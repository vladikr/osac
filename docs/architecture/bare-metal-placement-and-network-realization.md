# Bare-metal placement and network realization: FNN pilot implementation

This draft follows the [OSAC-7351 working design](https://redhat.atlassian.net/browse/OSAC-7351). It adds two **private Fulfillment API** records. They are not Kubernetes CRDs and are never selected by tenants. `NetworkClass.fabricManager` continues to select the ordinary fabric manager; the NICo adapter is invoked only after a NICo capacity target has been selected for a BMI.

## Record contracts

`BareMetalPlacementTarget` registers an OSAC tenant and bare-metal instance type against stable provider capacity and network configuration references, with a site known before allocation. Several targets may serve the same tenant and type. Its status starts unready. The Launchpad setup validates the NICo tenant IP Block and records its CIDR, time, and fingerprint; a production validator must also watch drift, capacity, address entitlements, and site fabric prerequisites. A target is selectable only when Ready with a recorded observation. If more than one Ready target fits, Create fails until a placement policy is configured.

`NetworkRealization` stores one VirtualNetwork or Subnet intent for an OSAC tenant, site, and network configuration. A VirtualNetwork record corresponds to a provider VPC; a Subnet record references its parent and corresponds to an exact CIDR Prefix. The database has unique keys for both kinds, so concurrent BMI requests cannot create separate *intent records* for the same network. A record starts Pending with a stable provider name and no remote ID. The reconciler must persist this intent before calling NICo, then save the verified remote ID and observed CIDR. An ambiguous POST result must be resolved by a unique lookup with ownership checks, or the record remains Unknown for operator resolution. It must never be retried as an unconditional second POST.

An adopted resource records its provider ID in the immutable spec; an OSAC-created resource obtains its ID only after creation. Ownership determines deletion behavior. A realization can be removed from Fulfillment only after its state is Deleted. Network realizations outlive each BMI and are removed in the Subnet and VirtualNetwork deletion paths, Prefix before VPC. They retain the OSAC tenant even when multiple OSAC tenants share one NICo tenant.

## Wired create flow

The private types, CRUD handlers, REST registration, and tenant-scoped tables are now connected to the FNN pilot create path:

1. BMI Create and dry-run resolve the effective instance type and Subnet, then select exactly one Ready target whose observed IP Block contains the exact Subnet CIDR. Real Create pins target ID, site, configuration references, and validation fingerprint in private BMI status. Ordinary inventory BMIs continue through their existing path.
2. Before projecting a NICo BMI CR to Kubernetes, the Fulfillment BMI reconciler persists stable VirtualNetwork and Subnet realization intents. Their unique database keys prevent duplicate intent records; stable IDs permit recovery after an ambiguous create response. The CR carries the pinned target and intent IDs.
3. BMF matches the pinned target to the provider-owned credential binding and passes the selected site and intent IDs to the NICo AAP job. The job checks the site and uses the existing NICo adapter's unique VPC/Prefix lookup, ownership checks, exact CIDR validation, and create-or-reuse behavior. It does not accept a tenant-supplied backend ID.
4. BMF saves the provider VPC and Prefix IDs returned by the successful job. Fulfillment records them on the two realizations before reporting the reconciled BMI. BMI deletion continues to release only the NICo Instance and Machine, retaining shared network realizations.

`seed-nico-bmi-pilot.sh` registers the private target and `configure-nico-fnn-pilot.py` binds its AWX credential by OSAC type and target ID rather than a particular Subnet. The latter calls `validate-nico-placement-target.sh`, which checks the NICo IP Block before marking the target Ready. This is pilot configuration, not the final `network-fulfillment-ig` credential contract.

## Remaining work before production

The create flow is wired, but the following design requirements are still open:

1. Replace the pilot AWX credential and one-time target validation with provider-scoped `network-fulfillment-ig` configuration, a periodic target validator, and access control so an arbitrary private API caller cannot mark a target Ready. Check capacity, address entitlement, fabric attestation, and drift.
2. Make Subnet attachment-domain claims atomic across NICo BMIs, ordinary inventory BMIs, and VMs; test concurrent BMI Create and multiple eligible targets.
3. Reconcile VPC/Prefix independently of the BMI job, including explicit adoption and recovery of partially completed jobs. Today a failed job may leave a Pending realization even when NICo has a VPC or Prefix; the next create can recover by the stable provider identity.
4. Coordinate Subnet and VirtualNetwork deletion with ordered remote Prefix then VPC cleanup. The current realization Delete handler requires a DELETED state, but no remote deletion controller sets it yet. Do not delete network parents with live provider resources.
5. Prove SecurityGroup enforcement, multi-tenant Ethernet/InfiniBand/NVLink isolation, and the full create/reuse/delete path on GB300 hardware. The pilot still accepts an explicit unenforced-SG override.
