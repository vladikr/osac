#!/usr/bin/env bash
# Validate the Launchpad pilot's provider IP Block, then publish a nonsecret
# observation on its private placement target. Re-run after provider changes.
set -euo pipefail
set +x

namespace="${NS:-osac}"
target_id="nico-gb300-fnn-nvl72"
site_id="d88d241d-a727-49c9-9fbb-521595a4eaa5"
tenant_id="284a8abb-f12f-45b8-b124-4207c35cefb8"
block_id="1adb7f5b-8b3e-4ff3-be0d-96bd99b2dab5"
api_host="fulfillment-internal-api.${namespace}.svc.cluster.local"
api_port="${NICO_PILOT_PRIVATE_API_PORT:-18001}"
pilot_dir="${HOME}/.local/share/nico-pilot"
tmp_dir="$(mktemp -d)"
port_forward_pid=""
cleanup() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
umask 077

case "$#" in
  0) ;;
  1|2) [[ "$1" == --show ]] || fail "usage: $0 [--show [BMI_ID]]" ;;
  *) fail "usage: $0 [--show [BMI_ID]]" ;;
esac
[[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]] || fail "set KUBECONFIG to the pilot Kind cluster"
[[ "$(kubectl config current-context)" == kind-osac-dev ]] || fail "unexpected Kubernetes context"

kubectl -n "${namespace}" get configmap ca-bundle -o jsonpath='{.data.bundle\.pem}' > "${tmp_dir}/ca.pem"
kubectl -n "${namespace}" get secret fulfillment-controller-credentials \
  -o jsonpath='{.data.client-secret}' | base64 -d > "${tmp_dir}/fulfillment-secret"
client_id="$(kubectl -n "${namespace}" get secret fulfillment-controller-credentials \
  -o jsonpath='{.data.client-id}' | base64 -d)"
issuer="$(kubectl -n "${namespace}" get configmap osac-fulfillment-config \
  -o jsonpath='{.data.OSAC_FULFILLMENT_ISSUER_URL}')"
[[ "${issuer}" == 'https://keycloak.osac.localhost:8443/realms/osac' ]] || fail "unexpected Fulfillment issuer"
curl -fsS --cacert "${tmp_dir}/ca.pem" --resolve 'keycloak.osac.localhost:8443:127.0.0.1' \
  --output "${tmp_dir}/fulfillment-token.json" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=${client_id}" \
  --data-urlencode "client_secret@${tmp_dir}/fulfillment-secret" \
  "${issuer}/protocol/openid-connect/token"
fulfillment_token="$(jq -er '.access_token' "${tmp_dir}/fulfillment-token.json")"

kubectl -n "${namespace}" port-forward svc/fulfillment-internal-api "${api_port}:8001" \
  > "${tmp_dir}/port-forward.log" 2>&1 &
port_forward_pid="$!"
api="https://${api_host}:${api_port}/api/private/v1/bare_metal_placement_targets/${target_id}"
curl_args=(--silent --show-error --fail --connect-timeout 5 --max-time 30 --cacert "${tmp_dir}/ca.pem"
  --resolve "${api_host}:${api_port}:127.0.0.1" --noproxy "${api_host}"
  -H "Authorization: Bearer ${fulfillment_token}")
for _ in $(seq 1 20); do
  if curl "${curl_args[@]}" --output "${tmp_dir}/target.json" "${api}" 2>/dev/null; then break; fi
  kill -0 "${port_forward_pid}" 2>/dev/null || fail "Fulfillment port-forward exited"
  sleep 1
done
[[ -s "${tmp_dir}/target.json" ]] || fail "placement target is not registered"
if [[ "${1:-}" == --show ]]; then
  jq '{kind:"BareMetalPlacementTarget",id,spec,status}' "${tmp_dir}/target.json"
  if [[ "$#" == 2 ]]; then
    bmi_id="$2"
    [[ "${bmi_id}" =~ ^[[:xdigit:]-]+$ ]] || fail "expected an OSAC BMI ID"
    private_api="${api%/bare_metal_placement_targets/*}"
    curl "${curl_args[@]}" "${private_api}/baremetal_instances/${bmi_id}" |
      jq '{kind:"BareMetalInstance",id,state:.status.state,target:.status.placement_target_id,nico_instance_type_id:.status.placement_nico_instance_type_id}'
    kubectl -n "${namespace}" get baremetalinstance "bmi-${bmi_id}" -o json > "${tmp_dir}/bmi.json"
    for network in vpc prefix; do
      realization="$(jq -er --arg key "osac.openshift.io/${network}-realization-id" \
        '.metadata.annotations[$key] | select(length > 0)' "${tmp_dir}/bmi.json")" ||
        fail "BMI does not yet reference a ${network} realization"
      curl "${curl_args[@]}" "${private_api}/network_realizations/${realization}" |
        jq '{kind:"NetworkRealization",id,spec,status}'
    done
  fi
  exit 0
fi

[[ -s "${pilot_dir}/ca-bundle.crt" && -s "${pilot_dir}/ncx-service-secret.txt" ]] || fail "NICo CA or client secret is missing"
# Launchpad secret files may have a trailing newline.
printf '%s' "$(cat "${pilot_dir}/ncx-service-secret.txt")" > "${tmp_dir}/nico-secret"
curl -fsS --cacert "${pilot_dir}/ca-bundle.crt" --output "${tmp_dir}/nico-token.json" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode client_id=ncx-service \
  --data-urlencode "client_secret@${tmp_dir}/nico-secret" \
  'https://keycloak-rhbk-operator.apps.nico-hub.nvidialaunchpad.internal/realms/nico/protocol/openid-connect/token'
