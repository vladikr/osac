#!/usr/bin/env python3
"""Configure the isolated Launchpad FNN pilot's AWX credential and BMF inputs."""

import base64
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener


NAMESPACE = "osac"
DISK_IMAGE_ID = "centos-stream-10"
OPERATING_SYSTEM_ID = "3403dd3c-83c3-474a-b62b-1aeaddf81ac4"
CREDENTIAL_TYPE_NAME = "nico-bmaas-fnn-pilot-type"
CREDENTIAL_NAME = "nico-tenant1-fnn-pilot"
AWX_PORT = "18084"


def kubectl(*args, input_text=None):
    result = subprocess.run(
        ["kubectl", "-n", NAMESPACE, *args],
        input=input_text,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(f"kubectl {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def k8s_object(kind, name):
    raw = kubectl("get", kind, name, "--ignore-not-found", "-o", "json")
    return json.loads(raw) if raw.strip() else None


def ensure_k8s_object(obj, expected_content):
    current = k8s_object(obj["kind"].lower(), obj["metadata"]["name"])
    if current is not None:
        if expected_content(current) != expected_content(obj):
            raise RuntimeError(f"existing {obj['kind']}/{obj['metadata']['name']} differs; inspect it before changing")
        print(f"{obj['kind']}/{obj['metadata']['name']}: already matches")
        return
    kubectl("apply", "-f", "-", input_text=json.dumps(obj))
    print(f"{obj['kind']}/{obj['metadata']['name']}: created")


def main():
    kubeconfig = os.environ.get("KUBECONFIG")
    if not kubeconfig or not Path(kubeconfig).is_file():
        raise RuntimeError("set KUBECONFIG to the new pilot VM's Kind kubeconfig")
    context = subprocess.check_output(["kubectl", "config", "current-context"], text=True).strip()
    if context != "kind-osac-dev":
        raise RuntimeError(f"expected kind-osac-dev context, got {context}")

    directory = Path.home() / ".local/share/nico-pilot"
    client_secret = (directory / "ncx-service-secret.txt").read_text().strip()
    ca_bundle = (directory / "ca-bundle.crt").read_text()
    if not client_secret or "BEGIN CERTIFICATE" not in ca_bundle:
        raise RuntimeError("NICo client secret or CA bundle is invalid")
    awx_token = base64.b64decode(
        kubectl("get", "secret", "awx-token", "-o", "jsonpath={.data.token}")
    ).decode().strip()
    if not awx_token:
        raise RuntimeError("AWX token is empty")

    port_forward = subprocess.Popen(
        ["kubectl", "-n", NAMESPACE, "port-forward", "svc/awx-service", f"{AWX_PORT}:80"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    opener = build_opener(ProxyHandler({}))

    def awx(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Authorization": f"Bearer {awx_token}"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = Request(f"http://127.0.0.1:{AWX_PORT}/api/v2{path}",
                          data=data, headers=headers, method=method)
        try:
            with opener.open(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except HTTPError as error:
            raise RuntimeError(f"AWX {method} {path} returned HTTP {error.code}") from None

    def unique_result(path, name):
        response = awx("GET", path + "?name=" + quote(name, safe=""))
        matches = [item for item in response["results"] if item["name"] == name]
        if len(matches) > 1:
            raise RuntimeError(f"multiple AWX resources named {name}")
        return matches[0] if matches else None

    try:
        for attempt in range(20):
            try:
                project = unique_result("/projects/", "osac-aap")
                break
            except URLError:
                if port_forward.poll() is not None or attempt == 19:
                    raise RuntimeError("AWX port-forward did not become ready") from None
                time.sleep(1)
        if not project or not project.get("organization"):
            raise RuntimeError("expected one osac-aap project with an AWX organization")
        organization = project["organization"]

        for template_name in ("osac-create-bare-metal-instance", "osac-delete-bare-metal-instance"):
            template = unique_result("/job_templates/", template_name)
            if not template or not template.get("ask_credential_on_launch"):
                raise RuntimeError(f"AWX template {template_name} cannot accept launch credentials")

        kube_credential = unique_result("/credentials/", "kind-cluster")
        if not kube_credential or kube_credential.get("organization") != organization:
            raise RuntimeError("AWX kind-cluster Kubernetes credential was not found in the pilot organization")

        environment = {
            "SSL_CERT_FILE": "{{ tower.filename }}",
            "NICO_BMAAS_API_URL": "https://nico-rest-api-nico-rest.apps.nico-hub.nvidialaunchpad.internal",
            "NICO_BMAAS_TOKEN_URL": "https://keycloak-rhbk-operator.apps.nico-hub.nvidialaunchpad.internal/realms/nico/protocol/openid-connect/token",
            "NICO_BMAAS_TENANT_ORG": "ncx",
            "NICO_BMAAS_PROVIDER_ORG": "ncx",
            "NICO_BMAAS_TENANT_ID": "284a8abb-f12f-45b8-b124-4207c35cefb8",
            "NICO_BMAAS_OSAC_TENANT_ID": "tenant1",
            "NICO_BMAAS_NETWORK_VIRTUALIZATION_TYPE": "FNN",
            "NICO_BMAAS_FNN_AUTO_CREATE": "true",
            "NICO_BMAAS_SITE_ID": "d88d241d-a727-49c9-9fbb-521595a4eaa5",
            "NICO_BMAAS_IP_BLOCK_ID": "1adb7f5b-8b3e-4ff3-be0d-96bd99b2dab5",
            "NICO_BMAAS_ROUTING_PROFILE": "external",
            "NICO_BMAAS_INSTANCE_TYPE_ID": "fce88359-c3bc-48b7-8029-b0f4466a2538",
            "NICO_BMAAS_PILOT_ALLOW_UNENFORCED_SECURITY_GROUPS": "true",
            "NICO_BMAAS_TENANT_CLIENT_ID": "ncx-service",
            "NICO_BMAAS_PROVIDER_CLIENT_ID": "ncx-service",
            "NICO_BMAAS_TENANT_CLIENT_SECRET": "{{ client_secret }}",
            "NICO_BMAAS_PROVIDER_CLIENT_SECRET": "{{ client_secret }}",
        }
        type_body = {
            "name": CREDENTIAL_TYPE_NAME,
            "kind": "cloud",
            "inputs": {
                "fields": [
                    {"id": "client_secret", "label": "NICo client secret", "type": "string", "secret": True},
                    {"id": "ca_bundle", "label": "NICo ingress CA bundle", "type": "string", "multiline": True},
                ],
                "required": ["client_secret", "ca_bundle"],
            },
            "injectors": {"file": {"template": "{{ ca_bundle }}"}, "env": environment},
        }
        credential_type = unique_result("/credential_types/", CREDENTIAL_TYPE_NAME)
        if credential_type:
            if credential_type.get("injectors") != type_body["injectors"]:
                raise RuntimeError("existing NICo AWX credential type has different injectors")
        else:
            credential_type = awx("POST", "/credential_types/", type_body)

        credential_body = {
            "name": CREDENTIAL_NAME,
            "organization": organization,
            "credential_type": credential_type["id"],
            "inputs": {"client_secret": client_secret, "ca_bundle": ca_bundle},
        }
        credential = unique_result("/credentials/", CREDENTIAL_NAME)
        if credential and credential.get("credential_type") != credential_type["id"]:
            raise RuntimeError("existing NICo AWX credential has a different type")
        if credential:
            credential = awx("PATCH", f"/credentials/{credential['id']}/", credential_body)
        else:
            credential = awx("POST", "/credentials/", credential_body)

        binding = (
            "version: 2\n"
            "bindings:\n"
            "  - osacTenantID: tenant1\n"
            "    osacBareMetalInstanceTypeID: nico-gb300-nvl72\n"
            "    placementTargetID: nico-gb300-fnn-nvl72\n"
            "    providerConfigRef: nico-gb300-pool-nvl72\n"
            "    networkConfigRef: nico-fnn-nvl72-site\n"
            "    siteID: d88d241d-a727-49c9-9fbb-521595a4eaa5\n"
            f"    credentialIDs: [{kube_credential['id']}, {credential['id']}]\n"
            "operatingSystems:\n"
            f"  - diskImageID: {DISK_IMAGE_ID}\n"
            f"    nicoOperatingSystemID: {OPERATING_SYSTEM_ID}\n"
        )
        binding_map = {"apiVersion": "v1", "kind": "ConfigMap",
                       "metadata": {"name": "osac-nico-tenant-bindings", "namespace": NAMESPACE},
                       "data": {"bindings.yaml": binding}}
        existing_binding = k8s_object("configmap", "osac-nico-tenant-bindings")
        if existing_binding is None or existing_binding.get("data") != binding_map["data"]:
            # This replaces the pilot's earlier Subnet-specific row with one
            # type/target binding. It carries no credential values.
            kubectl("apply", "-f", "-", input_text=json.dumps(binding_map))
            print("ConfigMap/osac-nico-tenant-bindings: applied target binding")
        else:
            print("ConfigMap/osac-nico-tenant-bindings: already matches")
        for name, filename, content in (
            ("osac-inventory-config-nico-pilot", "inventory.yaml",
             "name: nico-inventory\ntype: nico\nhostClass: nico\noptions: {}\n"),
            ("osac-management-config-nico-pilot", "management.yaml",
             "name: nico-management\ntype: nico\noptions: {}\n"),
        ):
            encoded = base64.b64encode(content.encode()).decode()
            ensure_k8s_object(
                {"apiVersion": "v1", "kind": "Secret",
                 "metadata": {"name": name, "namespace": NAMESPACE},
                 "type": "Opaque", "data": {filename: encoded}},
                lambda obj: obj["data"],
            )
        print(json.dumps({
            "awxProjectRevision": project.get("scm_revision"),
            "kubernetesCredentialId": kube_credential["id"],
            "nicoCredentialTypeId": credential_type["id"],
            "nicoCredentialId": credential["id"],
            "placementTargetId": "nico-gb300-fnn-nvl72",
            "diskImageId": DISK_IMAGE_ID,
            "nicoOperatingSystemId": OPERATING_SYSTEM_ID,
        }, indent=2))
    finally:
        port_forward.terminate()
        try:
            port_forward.wait(timeout=5)
        except subprocess.TimeoutExpired:
            port_forward.kill()
            port_forward.wait()

    # The target remains unselectable until the provider IP Block is observed
    # and its nonsecret fingerprint is stored by the private Fulfillment API.
    subprocess.run(["bash", str(Path(__file__).with_name("validate-nico-placement-target.sh"))], check=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
