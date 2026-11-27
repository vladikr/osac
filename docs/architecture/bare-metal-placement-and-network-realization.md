# Bare-metal placement and network realization: first implementation slice

This draft follows the [OSAC-7351 working design](https://redhat.atlassian.net/browse/OSAC-7351). It adds two **private Fulfillment API** records. They are not Kubernetes CRDs and are never selected by tenants. `NetworkClass.fabricManager` continues to select the ordinary fabric manager; the NICo adapter is invoked only after a NICo capacity target has been selected for a BMI.

## Record contracts

`BareMetalPlacementTarget` registers an OSAC tenant and bare-metal instance type against stable provider capacity and network configuration references, with a site where that is known before allocation. Several targets may serve the same tenant and type. Its status starts unready; a later validator must check the referenced configuration, remote capacity, address entitlement, and site fabric prerequisites, then save a fingerprint and observed IP Block CIDR. A target is selectable only when that validation is current and Ready.

`NetworkRealization` stores one VirtualNetwork or Subnet intent for an OSAC tenant, site, and network configuration. A VirtualNetwork record corresponds to a provider VPC; a Subnet record references its parent and corresponds to an exact CIDR Prefix. The database has unique keys for both kinds, so concurrent BMI requests cannot create separate *intent records* for the same network. A record starts Pending with a stable provider name and no remote ID. The reconciler must persist this intent before calling NICo, then save the verified remote ID and observed CIDR. An ambiguous POST result must be resolved by a unique lookup with ownership checks, or the record remains Unknown for operator resolution. It must never be retried as an unconditional second POST.

An adopted resource records its provider ID in the immutable spec; an OSAC-created resource obtains its ID only after creation. Ownership determines deletion behavior. A realization can be removed from Fulfillment only after its state is Deleted. Network realizations outlive each BMI and are removed in the Subnet and VirtualNetwork deletion paths, Prefix before VPC. They retain the OSAC tenant even when multiple OSAC tenants share one NICo tenant.

## Scope of this slice

This branch introduces the private types, CRUD handlers, REST registration, tenant-scoped tables, and basic intent/identity validation. It does **not** yet route provisioning through these records. The existing pilot ConfigMap and AWX path remain active. `Ready` and `Deleted` status transitions are not yet backed by a remote reconciler; therefore these records must not be used as a placement or cleanup authority until the follow-up control loop is implemented.

The next vertical slice must:

1. Define provider and network configuration records or an explicit reference to the existing `NICO_*` instance-group configuration, without storing credentials in these objects.
2. Validate targets through a provider-scoped job, including site/IP Block identity, address entitlement, capacity, and attested fabric prerequisites; ensure only that controller can advance Ready status.
3. Select and pin a target in the effective BMI Create and dry-run path, reject an incompatible Subnet early, and keep the ordinary inventory path available. The real Create path must make the attachment-domain claim atomic.
4. Reconcile VPC and Prefix intent through NICo with safe ambiguous-result handling, parent validation, reuse, and exact CIDR checks; pass the Prefix ID to NICo Instance create.
5. Guard target and realization references in the database and coordinate BMI and network-parent finalizers. Deleting a BMI must not delete its VN/Subnet realizations. A later Subnet or VN deletion must clean owned remote resources in order, while adopted resources remain provider-owned.
6. Exercise multi-tenant isolation, concurrent creates, adoption, retries, deletion, and actual GB300 boot and network reachability in the Launchpad environment.
