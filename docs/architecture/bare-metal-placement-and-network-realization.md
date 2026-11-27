# Bare-metal placement and network realization: FNN pilot implementation

This draft follows the [OSAC-7351 working design](https://redhat.atlassian.net/browse/OSAC-7351). It adds two **private Fulfillment API** records. They are not Kubernetes CRDs and are never selected by tenants. `NetworkClass.fabricManager` continues to select the ordinary fabric manager; the NICo adapter is invoked only after a NICo capacity target has been selected for a BMI.

## Record contracts

A `BareMetalPlacementTarget` registers an OSAC tenant's access to a site through a provider and network configuration. The provider admin maps each OSAC hardware offering at the target to one NICo Instance Type. Each NICo Instance Type identifies a pool of machines. Different pools at the site can share the same FNN network configuration.

### One site with two offerings

The first mapping below is the deployed Launchpad GB300 offering. The second is illustrative. The pilot seed installs only the GB300 entry.

```yaml
kind: BareMetalPlacementTarget
id: nico-gb300-fnn-nvl72
spec:
  osac_tenant_id: tenant1
  site_id: d88d241d-a727-49c9-9fbb-521595a4eaa5
  provider_config_ref: nico-gb300-pool-nvl72
  network_config_ref: nico-fnn-nvl72-site
  instance_type_mappings:
    - osac_instance_type_id: nico-gb300-nvl72
      nico_instance_type_id: fce88359-c3bc-48b7-8029-b0f4466a2538
    - osac_instance_type_id: example-second-offering
      nico_instance_type_id: 00000000-0000-4000-8000-000000000002
```

The pilot validator reads the site's IP Block and, for each mapped pool, verifies a Ready NICo Instance Type at the site and a Registered compute allocation to the configured NICo tenant. Provider visibility alone does not establish tenant entitlement. The admin owns the catalog-to-pool choice. Discovery checks that choice without creating catalog entries. Ready describes the validated configuration. Machine availability is determined at allocation time.

Editing the mappings clears Ready until validation succeeds. A future BMI selects using the new mappings. An admitted BMI retains its provider pool in private status, including across reconcile retries. Adding an offering does not create another credential, VPC, or subnet prefix. If several Ready targets cover the same type and subnet, admission reports the ambiguity.

`NetworkRealization` stores one VirtualNetwork or Subnet intent for an OSAC tenant, site, and network configuration. A VirtualNetwork record corresponds to a provider VPC; a Subnet record references its parent and corresponds to an exact CIDR Prefix. The database has unique keys for both kinds, so concurrent BMI requests cannot create separate *intent records* for the same network. A record starts Pending with a stable provider name and no remote ID. The reconciler must persist this intent before calling NICo, then save the verified remote ID and observed CIDR. An ambiguous POST result must be resolved by a unique lookup with ownership checks, or the record remains Unknown for operator resolution. It must never be retried as an unconditional second POST.

An adopted resource records its provider ID in the immutable spec; an OSAC-created resource obtains its ID only after creation. Ownership determines deletion behavior. A realization can be removed from Fulfillment only after its state is Deleted. Network realizations outlive each BMI and are removed in the Subnet and VirtualNetwork deletion paths, Prefix before VPC. They retain the OSAC tenant even when multiple OSAC tenants share one NICo tenant.

## Wired create flow

The private types, CRUD handlers, REST registration, and tenant-scoped tables are now connected to the FNN pilot create path:

1. BMI Create and dry-run resolve the effective instance type and Subnet, then select exactly one Ready target whose observed IP Block contains the exact Subnet CIDR. Real Create pins target ID, NICo Instance Type ID, site, configuration references, and validation fingerprint in private BMI status. Ordinary inventory BMIs continue through their existing path.
2. Before projecting a NICo BMI CR to Kubernetes, the Fulfillment BMI reconciler persists stable VirtualNetwork and Subnet realization intents. Their unique database keys prevent duplicate intent records; stable IDs permit recovery after an ambiguous create response. The CR carries the pinned target and intent IDs.
3. BMF matches the pinned target to the provider-owned credential binding and passes the pinned NICo Instance Type as an AWX extra variable, together with the selected site and intent IDs to the NICo AAP job. The job checks the site and uses the existing NICo adapter's unique VPC/Prefix lookup, ownership checks, exact CIDR validation, and create-or-reuse behavior. It does not accept a tenant-supplied backend ID.
4. BMF saves the provider VPC and Prefix IDs returned by the successful job. Fulfillment records them on the two realizations before reporting the reconciled BMI. BMI deletion continues to release only the NICo Instance and Machine, retaining shared network realizations.

`seed-nico-bmi-pilot.sh` registers the private target and `configure-nico-fnn-pilot.py` binds its AWX credential by OSAC tenant and target ID. The latter calls `validate-nico-placement-target.sh`, which checks the NICo IP Block and each approved pool allocation before marking the target Ready. This is pilot configuration, not the final `network-fulfillment-ig` credential contract.

## Remaining work before production

The create flow is wired, but the following design requirements are still open:

1. Replace the pilot AWX credential and one-time target validation with provider-scoped `network-fulfillment-ig` configuration, a periodic target validator, and access control so an arbitrary private API caller cannot mark a target Ready. Check capacity, address entitlement, fabric attestation, and drift.
2. Make Subnet attachment-domain claims atomic across NICo BMIs, ordinary inventory BMIs, and VMs; test concurrent BMI Create and multiple eligible targets.
3. Reconcile VPC/Prefix independently of the BMI job, including explicit adoption and recovery of partially completed jobs. Today a failed job may leave a Pending realization even when NICo has a VPC or Prefix; the next create can recover by the stable provider identity.
4. Coordinate Subnet and VirtualNetwork deletion with ordered remote Prefix then VPC cleanup. The current realization Delete handler requires a DELETED state, but no remote deletion controller sets it yet. Do not delete network parents with live provider resources.
5. Prove SecurityGroup enforcement, multi-tenant Ethernet/InfiniBand/NVLink isolation, and the full create/reuse/delete path on GB300 hardware. The pilot still accepts an explicit unenforced-SG override.