nico_token="$(jq -er '.access_token' "${tmp_dir}/nico-token.json")"
reject_target() {
  jq --arg reason "$1" '.status = {ready:false,message:$reason}' "${tmp_dir}/target.json" > "${tmp_dir}/invalid.json"
  curl "${curl_args[@]}" -X PATCH -H 'Content-Type: application/json' \
    --data-binary "@${tmp_dir}/invalid.json" --output /dev/null "${api}?update_mask=status&lock=true"
  fail "$1"
}
curl -fsS --cacert "${pilot_dir}/ca-bundle.crt" \
  -H "Authorization: Bearer ${nico_token}" \
  --output "${tmp_dir}/ip-block.json" \
  "https://nico-rest-api-nico-rest.apps.nico-hub.nvidialaunchpad.internal/v2/org/ncx/nico/ipblock/${block_id}"
jq -e --arg id "${block_id}" --arg tenant "${tenant_id}" --arg site "${site_id}" \
  '.id == $id and .status == "Ready" and .tenantId == $tenant and .siteId == $site and
   (.prefix | type == "string") and (.prefixLength | type == "number")' \
  "${tmp_dir}/ip-block.json" >/dev/null || reject_target "NICo IP Block differs from the configured tenant or site"
cidr="$(jq -er '"\(.prefix)/\(.prefixLength)"' "${tmp_dir}/ip-block.json")"

jq -e --arg site "${site_id}" \
  '.spec.site_id == $site and .spec.osac_tenant_id == "tenant1" and
   (.spec.instance_type_mappings | length > 0) and
   .spec.provider_config_ref == "nico-gb300-pool-nvl72" and
   .spec.network_config_ref == "nico-fnn-nvl72-site"' "${tmp_dir}/target.json" >/dev/null ||
  fail "placement target specification differs from the configured pilot"
# An org can act as both provider and tenant. A visible type alone does not establish entitlement.
nico_api="https://nico-rest-api-nico-rest.apps.nico-hub.nvidialaunchpad.internal/v2/org/ncx/nico"
nico_get=(curl -fsS --cacert "${pilot_dir}/ca-bundle.crt" -H "Authorization: Bearer ${nico_token}")
private_api="${api%/bare_metal_placement_targets/*}"
jq -r '.spec.instance_type_mappings[].osac_instance_type_id | @uri' "${tmp_dir}/target.json" > "${tmp_dir}/offerings"
while IFS= read -r offering; do
  curl "${curl_args[@]}" --output "${tmp_dir}/offering.json" "${private_api}/bare_metal_instance_types/${offering}"
  jq -e '.metadata.deletion_timestamp == null and (.metadata.tenant == "tenant1" or .metadata.tenant == "shared")' \
    "${tmp_dir}/offering.json" >/dev/null || reject_target "OSAC instance type ${offering} is unavailable to tenant1"
done < "${tmp_dir}/offerings"
jq -r '.spec.instance_type_mappings[].nico_instance_type_id' "${tmp_dir}/target.json" | sort -u > "${tmp_dir}/pools"
while IFS= read -r pool; do
  "${nico_get[@]}" --output "${tmp_dir}/allocations.json" --get "${nico_api}/allocation" \
    --data-urlencode "siteId=${site_id}" --data-urlencode "tenantId=${tenant_id}" \
    --data-urlencode "resourceType=InstanceType" --data-urlencode "resourceTypeId=${pool}" \
    --data-urlencode "status=Registered" --data-urlencode "pageSize=100"
  jq -e --arg site "${site_id}" --arg tenant "${tenant_id}" --arg pool "${pool}" '
    any(.[]; .siteId == $site and .tenantId == $tenant and .status == "Registered" and
      any(.allocationConstraints[]?; .resourceType == "InstanceType" and .resourceTypeId == $pool))' \
    "${tmp_dir}/allocations.json" >/dev/null || reject_target "no registered tenant allocation for NICo type ${pool}"
  "${nico_get[@]}" --output "${tmp_dir}/pool.json" "${nico_api}/instance/type/${pool}"
  jq -e --arg site "${site_id}" --arg pool "${pool}" \
    '.id == $pool and .siteId == $site and .status == "Ready"' "${tmp_dir}/pool.json" >/dev/null ||
    reject_target "NICo type ${pool} is not Ready at the configured site"
done < "${tmp_dir}/pools"
fingerprint="$(jq -cn --slurpfile target "${tmp_dir}/target.json" --slurpfile block "${tmp_dir}/ip-block.json" \
  '{target:$target[0].spec,block:{id:$block[0].id,prefix:$block[0].prefix,prefixLength:$block[0].prefixLength,siteId:$block[0].siteId,tenantId:$block[0].tenantId}}' |
  sha256sum | cut -d' ' -f1)"
validated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg cidr "${cidr}" --arg fingerprint "${fingerprint}" --arg time "${validated_at}" \
  '.status = {ready:true,validated_fingerprint:$fingerprint,observed_ip_block_cidr:$cidr,validated_at:$time}' \
  "${tmp_dir}/target.json" > "${tmp_dir}/validated-target.json"
curl "${curl_args[@]}" -X PATCH -H 'Content-Type: application/json' \
  --data-binary "@${tmp_dir}/validated-target.json" --output "${tmp_dir}/updated.json" \
  "${api}?update_mask=status&lock=true"
jq -er --arg cidr "${cidr}" \
  'select(.status.ready == true and .status.observed_ip_block_cidr == $cidr) |
   "placement target \(.id) validated for \($cidr)"' "${tmp_dir}/updated.json"
