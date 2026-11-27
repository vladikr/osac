# NICo FNN network realization pilot

This branch extends the existing NICo BareMetalInstance pilot. When enabled for
an AWX NICo BMI credential, the create job reads the referenced OSAC Subnet and
parent VirtualNetwork, verifies their tenant and Ready state, checks that the
exact Subnet CIDR fits a Ready **derived tenant** NICo IP Block, and creates or
reuses one FNN VPC and one exact-CIDR VPC Prefix before creating the NICo
Instance. The VPC identity is stable for the OSAC tenant, VirtualNetwork, and
NICo Site; an existing VPC must carry matching OSAC ownership labels. A Prefix
is reused only when its parent VPC, Site, IP Block, and exact CIDR match.

The opt-in path uses the pilot's existing AWX BMI credential and job, now with
private `BareMetalPlacementTarget` selection and persistent VirtualNetwork and
Subnet `NetworkRealization` intents. This remains a control-plane pilot. It does not change `NetworkClass` or make
NICo the OSAC Fabric Manager. It does not coordinate Netris and NICo data-plane
connectivity, enforce SecurityGroups on NICo, or clean up shared VPCs and
Prefixes when an OSAC network is deleted. Existing pre-created VPC/Prefix
credentials continue to work when the new flag is off.

## What the Launchpad test proves

The default `k8s_only` NetworkClass realizes the OSAC VirtualNetwork and
Subnet through Kubernetes networking. Their `Ready` state proves that path,
not that NICo has a VPC yet. The first NICo-backed BMI then triggers the
FNN VPC/Prefix creation. Verify the chain at each boundary:

1. The OSAC VirtualNetwork and Subnet reach `Ready`, and the Subnet CR has the
   requested CIDR and parent VirtualNetwork ID.
2. The AWX BMI job reports the NICo VPC/Prefix IDs. NICo reports an FNN VPC
   with the OSAC ownership labels and a Ready Prefix with the exact Subnet
   CIDR, derived tenant IP Block, and parent VPC.
3. The NICo Instance uses that Prefix; the installed OS phones home, OSAC
   reports `RUNNING` and the NICo-assigned IP, and the host accepts SSH from a
   site-approved access path. Delete the BMI and verify that its Instance is
   absent and its Machine returns to unassigned `Ready`.

This test does **not** prove a shared data plane between Kubernetes VMs,
inventory bare metal, and NICo trays. It also does not exercise the Netris
backend. To validate the complete Netris-plus-NICo network, use a Netris
controller that manages the Launchpad site's actual fabric and a documented
routing/ownership contract for the NICo FNN tenant CIDRs. Then test traffic
between a Netris-connected workload and a NICo tray, external/service return
paths, isolation, and policy enforcement. A separate simulated Netris fabric
can test OSAC's Netris API workflow but cannot establish those site-level
properties for the real GB300 trays.

## Upgrade the existing Launchpad VM

Run as `cloud-user` on `osac-nico-fnn-pilot`. Finish any in-flight BMI deletion
first. This upgrade reuses the existing Kind cluster, OSAC releases, NICo CA
and client secret. On CentOS, install `python3-pyyaml` if `python3 -c 'import yaml'`
fails.

```bash
cd "$HOME/src/osac"
git fetch https://github.com/vladikr/osac.git osac-7351-nico-fnn-pilot
git switch osac-7351-nico-fnn-pilot
git merge --ff-only FETCH_HEAD
export KUBECONFIG="$HOME/.kube/osac-dev-kind-root.kubeconfig"
make -C osac-installer upgrade-nico-fnn-pilot PLATFORM=kind PROFILE=dev-full NS=osac
bash osac-installer/scripts/dev-full/validate-nico-placement-target.sh --show
```

The upgrade builds and loads all four images, upgrades Helm, seeds the
private target and existing catalog, switches the pilot binding to the new AWX
credential, and validates the NICo tenant IP Block. The target should show
`id=nico-gb300-fnn-nvl72`, `status.ready=true` and
`status.observed_ip_block_cidr=10.181.0.0/24`. The credential binding now
selects `tenant1` and its placement target. Confirm `spec.instance_type_mappings` contains the GB300 mapping. Older binding rows remain available for previously admitted BMIs.

