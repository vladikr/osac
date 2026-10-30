#!/usr/bin/env bash
# dev-full: configure AWX as the AAP provisioning backend on Kind.
#
# AWX is installed as a Helm chart dependency (awx-operator). This script
# configures the OAuth token, inventory, project, job templates and Kubernetes
# credential that osac-operator needs.
#
# Requires KUBECONFIG to point at the kind cluster.
#
# Usage: configure-awx.sh [osac-namespace]

set -euo pipefail

NS="${1:-${NS:-osac}}"
OSAC_EE_IMAGE="${OSAC_EE_IMAGE:-ghcr.io/osac-project/osac-aap:latest}"
OSAC_EE_PULL="${OSAC_EE_PULL:-missing}"
OSAC_AWX_PROJECT_URL="${OSAC_AWX_PROJECT_URL:-https://github.com/osac-project/osac.git}"
OSAC_AWX_PROJECT_BRANCH="${OSAC_AWX_PROJECT_BRANCH:-main}"
OSAC_CONTROLLER_VARS_URL="${OSAC_CONTROLLER_VARS_URL:-https://raw.githubusercontent.com/osac-project/osac/main/osac-aap/collections/ansible_collections/osac/config_as_code/roles/aap/vars/controller.yml}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

# Make template API failures visible to the Helm hook. Plain `curl -s` returns
# success for HTTP 4xx/5xx responses, which previously let this Job complete
# even when AWX rejected every template create request.
awx_job_template_request() {
  local method="$1" endpoint="$2" payload="${3:-}"
  local response http_status
  local -a curl_args=(
    --silent --show-error --write-out $'\n%{http_code}'
    -X "${method}"
    -H "Authorization: Bearer ${awx_token}"
    -H "Content-Type: application/json"
  )
  [[ -z "${payload}" ]] || curl_args+=(--data "${payload}")

  response=$(curl "${curl_args[@]}" "${api}${endpoint}")
  http_status="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [[ ! "${http_status}" =~ ^2[0-9][0-9]$ ]]; then
    warn "AWX API ${method} ${endpoint} failed (HTTP ${http_status}): ${response}"
    return 1
  fi
  printf '%s' "${response}"
}

