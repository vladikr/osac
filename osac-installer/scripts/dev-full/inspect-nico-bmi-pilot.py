#!/usr/bin/env python3
"""Read NICo OS and VPC metadata using the pilot VM's client credentials."""

import json
import ssl
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPSHandler, ProxyHandler, Request, build_opener


ORG = "ncx"
SITE_ID = "d88d241d-a727-49c9-9fbb-521595a4eaa5"
EXISTING_VPC_ID = "2b799d5e-1174-436c-af42-5bff0ff74b6b"
API_URL = "https://nico-rest-api-nico-rest.apps.nico-hub.nvidialaunchpad.internal"
TOKEN_URL = (
    "https://keycloak-rhbk-operator.apps.nico-hub.nvidialaunchpad.internal"
    "/realms/nico/protocol/openid-connect/token"
)


def request_json(opener, request):
    try:
        with opener.open(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as exc:
        raise RuntimeError(f"{request.get_method()} {request.full_url} returned HTTP {exc.code}") from None
    except URLError as exc:
        raise RuntimeError(f"could not reach {request.full_url}: {exc.reason}") from None


def main():
    credential_dir = Path.home() / ".local/share/nico-pilot"
    ca_file = credential_dir / "ca-bundle.crt"
    secret_file = credential_dir / "ncx-service-secret.txt"
    if not ca_file.is_file() or not secret_file.is_file():
        raise RuntimeError(f"pilot CA or client secret is missing from {credential_dir}")

    context = ssl.create_default_context(cafile=str(ca_file))
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
    token_request = Request(
        TOKEN_URL,
        data=urlencode(
            {
                "grant_type": "client_credentials",
                "client_id": "ncx-service",
                "client_secret": secret_file.read_text().strip(),
            }
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    token = request_json(opener, token_request).get("access_token")
    if not token:
        raise RuntimeError("NICo token response had no access token")

    def get(path):
        req = Request(
            f"{API_URL}/v2/org/{ORG}/nico/{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        return request_json(opener, req)

    operating_systems = get("operating-system?pageNumber=1&pageSize=100")
    if isinstance(operating_systems, dict):
        if "items" not in operating_systems:
            raise RuntimeError("NICo Operating System list had an unexpected response shape")
        operating_systems = operating_systems["items"]
    if not isinstance(operating_systems, list):
        raise RuntimeError("NICo Operating System list was not an array")
    for entry in operating_systems:
        associations = entry.get("siteAssociations") or []
        print(json.dumps({
            "kind": "operating_system",
            "id": entry.get("id"),
            "name": entry.get("name"),
            "status": entry.get("status"),
            "type": entry.get("type"),
            "site_status": [a.get("status") for a in associations
                            if (a.get("site") or {}).get("id") == SITE_ID],
        }))
    if not operating_systems:
        print(json.dumps({"kind": "operating_systems", "count": 0}))

    vpc = get(f"vpc/{EXISTING_VPC_ID}")
    print(json.dumps({
        "kind": "existing_vpc",
        "id": vpc.get("id"),
        "status": vpc.get("status"),
        "siteId": vpc.get("siteId"),
        "routingProfile": vpc.get("routingProfile"),
        "networkVirtualizationType": vpc.get("networkVirtualizationType"),
    }))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
