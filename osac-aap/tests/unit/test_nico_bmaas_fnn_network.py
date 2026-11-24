"""Automatic FNN realization must use exact OSAC CIDRs and stable ownership."""

import importlib.util
from pathlib import Path

import pytest


MODULE_PATH = (
    Path(__file__).resolve().parents[2]
    / "collections/ansible_collections/nico/steps/plugins/modules/bare_metal_instance.py"
)
SPEC = importlib.util.spec_from_file_location("nico_fnn_bmi", MODULE_PATH)
nico = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nico)


def params(**overrides):
    values = {
        "osac_tenant_id": "tenant1",
        "osac_virtual_network_id": "01a1a8f1-de09-7d30-90ab-53e334041385",
        "osac_subnet_id": "01a1a8f2-22c6-7324-9e28-8e38fd878f3e",
        "osac_subnet_cidr": "10.180.65.0/24",
        "site_id": "site-id",
        "ip_block_id": "tenant-block-id",
        "tenant_id": "nico-tenant-id",
        "vpc_id": "",
        "vpc_prefix_id": "",
        "subnet_id": "",
        "flat_ipv4_cidr": "",
        "routing_profile": "external",
        "timeout": 1,
        "poll_interval": 1,
    }
    values.update(overrides)
    return values


class FakeClient:
    def __init__(self, parameters):
        self.params = parameters
        self.vpc = None
        self.prefix = None
        self.posts = []

    def request(self, scope, method, path, body=None):
        assert scope == "tenant"
        if method == "GET" and path == "ipblock/tenant-block-id":
            return 200, {"id": "tenant-block-id", "status": "Ready", "siteId": "site-id",
                         "tenantId": "nico-tenant-id", "prefix": "10.180.64.0", "prefixLength": 20}
        if method == "GET" and path.startswith("vpc-prefix?"):
            return 200, [self.prefix] if self.prefix else []
        if method == "GET" and path.startswith("vpc-prefix/"):
            if self.prefix:
                return 200, self.prefix
            raise nico.NicoHTTPError(404, "not found")
        if method == "GET" and path.startswith("vpc/"):
            if self.vpc:
                return 200, self.vpc
            raise nico.NicoHTTPError(404, "not found")
        if method == "POST" and path == "vpc":
            self.posts.append((path, body))
            self.vpc = {**body, "tenantId": "nico-tenant-id", "status": "Ready"}
            return 201, self.vpc
        if method == "POST" and path == "vpc-prefix":
            self.posts.append((path, body))
            self.prefix = {**body, "id": "prefix-id", "siteId": "site-id", "status": "Ready"}
            return 201, self.prefix
        raise AssertionError((scope, method, path, body))


def test_creates_exact_prefix_once_and_reuses_it():
    client = FakeClient(params())

    first = nico.ensure_fnn_network(client)
    second = nico.ensure_fnn_network(client)

    assert first == second == (client.vpc["id"], "prefix-id")
    assert [path for path, _ in client.posts] == ["vpc", "vpc-prefix"]
    assert client.posts[0][1]["networkVirtualizationType"] == "FNN"
    assert client.posts[0][1]["labels"] == {
        "osacTenant": "tenant1", "osacVirtualNetworkId": client.params["osac_virtual_network_id"]}
    assert client.posts[1][1] == {
        "name": "osac-" + client.params["osac_subnet_id"],
        "vpcId": client.vpc["id"], "ipBlockId": "tenant-block-id", "prefix": "10.180.65.0/24"}


def test_rejects_out_of_block_before_any_create():
    client = FakeClient(params(osac_subnet_cidr="10.181.65.0/24"))
    with pytest.raises(nico.NicoError, match="outside"):
        nico.ensure_fnn_network(client)
    assert client.posts == []


def test_rejects_vpc_with_different_osac_owner():
    client = FakeClient(params())
    vpc_id = nico._stable_vpc_id("tenant1", client.params["osac_virtual_network_id"], "site-id")
    client.vpc = {
        "id": vpc_id, "name": "osac-" + client.params["osac_virtual_network_id"],
        "labels": {"osacTenant": "someone-else"}, "tenantId": "nico-tenant-id",
        "siteId": "site-id", "networkVirtualizationType": "FNN", "status": "Ready"}
    with pytest.raises(nico.NicoError, match="identity, owner"):
        nico.ensure_fnn_network(client)
    assert client.posts == []


def test_ambiguous_vpc_create_is_recovered_by_stable_id():
    client = FakeClient(params())
    original = client.request

    def uncertain(scope, method, path, body=None):
        if (method, path) == ("POST", "vpc"):
            original(scope, method, path, body)
            raise nico.NicoError("connection closed")
        return original(scope, method, path, body)

    client.request = uncertain
    assert nico.ensure_fnn_network(client)[1] == "prefix-id"
    assert [path for path, _ in client.posts] == ["vpc", "vpc-prefix"]


def test_rejects_mismatched_existing_prefix():
    client = FakeClient(params())
    nico.ensure_fnn_network(client)
    client.prefix["prefix"] = "10.180.66.0/24"
    with pytest.raises(nico.NicoError, match="exact CIDR"):
        nico.ensure_fnn_network(client)
    assert [path for path, _ in client.posts] == ["vpc", "vpc-prefix"]


def test_instance_create_uses_the_new_exact_prefix():
    class InstanceClient(FakeClient):
        def request(self, scope, method, path, body=None):
            if (method, path) == ("GET", "operating-system/os-id"):
                return 200, {
                    "id": "os-id", "status": "Ready", "type": "TemplatedIpxe",
                    "ipxeTemplateParameters": [{"value": "nocloud-net;s=${tenant-cloudinit-url}"}],
                    "siteAssociations": [{"site": {"id": "site-id"}, "status": "Synced"}],
                }
            if (method, path) == ("GET", "instance?name=osac-bmi-uid"):
                return 200, []
            if (method, path) == ("POST", "instance"):
                self.posts.append((path, body))
                return 201, {"id": "instance-id"}
            if (method, path) == ("GET", "instance/instance-id"):
                return 200, {
                    "id": "instance-id", "status": "Ready", "tenantId": "nico-tenant-id",
                    "vpcId": self.vpc["id"], "instanceTypeId": "type-id", "machineId": "machine-id",
                    "labels": {"osacBmiUid": "bmi-uid"},
                    "interfaces": [{"vpcPrefixId": "prefix-id", "ipAddresses": ["10.180.65.5"]}],
                }
            return super().request(scope, method, path, body)

    client = InstanceClient(params(
        name="osac-bmi-uid", bmi_uid="bmi-uid", instance_type_id="type-id",
        target_machine_id="", fnn_auto_create=True, network_virtualization_type="FNN",
        operating_system_id="os-id", user_data="", ssh_public_key="",
        phone_home_enabled=True, instance_id="", machine_id="", create_allowed=True))

    result = nico.ensure_present(client)

    assert result["vpc_id"] == client.vpc["id"]
    assert result["vpc_prefix_id"] == "prefix-id"
    assert result["ip_address"] == "10.180.65.5"
    assert [path for path, _ in client.posts] == ["vpc", "vpc-prefix", "instance"]
    assert client.posts[2][1]["interfaces"] == [{"isPhysical": True, "vpcPrefixId": "prefix-id"}]