## Prepare the validation network

1. Verify the NICo Site's FNN routing profile, parked-pool routing, and
   services return path with the site operator. The REST API cannot attest the
   Core TOML and fabric blackhole routes.
2. Inspect the NICo tenant IP Block and existing Prefixes. The block passed to
   this pilot must have `status=Ready`, the expected NICo `tenantId` and
   `siteId`, and enough free address space. Use the **derived tenant** block
   (root block → allocation → derived tenant block). The existing
   `10.180.65.0/24` Prefix is already reserved; choose another nonoverlapping
   CIDR inside the derived block. Do not delete the existing Prefix just to
   run this test.
3. As `tenant1_user` on the OSAC pilot VM, create a new OSAC VirtualNetwork,
   Subnet and SecurityGroup for the selected CIDR. For example:

   ```bash
   free_cidr='10.181.0.48/28' # Use only if confirmed free in OSAC and NICo
   osac create virtualnetwork --name nico-fnn-placement-vpc --ipv4-cidr "$free_cidr"
   osac create subnet --name nico-fnn-placement-subnet \
     --virtual-network nico-fnn-placement-vpc --ipv4-cidr "$free_cidr"
   osac create securitygroup --name nico-fnn-placement-sg \
     --virtual-network nico-fnn-placement-vpc \
     --egress protocol=all,ipv4-cidr=0.0.0.0/0
   osac get virtualnetworks nico-fnn-placement-vpc
   osac get subnets nico-fnn-placement-subnet
   osac get securitygroups nico-fnn-placement-sg
   ```

## Configuration applied by the upgrade

The helper configures one NICo AWX BMI credential for the OSAC tenant and placement target.
A new Subnet inside the validated IP Block needs no credential change.
The BMI supplies the pinned NICo Instance Type ID at job launch. Use these fields in the
AWX custom credential type's environment injector and supply their values
on the credential:

| Environment variable | Value |
| --- | --- |
| `NICO_BMAAS_OSAC_SUBNET_ID` | Empty; the job reads the BMI Subnet |
| `NICO_BMAAS_NETWORK_VIRTUALIZATION_TYPE` | `FNN` |
| `NICO_BMAAS_FNN_AUTO_CREATE` | `true` |
| `NICO_BMAAS_SITE_ID` | NICo Site UUID (`d88d241d-a727-49c9-9fbb-521595a4eaa5` in the lab) |
| `NICO_BMAAS_IP_BLOCK_ID` | Ready derived tenant IP Block UUID |
| `NICO_BMAAS_ROUTING_PROFILE` | Validated NICo FNN routing profile (for example `external`) |
| `NICO_BMAAS_VPC_ID`, `NICO_BMAAS_VPC_PREFIX_ID`, `NICO_BMAAS_SUBNET_ID` | Empty |
| `NICO_BMAAS_PILOT_ALLOW_UNENFORCED_SECURITY_GROUPS` | `true` only for this isolated pilot |

The SecurityGroup override is explicit because the OSAC API requires a
group for this nondefault network, while this pilot cannot attest that a
corresponding NICo NSG is enforced. Do not present this as a firewall test.
Keep all tokens and client secrets in AWX, never in the binding ConfigMap.

The seed script registers private target `nico-gb300-fnn-nvl72` for `tenant1`, OSAC type
`nico-gb300-nvl72`, the NICo site, and provider/network configuration references.
The validation script checks the derived tenant IP Block, mapped pool readiness and compute allocation before marking the target Ready.
The `version: 2` binding names this target and the OSAC tenant, with the
AWX Kubernetes and NICo credential IDs. Map the
`centos-stream-10` DiskImage ID to the validated NICo Operating System
`3403dd3c-83c3-474a-b62b-1aeaddf81ac4`. Create and dry-run reject a BMI
whose selected Subnet falls outside the target's observed IP Block. The pilot catalog seed
script registers the same tenant-scoped DiskImage record used in the
original Launchpad pilot.

The DiskImage record points to the pinned CentOS Stream 10 aarch64 QCOW2
at `http://172.16.2.122/osac/CentOS-Stream-GenericCloud-10-20261103.0.aarch64.qcow2`,
matching the NICo Operating System's `image_url`. Its `source_type` is
`SOURCE_TYPE_REGISTRY` because that is the only type the current OSAC API
supports; this is a pilot representation gap, not an OCI installation.

