# NICo FNN network realization pilot

This branch extends the existing NICo BareMetalInstance pilot. When enabled for
an AWX NICo BMI credential, the create job reads the referenced OSAC Subnet and
parent VirtualNetwork, verifies their tenant and Ready state, checks that the
exact Subnet CIDR fits a Ready **derived tenant** NICo IP Block, and creates or
reuses one FNN VPC and one exact-CIDR VPC Prefix before creating the NICo
Instance. The VPC identity is stable for the OSAC tenant, VirtualNetwork, and
NICo Site; an existing VPC must carry matching OSAC ownership labels. A Prefix
is reused only when its parent VPC, Site, IP Block, and exact CIDR match.

The opt-in path uses the pilot's existing AWX BMI credential and job. It is a
control-plane test, **not** the final `BareMetalPlacementTarget` /
`NetworkRealization` implementation. It does not change `NetworkClass` or make
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

## Launchpad setup

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
   free_cidr='10.180.66.0/24' # Example only: verify this CIDR is free in the derived block
   osac create virtualnetwork --name nico-fnn-test-vpc --ipv4-cidr "$free_cidr"
   osac create subnet --name nico-fnn-test-subnet \
     --virtual-network nico-fnn-test-vpc --ipv4-cidr "$free_cidr"
   osac create securitygroup --name nico-fnn-test-sg \
     --virtual-network nico-fnn-test-vpc \
     --egress protocol=all,ipv4-cidr=0.0.0.0/0
   osac get virtualnetworks nico-fnn-test-vpc
   osac get subnets nico-fnn-test-subnet
   osac get securitygroups nico-fnn-test-sg
   ```

4. Use the NICo AWX BMI credential bound to this tenant and OSAC InstanceType.
   A new Subnet within the configured derived tenant IP Block needs no new
   credential or ConfigMap entry. The credential supplies:

   | Environment variable | Value |
   | --- | --- |
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

5. Add a `version: 3` entry for the OSAC tenant and InstanceType to the
   `osac-nico-tenant-bindings` ConfigMap, if one is not already present. Its
   `credentialIDs` must include the AWX Kubernetes credential and NICo
   credential. Map the
   `centos-stream-10` DiskImage ID to the validated NICo Operating System
   `3403dd3c-83c3-474a-b62b-1aeaddf81ac4`. The operator selects the
   credential from this exact tenant/InstanceType binding. The pilot catalog seed
   script registers the same tenant-scoped DiskImage record used in the
   original Launchpad pilot.

   The DiskImage record points to the pinned CentOS Stream 10 aarch64 QCOW2
   at `http://172.16.2.122/osac/CentOS-Stream-GenericCloud-10-20261103.0.aarch64.qcow2`,
   matching the NICo Operating System's `image_url`. Its `source_type` is
   `SOURCE_TYPE_REGISTRY` because that is the only type the current OSAC API
   supports; this is a pilot representation gap, not an OCI installation.

   On the isolated Launchpad VM described here, after verifying the IDs and
   source URL, `python3 osac-installer/scripts/dev-full/configure-nico-fnn-pilot.py`
   creates the dedicated AWX credential and this binding. It discovers the
   AWX Kubernetes credential ID and creates the two BMF configuration Secrets.
   The helper reads the NICo CA and client secret from
   `$HOME/.local/share/nico-pilot/` and never puts their values in the binding.
   It does not enable BMF or create a NICo resource. Its fixed Site, IP Block,
   and OS IDs are specific to this test environment. The printed Subnet ID is
   only the example used by the demo; it is not part of the binding.
   On an existing version 2 pilot, wait for every NICo BMI to finish deletion
   before replacing the binding ConfigMap. The helper uses a new AWX credential
   type and credential name for version 3, leaving the old credential available
   until those deletes finish. It refuses to overwrite a different ConfigMap;
   inspect and remove the old pilot ConfigMap after the drain, then rerun it.

6. On the Launchpad pilot VM, deploy this branch from the contributor fork:

   ```bash
   git -C "$HOME/src/osac" fetch https://github.com/vladikr/osac.git \
     osac-7351-nico-fnn-pilot
   git -C "$HOME/src/osac" switch -c osac-7351-nico-fnn-pilot FETCH_HEAD
   export KUBECONFIG="$HOME/.kube/osac-dev-kind-root.kubeconfig"
   make -C "$HOME/src/osac/osac-installer" redeploy-nico-pilot \
     PLATFORM=kind PROFILE=dev-full NS=osac NICO_PILOT_ENABLE_BMF=yes \
     NICO_PILOT_BRANCH=osac-7351-nico-fnn-pilot
   ```

   If the branch already exists on that VM, switch to it and use the same
   `make` command. The redeploy target requires a clean working tree. Check
   the AWX project sync and BMF rollout after deployment.

## Test and observe

Create a BMI with the seeded NICo catalog item, approved DiskImage, and new
Subnet/SG IDs. Use the same SSH key and instance type as the proven BMI pilot:

```bash
pilot_key='/path/to/public-key.pub'
subnet_id='<new-subnet-id>'
sg_id='<new-sg-id>'
osac create baremetalinstance \
  --catalog-item 01a21a54-a3eb-717b-8b42-7f52dc339330 \
  --name nico-fnn-test --instance-type nico-gb300-nvl72 \
  --disk-image centos-stream-10 --ssh-key "$(cat "$pilot_key")" \
  --network-attachment \
  "subnet=$subnet_id,interface=data-0,primary,security-groups=$sg_id"
osac get baremetalinstances nico-fnn-test
```

Inspect the `bmi-<BMI-ID>` CR's `status.provisioningJobs` and `nicoInstanceID` /
`nicoMachineID`. The AWX provision job artifacts include `nicoVpcID` and
`nicoVpcPrefixID`. Confirm in NICo that the VPC has the OSAC ownership labels,
the Prefix has the exact OSAC Subnet CIDR, the Instance uses that Prefix, and
the Machine reaches Ready after OSAC deletion. Creating a second BMI on the
same Subnet should reuse the VPC/Prefix (when capacity permits).

On BMI delete, NICo releases the Instance and the original Machine returns to
Ready. The VPC/Prefix remain for reuse. Network deletion and durable shared
realization records are follow-up work; remove test network resources only
after verifying no BMI or NICo Instance still references them.