ensure_job_template() {
  local name="$1" playbook="$2" inventory_id="$3" extra_vars="$4" ask_credential="$5"
  local existing_id response template_id payload method endpoint

  payload=$(python3 -c '
import json
import sys

name, playbook, inventory, project, execution_environment, extra_vars, ask_credential = sys.argv[1:]
print(json.dumps({
    "name": name,
    "organization": 1,
    "inventory": int(inventory),
    "project": int(project),
    "playbook": playbook,
    "execution_environment": int(execution_environment),
    "extra_vars": extra_vars,
    "ask_variables_on_launch": True,
    "ask_credential_on_launch": ask_credential == "true",
    "allow_simultaneous": False,
}))
' "${name}" "${playbook}" "${inventory_id}" "${project_id}" "${ee_id}" "${extra_vars}" "${ask_credential}")

  response=$(awx_job_template_request GET "/job_templates/?name=${name}")
  existing_id=$(python3 -c '
import json
import sys

name = sys.argv[1]
templates = json.load(sys.stdin).get("results", [])
matches = [str(item["id"]) for item in templates
           if item.get("name") == name and item.get("organization") == 1]
if len(matches) > 1:
    raise SystemExit(f"multiple AWX job templates named {name!r} in organization 1")
print(matches[0] if matches else "")
' "${name}" <<<"${response}")
  if [[ -n "${existing_id}" ]]; then
    method=PATCH
    endpoint="/job_templates/${existing_id}/"
  else
    method=POST
    endpoint="/job_templates/"
  fi

  response=$(awx_job_template_request "${method}" "${endpoint}" "${payload}")
  template_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"${response}")
  if [[ -z "${template_id}" && -n "${existing_id}" ]]; then
    template_id="${existing_id}"
  fi
  if [[ -z "${template_id}" ]]; then
    warn "AWX accepted ${method} ${endpoint} but returned no job template ID"
    return 1
  fi
  log "  template ${method,,}: ${name} (id ${template_id})"
}

execution_environment_json() {
  OSAC_EE_IMAGE="${OSAC_EE_IMAGE}" OSAC_EE_PULL="${OSAC_EE_PULL}" \
    python3 -c 'import json, os; print(json.dumps({"name": "osac-aap-ee", "organization": 1, "image": os.environ["OSAC_EE_IMAGE"], "pull": os.environ["OSAC_EE_PULL"]}))'
}

execution_environment_image_json() {
  OSAC_EE_IMAGE="${OSAC_EE_IMAGE}" OSAC_EE_PULL="${OSAC_EE_PULL}" \
    python3 -c 'import json, os; print(json.dumps({"image": os.environ["OSAC_EE_IMAGE"], "pull": os.environ["OSAC_EE_PULL"]}))'
}

ensure_inventory() {
  local inventory_name="$1" api="$2" awx_token="$3" inventory_id
  inventory_id=$(curl -s -X POST "${api}/inventories/" -H "Authorization: Bearer ${awx_token}" \
    -H "Content-Type: application/json" -d "{\"name\": \"${inventory_name}\", \"organization\": 1}" | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  if [[ -z "${inventory_id}" ]]; then
    inventory_id=$(curl -s -H "Authorization: Bearer ${awx_token}" "${api}/inventories/?name=${inventory_name}" | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['id'] if d.get('results') else '')")
  fi
  [[ -n "${inventory_id}" ]] || return 1
  curl -s -X POST "${api}/inventories/${inventory_id}/hosts/" -H "Authorization: Bearer ${awx_token}" \
    -H "Content-Type: application/json" -d '{"name": "localhost", "variables": "ansible_connection: local"}' >/dev/null 2>&1 || true
  printf '%s' "${inventory_id}"
}

controller_template_specs() {
  curl -fsSL "${OSAC_CONTROLLER_VARS_URL}" | python3 -c '
import re
import sys

text = sys.stdin.read()
section = text.split("controller_templates:", 1)[1].split("controller_job_template_surveys:", 1)[0]
entry_pattern = re.compile(r"(?ms)^\s+- name: \"\{\{ aap_prefix \}\}-(?P<name>[^\"]+)\"\s*\n(?P<body>.*?)(?=^\s+- name:|\Z)")
for entry in entry_pattern.finditer(section):
    body = entry.group("body")
    playbook = re.search(r"^\s+playbook:\s+\"([^\"]+)\"", body, re.MULTILINE)
    inventory = re.search(r"^\s+inventory:\s+\"\{\{ aap_prefix \}\}-([^\"]+)\"", body, re.MULTILINE)
    if not playbook or not inventory:
        continue
    workflow_status = re.search(r"^\s+workflow_status:\s+(\w+)", body, re.MULTILINE)
    ask_credential = re.search(r"^\s+ask_credential_on_launch:\s+(true|false)\s*$", body, re.MULTILINE)
    print("|".join(("osac-" + entry.group("name"), playbook.group(1), "osac-" + inventory.group(1), workflow_status.group(1) if workflow_status else "", ask_credential.group(1) if ask_credential else "false")))
'
}

configure_awx() {
  log "Configuring AWX for OSAC..."

  local admin_pass
  admin_pass=$(kubectl -n "${NS}" get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d)

  # Connect directly to AWX service (this script runs in-cluster as a Job pod)
  local api="http://awx-service.${NS}.svc.cluster.local/api/v2"

  # OAuth token.
  local awx_token
  awx_token=$(curl -s -X POST "${api}/tokens/" -u "admin:${admin_pass}" \
    -H "Content-Type: application/json" -d '{"scope": "write"}' | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))")
  if [[ -z "$awx_token" ]]; then
    warn "Failed to create AWX token — AWX may not be ready yet"
    return 1
  fi
  log "AWX token created"

  # Disable project collection/role sync: OSAC's collections are installed in
  # its dedicated execution environment from osac-aap/collections/requirements.yml.
  # Set ANSIBLE_JINJA2_NATIVE=true for osac-aap playbooks.
  # Local AWX workers may lack a service-account namespace file. Use the
  # release namespace for storage config Secrets through the supported override.
  local settings_payload
  settings_payload=$(python3 -c '
import json
import sys

print(json.dumps({
    "AWX_COLLECTIONS_ENABLED": False,
    "AWX_ROLES_ENABLED": False,
    "AWX_TASK_ENV": {
        "ANSIBLE_JINJA2_NATIVE": "true",
        "OSAC_STORAGE_CONFIG_NAMESPACE": sys.argv[1],
    },
}))
 ' "${NS}")
  curl -fsS -X PATCH "${api}/settings/jobs/" -H "Authorization: Bearer ${awx_token}" \
    -H "Content-Type: application/json" \
    -d "${settings_payload}" >/dev/null

  # Register the OSAC AAP execution environment. It is built from the same
  # collection requirements as AAP deployments, including vastdata.vms.
  local ee_id
  ee_id=$(curl -s -X POST "${api}/execution_environments/" -H "Authorization: Bearer ${awx_token}" \
    -H "Content-Type: application/json" \
    -d "$(execution_environment_json)" | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  if [[ -z "${ee_id}" ]]; then
    ee_id=$(curl -s -H "Authorization: Bearer ${awx_token}" "${api}/execution_environments/?name=osac-aap-ee" | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['id'] if d.get('results') else '')")
  fi
  if [[ -z "${ee_id}" ]]; then
    warn "Failed to create or find the OSAC AAP execution environment"
    return 1
  fi
  if ! curl -sS -f -X PATCH "${api}/execution_environments/${ee_id}/" \
    -H "Authorization: Bearer ${awx_token}" -H "Content-Type: application/json" \
    -d "$(execution_environment_image_json)" >/dev/null; then
    warn "Failed to configure execution environment ${ee_id}"
    return 1
  fi
  log "OSAC AAP execution environment configured: ${OSAC_EE_IMAGE} (pull: ${OSAC_EE_PULL})"

  # Project from the osac mono-repo.
  # Remove the cached checkout before syncing: the repo's graph-latest tag moves,
  # and Git rejects a fetch when that tag differs from AWX's stale local tag.
  local project_id project_json project_update_json project_update_id=""
  project_json=$(python3 -c '
import json
import sys

url, branch = sys.argv[1:]
print(json.dumps({
    "name": "osac-aap", "organization": 1, "scm_type": "git",
    "scm_url": url, "scm_branch": branch,
    "scm_update_on_launch": False, "scm_delete_on_update": True,
}))
' "${OSAC_AWX_PROJECT_URL}" "${OSAC_AWX_PROJECT_BRANCH}")
  project_update_json=$(python3 -c '
import json
import sys

url, branch = sys.argv[1:]
print(json.dumps({"scm_url": url, "scm_branch": branch, "scm_delete_on_update": True}))
' "${OSAC_AWX_PROJECT_URL}" "${OSAC_AWX_PROJECT_BRANCH}")
  project_id=$(curl -s -X POST "${api}/projects/" -H "Authorization: Bearer ${awx_token}" \
    -H "Content-Type: application/json" -d "${project_json}" | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
  if [[ -z "$project_id" ]]; then
    project_id=$(curl -s -H "Authorization: Bearer ${awx_token}" "${api}/projects/?name=osac-aap" | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['id'] if d.get('results') else '')")
    if [[ -n "$project_id" ]]; then
      curl -fsS -X PATCH "${api}/projects/${project_id}/" -H "Authorization: Bearer ${awx_token}" \
        -H "Content-Type: application/json" -d "${project_update_json}" >/dev/null
      project_update_id=$(curl -fsS -X POST "${api}/projects/${project_id}/update/" \
        -H "Authorization: Bearer ${awx_token}" | \
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')
      [[ "${project_update_id}" =~ ^[0-9]+$ ]] || { warn "AWX did not return a project update ID"; return 1; }
    fi
  fi
  if [[ ! "${project_id}" =~ ^[0-9]+$ ]]; then
    warn "Failed to create or find the osac-aap AWX project"
    return 1
  fi

  # On an existing project, the previous successful status can remain visible
  # while the new sync is running. Wait for this update job before reading the
  # project status or configuring templates from the new catalog.
  local i proj_status="unknown" update_status="unknown"
  if [[ -n "${project_update_id}" ]]; then
    for i in $(seq 1 60); do
      update_status=$(curl -fsS -H "Authorization: Bearer ${awx_token}" \
        "${api}/project_updates/${project_update_id}/" | \
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "unknown"))')
      [[ "${update_status}" == "successful" || "${update_status}" == "failed" || "${update_status}" == "error" || "${update_status}" == "canceled" ]] && break
      sleep 10
    done
    if [[ "${update_status}" != "successful" ]]; then
      warn "AWX project update ${project_update_id} did not succeed (${update_status})"
      return 1
    fi
  fi
  for i in $(seq 1 60); do
    proj_status=$(curl -s -H "Authorization: Bearer ${awx_token}" "${api}/projects/${project_id}/" | \
      python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo unknown)
    [[ "$proj_status" == "successful" || "$proj_status" == "failed" ]] && break
    sleep 10
  done
  log "AWX project synced: ${proj_status}"
  if [[ "${proj_status}" != "successful" ]]; then
    warn "AWX project sync did not succeed; refusing to create job templates"
    return 1
  fi

  # Create the production template catalog with dedicated inventories. Leave
  # compute storage classes unset; the operator supplies each tenant's resolved
  # classes when it launches a job.
  local inventory_id name playbook template_inventory workflow_status ask_credential extra_vars
  declare -A inventory_ids

  local template_specs
  if ! template_specs=$(controller_template_specs); then
    warn "Failed to load production controller template definitions"
    return 1
  fi
  if [[ -z "${template_specs}" ]]; then
    warn "Production controller template definitions are empty"
    return 1
  fi
  while IFS='|' read -r name playbook template_inventory workflow_status ask_credential; do
    [[ -n "${name}" ]] || continue
    if [[ -z "${inventory_ids[${template_inventory}]:-}" ]]; then
      inventory_ids["${template_inventory}"]=$(ensure_inventory "${template_inventory}" "${api}" "${awx_token}")
    fi
    inventory_id="${inventory_ids[${template_inventory}]}"
    [[ -n "${inventory_id}" ]] || { warn "No AWX inventory configured for ${name}"; return 1; }
    extra_vars="{}"
    if [[ -n "${workflow_status:-}" ]]; then
      extra_vars="workflow_status: ${workflow_status}"
    fi
    ensure_job_template "${name}" "${playbook}" "${inventory_id}" "${extra_vars}" "${ask_credential}"
  done <<< "${template_specs}"
  log "All 35 production OSAC job templates configured"

  # Kubernetes credential for job templates.
  kubectl -n "${NS}" create serviceaccount awx-runner 2>/dev/null || true
  kubectl create clusterrolebinding awx-runner-admin --clusterrole=cluster-admin \
    --serviceaccount="${NS}:awx-runner" 2>/dev/null || true

  local awx_runner_token cluster_ca cluster_ca_json cred_id credential_payload
  awx_runner_token=$(kubectl -n "${NS}" create token awx-runner --duration=87600h)
  if [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
    cluster_ca=$(</var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
  else
    cluster_ca=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
  fi
  cluster_ca_json=$(printf '%s' "${cluster_ca}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  credential_payload="{
      \"name\": \"kind-cluster\", \"organization\": 1, \"credential_type\": 17,
      \"inputs\": {
        \"host\": \"https://kubernetes.default.svc.cluster.local:443\",
        \"bearer_token\": \"${awx_runner_token}\", \"verify_ssl\": true,
        \"ssl_ca_cert\": ${cluster_ca_json}
      }
    }"
  cred_id=$(curl -fsS -H "Authorization: Bearer ${awx_token}" \
    "${api}/credentials/?name=kind-cluster" | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((c["id"] for c in d.get("results", []) if c["name"] == "kind-cluster" and c.get("organization") == 1), ""))')
  if [[ -n "${cred_id}" ]]; then
    curl -fsS -X PATCH "${api}/credentials/${cred_id}/" \
      -H "Authorization: Bearer ${awx_token}" -H "Content-Type: application/json" \
      -d "${credential_payload}" >/dev/null
  else
    cred_id=$(curl -fsS -X POST "${api}/credentials/" \
      -H "Authorization: Bearer ${awx_token}" -H "Content-Type: application/json" \
      -d "${credential_payload}" | \
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')
  fi
  [[ "${cred_id}" =~ ^[0-9]+$ ]] || { warn "Failed to configure the Kind cluster credential"; return 1; }

  # Attach credential to all job templates.
  local attached_credentials
  templates=$(curl -fsS -H "Authorization: Bearer ${awx_token}" "${api}/job_templates/?page_size=200" | \
    python3 -c "import json,sys; print(' '.join(str(t['id']) for t in json.load(sys.stdin)['results']))")
  for jt_id in ${templates}; do
    attached_credentials=$(curl -fsS -H "Authorization: Bearer ${awx_token}" \
      "${api}/job_templates/${jt_id}/credentials/?page_size=200")
    if python3 -c 'import json,sys; wanted=int(sys.argv[1]); d=json.load(sys.stdin); sys.exit(0 if any(c["id"] == wanted for c in d.get("results", [])) else 1)' \
      "${cred_id}" <<<"${attached_credentials}"; then
      continue
    fi
    curl -fsS -X POST "${api}/job_templates/${jt_id}/credentials/" \
      -H "Authorization: Bearer ${awx_token}" -H "Content-Type: application/json" \
      -d "{\"id\": ${cred_id}}" >/dev/null
  done
  log "Credential ${cred_id} attached to all templates"

  # Store AWX token as secret for osac-operator.
  kubectl -n "${NS}" create secret generic awx-token \
    --from-literal=token="${awx_token}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Restart operator to pick up awx-token secret.
  if kubectl -n "${NS}" get deployment osac-operator >/dev/null 2>&1; then
    kubectl -n "${NS}" rollout restart deployment osac-operator
    kubectl -n "${NS}" rollout status deployment osac-operator --timeout=3m || true
    log "osac-operator restarted to pick up awx-token"
  else
    warn "osac-operator deployment not found in ${NS}; skipped restart"
  fi

  log "AWX configured for OSAC"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  configure_awx
fi