On the isolated Launchpad VM described here, after verifying the IDs and
source URL, `seed-nico-bmi-pilot.sh` registers the target and
`python3 osac-installer/scripts/dev-full/configure-nico-fnn-pilot.py`
creates the dedicated AWX credential and binding, then validates the target.
It discovers the
AWX Kubernetes credential ID and creates the two BMF configuration Secrets.
The helper reads the NICo CA and client secret from
`$HOME/.local/share/nico-pilot/` and never puts their values in the binding.
It does not enable BMF or create a NICo resource. Its fixed Site,
IP Block, and OS IDs are specific to this test environment.

## Test and observe

Create a BMI with the seeded NICo catalog item, approved DiskImage, and new
Subnet/SG IDs. Use the same SSH key and instance type as the proven BMI pilot:

```bash
pilot_key="$HOME/.ssh/nico-fnn-pilot.pub"
subnet_id=$(osac get subnets nico-fnn-placement-subnet -o json | jq -er .id)
sg_id=$(osac get securitygroups nico-fnn-placement-sg -o json | jq -er .id)
catalog_id=$(osac get baremetalinstancecatalogitems nico-gb300-fnn-pilot -o json | jq -er .id)
osac create baremetalinstance \
  --catalog-item "$catalog_id" --name nico-fnn-placement-test \
  --instance-type nico-gb300-nvl72 --disk-image centos-stream-10 \
  --ssh-key "$(cat "$pilot_key")" \
  --network-attachment "subnet=$subnet_id,interface=data-0,primary,security-groups=$sg_id"
bmi_id=$(osac get baremetalinstances nico-fnn-placement-test -o json | jq -er .id)
```

After the BMI CR appears, run the following during provisioning and again once
OSAC reports `RUNNING`. The inspector follows the two realization IDs on this
specific BMI. It reads the private Fulfillment API using the controller
credential on the pilot VM.

```bash
bash osac-installer/scripts/dev-full/validate-nico-placement-target.sh --show "$bmi_id"
kubectl -n osac get baremetalinstance "bmi-$bmi_id" -o json |
  jq '.status | {phase,nicoInstanceID,nicoMachineID,nicoVpcID,nicoVpcPrefixID,provisioningJobs}'
osac get baremetalinstances "$bmi_id" -o json |
  jq '.status | {state,network_attachment_statuses}'
```

For a fresh network, expect two Pending records during provisioning. On success
both become Ready. The Prefix record's `spec.parent_realization_id` should
equal the VPC record's ID. Compare the two `status.backend_resource_id` values
with the BMI's `nicoVpcID` and `nicoVpcPrefixID`. On the control plane with
`nicocli`, use the reported IDs to check the actual provider objects:

```bash
nicocli --org ncx vpc get "$vpc_id" | jq '{id,status,routingProfile,networkVirtualizationType,labels}'
nicocli --org ncx vpc-prefix list | jq --arg id "$prefix_id" '.[] | select(.id == $id) | {id,vpcId,prefix,ipBlockId,status}'
nicocli --org ncx instance get "$instance_id" | jq '{id,status,machineId,vpcId,interfaces}'
```

On the pilot VM, verify the reported IP and OS:

```bash
ip=$(osac get baremetalinstances "$bmi_id" -o json |
  jq -er '.status.network_attachment_statuses[] | select(.primary) | .ip_address')
ssh -i "$HOME/.ssh/nico-fnn-pilot" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "cloud-user@$ip" 'hostname; . /etc/os-release; echo "$PRETTY_NAME"; uname -m'
```

When finished with the host, release it and wait for the BMI finalizers:

```bash
osac delete baremetalinstances "$bmi_id"
kubectl -n osac wait --for=delete "baremetalinstance/bmi-$bmi_id" --timeout=45m
```

On BMI delete, NICo releases the Instance and the original Machine returns to
Ready. The VPC/Prefix and realization records remain for reuse. Parent-network
deletion cleanup is follow-up work; remove test network resources only
after verifying no BMI or NICo Instance still references them.
