#!/usr/bin/env bash
# Register the shared NICo GB300 hardware type and BMI template in a Kind dev-full pilot.
# Credentials come from the deployed Fulfillment Secret and never enter the source tree.
set -euo pipefail
set +x

namespace="${NS:-osac}"
api_host="fulfillment-internal-api.${namespace}.svc.cluster.local"
local_port="${NICO_PILOT_PRIVATE_API_PORT:-18001}"
issuer_host="keycloak.osac.localhost"
temporary_dir="$(mktemp -d)"
port_forward_pid=""

cleanup() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || fail "set KUBECONFIG to the pilot Kind kubeconfig"
[[ "$(kubectl config current-context)" == kind-osac-dev ]] || fail "expected kind-osac-dev context"
for command in kubectl curl jq base64; do
  command -v "${command}" >/dev/null || fail "missing command: ${command}"
done
umask 077

kubectl -n "${namespace}" get configmap ca-bundle \
  -o jsonpath='{.data.bundle\.pem}' > "${temporary_dir}/ca.pem"
kubectl -n "${namespace}" get secret fulfillment-controller-credentials \
  -o jsonpath='{.data.client-secret}' | base64 -d > "${temporary_dir}/client-secret"
client_id="$(kubectl -n "${namespace}" get secret fulfillment-controller-credentials \
  -o jsonpath='{.data.client-id}' | base64 -d)"
issuer="$(kubectl -n "${namespace}" get configmap osac-fulfillment-config \
  -o jsonpath='{.data.OSAC_FULFILLMENT_ISSUER_URL}')"
[[ -s "${temporary_dir}/ca.pem" && -s "${temporary_dir}/client-secret" && -n "${client_id}" ]] || fail "Fulfillment credentials are incomplete"
[[ "${issuer}" == "https://${issuer_host}:8443/realms/osac" ]] || fail "unexpected dev-full issuer: ${issuer}"

curl --silent --show-error --fail --cacert "${temporary_dir}/ca.pem" \
  --resolve "${issuer_host}:8443:127.0.0.1" \
  --connect-timeout 5 --max-time 30 \
  --output "${temporary_dir}/token.json" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode "client_id=${client_id}" \
  --data-urlencode "client_secret@${temporary_dir}/client-secret" \
  "${issuer}/protocol/openid-connect/token"
token="$(jq -er '.access_token' "${temporary_dir}/token.json")"

kubectl -n "${namespace}" port-forward svc/fulfillment-internal-api \
  "${local_port}:8001" > "${temporary_dir}/port-forward.log" 2>&1 &
port_forward_pid="$!"
api="https://${api_host}:${local_port}/api/private/v1"
curl_args=(
  --silent --show-error --cacert "${temporary_dir}/ca.pem"
  --resolve "${api_host}:${local_port}:127.0.0.1" --noproxy "${api_host}"
  --connect-timeout 5 --max-time 30
  --header "Authorization: Bearer ${token}"
)

ready=false
for _ in $(seq 1 20); do
  kill -0 "${port_forward_pid}" 2>/dev/null || fail "private API port-forward exited"
  if curl "${curl_args[@]}" --fail --output /dev/null "${api}/disk_images" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
[[ "${ready}" == true ]] || fail "private Fulfillment API did not become ready"

cat > "${temporary_dir}/type.json" <<'JSON'
{
  "metadata": {"name": "nico-gb300-nvl72", "tenant": "shared"},
  "spec": {
    "hardware": {
      "cpu": {"cores": 144, "architecture": "arm64", "model": "Neoverse-V2", "threads_per_core": 1},
      "memory": {"total_gb": "960", "type": "LPDDR5X"},
      "accelerators": [
        {"type": "GPU", "model": "GB300", "vendor": "NVIDIA"},
        {"type": "GPU", "model": "GB300", "vendor": "NVIDIA"},
        {"type": "GPU", "model": "GB300", "vendor": "NVIDIA"},
        {"type": "GPU", "model": "GB300", "vendor": "NVIDIA"}
      ],
      "network_ports": [
        {"name": "data-0", "role": "fabric", "type": "Ethernet", "speed": "400Gbps"}
      ]
    },
    "description": "Lenovo GB300 NVL72 compute tray for the NICo pilot",
    "host_label_selector": {"match_labels": {"model": "GB300_NVL72"}}
  }
}
JSON

cat > "${temporary_dir}/template.json" <<'JSON'
{
  "id": "osac.templates.nico_bm_host_provisioning",
  "metadata": {"name": "nico-bm-host-provisioning", "tenant": "shared"},
  "title": "NICo Bare Metal Instance Provisioning",
  "description": "Provisions one NICo Instance for an OSAC BareMetalInstance and verifies cleanup of its original Machine on deletion."
}
JSON

ensure_resource() {
  local resource="$1" id="$2" payload="$3" kind="$4" code
  code="$(curl "${curl_args[@]}" --output "${temporary_dir}/response.json" \
    --write-out '%{http_code}' "${api}/${resource}/${id}")"
  case "${code}" in
    200)
      if [[ "${kind}" == type ]]; then
        jq -e --slurpfile expected "${payload}" \
          '.id == $expected[0].metadata.name and .metadata.name == $expected[0].metadata.name and .spec == $expected[0].spec' \
          "${temporary_dir}/response.json" >/dev/null || fail "existing ${resource}/${id} differs from pilot specification"
      else
        jq -e --slurpfile expected "${payload}" \
          '.id == $expected[0].id and .metadata.name == $expected[0].metadata.name and .title == $expected[0].title' \
          "${temporary_dir}/response.json" >/dev/null || fail "existing ${resource}/${id} differs from pilot template"
      fi
      echo "${resource}/${id}: already matches"
      ;;
    404)
      code="$(curl "${curl_args[@]}" --header 'Content-Type: application/json' \
        --data-binary "@${payload}" --output "${temporary_dir}/response.json" \
        --write-out '%{http_code}' "${api}/${resource}")"
      if [[ "${code}" != 2* ]]; then
        jq '{code,message}' "${temporary_dir}/response.json" >&2 || true
        fail "creating ${resource}/${id} returned HTTP ${code}"
      fi
      jq -er --arg id "${id}" --arg resource "${resource}" \
        'select(.id == $id) | "\($resource)/\(.id): created"' \
        "${temporary_dir}/response.json" || fail "create response did not contain ${id}"
      ;;
    *)
      jq '{code,message}' "${temporary_dir}/response.json" >&2 || true
      fail "reading ${resource}/${id} returned HTTP ${code}"
      ;;
  esac
}

ensure_resource bare_metal_instance_types nico-gb300-nvl72 "${temporary_dir}/type.json" type
ensure_resource baremetal_instance_templates osac.templates.nico_bm_host_provisioning "${temporary_dir}/template.json" template
