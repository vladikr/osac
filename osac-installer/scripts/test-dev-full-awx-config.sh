#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source charts/osac-devstack/files/configure-awx.sh

# Parse the tracked catalog without contacting GitHub or AWX.
curl() {
  cat ../osac-aap/collections/ansible_collections/osac/config_as_code/roles/aap/vars/controller.yml
}
specs=$(controller_template_specs)
for operation in create delete; do
  name="osac-${operation}-bare-metal-instance"
  prompt=$(awk -F '|' -v name="$name" '$1 == name { print $5 }' <<<"$specs")
  if [[ "$prompt" != true ]]; then
    echo "$name must request its NICo credential at launch" >&2
    exit 1
  fi
done
unset -f curl

# Check that the parsed prompt flag reaches the AWX job-template payload.
payload_file=$(mktemp)
trap 'rm -f "$payload_file"' EXIT
awx_job_template_request() {
  if [[ "$1" == GET ]]; then
    printf '{"results":[]}'
  else
    printf '%s' "$3" > "$payload_file"
    printf '{"id":42}'
  fi
}
project_id=1
ee_id=2
ensure_job_template osac-create-bare-metal-instance playbooks/create.yaml 3 '{}' true
if ! jq -e '.ask_credential_on_launch == true' "$payload_file" >/dev/null; then
  echo "NICo BMI template payload must prompt for credentials" >&2
  exit 1
fi
ensure_job_template osac-create-compute-instance playbooks/create.yaml 3 '{}' false
if ! jq -e '.ask_credential_on_launch == false' "$payload_file" >/dev/null; then
  echo "Ordinary job template payload must retain its credential behavior" >&2
  exit 1
fi

echo "Dev-full AWX project and template configuration checks passed."
