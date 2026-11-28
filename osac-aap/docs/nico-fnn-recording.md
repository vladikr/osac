# One tenant network, from OSAC to a GB300

**Opening narration.** “As an OSAC tenant, I can request VMs, Kubernetes clusters, and bare-metal nodes, including a GB300. I want to define my workload network once and choose the subnet when I request a service. I'll start by creating that network in OSAC. Then I'll request a GB300 and log in to the address it gets on my subnet.”

## Before recording

Use two Bash terminals. **Pilot VM** is `cloud-user@osac-nico-fnn-pilot`, with the OSAC CLI logged in as `tenant1_user`. Use that terminal for both the tenant commands and the clearly labeled admin cutaways. **NICo hub** is the existing `control-plane-2` shell with a working `nicocli --org ncx` session. Authenticate before recording. Keep the shells open so their variables survive camera cuts.

For a **creation** demo, reserve a fresh, nonoverlapping /28 inside the validated `10.181.0.0/24` with the site operator. Check current OSAC network/subnet allocations and NICo prefixes. Confirm a tray is available and the SSH key pair exists on the pilot VM.

If you want a text transcript as well as video, run `script -q "$HOME/fnn-demo-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"` in each terminal **before** setting variables. Use `exit` to finish each transcript.

## 1. Tenant creates the workload network

**Pilot VM · tenant view.** Start recording here. Run the identity check as you deliver the opening narration.

```bash
osac whoami
```

**NICo hub · provider cutaway.** “Where does my subnet range come from? The provider has already allocated this IP block to the NICo tenant used by OSAC tenant1 at this site.”

```bash
block=1adb7f5b-8b3e-4ff3-be0d-96bd99b2dab5
nicocli --org ncx ip-block get "$block" |
  jq '{id,cidr:(.prefix + "/" + (.prefixLength|tostring)),tenantId,siteId,status}'
nicocli --org ncx vpc-prefix list |
  jq --arg block "$block" '[.[] | select(.ipBlockId == $block) | {prefix,vpcId}]'
```

Point to the Ready tenant-owned `10.181.0.0/24` block, its NICo tenant ID `284a8abb-f12f-45b8-b124-4207c35cefb8`, and site `d88d241d-a727-49c9-9fbb-521595a4eaa5`. The provider root block can have the same CIDR and an empty tenant ID. The tenant-owned record establishes which allocation this site configuration can use.

“Our chosen `10.181.0.48/28` spans `10.181.0.48` through `10.181.0.63`, entirely inside that allocation.” Show the existing prefixes in the block so viewers can see which ranges are already claimed. Check for overlap with larger or smaller prefixes as well as an exact match. Later, compare this block CIDR with the placement target’s `status.observed_ip_block_cidr`.

**Pilot VM · tenant view.** Create the demo network. Enter the reserved demo CIDR, `10.181.0.48/28`. Keep the generated name for the rest of the recording.

```bash
read -rp 'Reserved demo CIDR: ' cidr
demo="fnn-demo-$(date +%m%d-%H%M%S)"
osac create virtualnetwork --name "$demo-vpc" --ipv4-cidr "$cidr"
osac create subnet --name "$demo-subnet" --virtual-network "$demo-vpc" --ipv4-cidr "$cidr"
osac create securitygroup --name "$demo-sg" --virtual-network "$demo-vpc" \
  --egress protocol=all,ipv4-cidr=0.0.0.0/0
osac get virtualnetworks "$demo-vpc"
osac get subnets "$demo-subnet" -o json | jq '{id,name:.metadata.name,cidr:.spec.ipv4_cidr,state:.status.state}'
osac get securitygroups "$demo-sg"
```

Wait for all three OSAC objects to report Ready. Hold on the subnet ID and CIDR. The audience will see them again in the instance request and the NICo prefix. The tenant supplies a security group because this OSAC network requires one. NICo security-group enforcement is outside this pilot.

## 2. Admin explains why this subnet can serve a GB300

**Pilot VM · admin view.** “That subnet is inside the site’s validated IP block. Before this tenant created it, I registered the site and its FNN configuration. This mapping tells OSAC which NICo hardware pool fulfills the GB300 offering. The validator checked the pool, the tenant's compute allocation, and the IP block.”

```bash
cd "$HOME/src/osac"
export KUBECONFIG="$HOME/.kube/osac-dev-kind-root.kubeconfig"
inspect=osac-installer/scripts/dev-full/validate-nico-placement-target.sh
bash "$inspect" --show
```

Hold on the actual output: `tenant1`, the mapping from `nico-gb300-nvl72` to `fce88359-c3bc-48b7-8029-b0f4466a2538`, `ready: true`, and `10.181.0.0/24`. Launchpad has one verified mapping. The design allows additional offerings on the same target. The admin already completed this setup on the pilot VM. [Setup steps](nico-fnn-pilot.md#upgrade-the-existing-launchpad-vm)

## 3. Tenant requests one bare-metal instance

**Pilot VM · tenant view.** “Back in my tenant account, I choose the GB300 offering and a CentOS image. For the tray's fabric port, `data-0`, I use the subnet I just created.”

```bash
osac get baremetalinstancecatalogitems nico-gb300-fnn-pilot
osac describe baremetalinstancetype nico-gb300-nvl72
osac get diskimages centos-stream-10
```

```bash
catalog=$(osac get baremetalinstancecatalogitems nico-gb300-fnn-pilot -o json | jq -er .id)
subnet=$(osac get subnets "$demo-subnet" -o json | jq -er .id)
sg=$(osac get securitygroups "$demo-sg" -o json | jq -er .id)
osac create baremetalinstance --name "$demo" --catalog-item "$catalog" \
  --instance-type nico-gb300-nvl72 --disk-image centos-stream-10 \
  --ssh-key "$(cat "$HOME/.ssh/nico-fnn-pilot.pub")" \
  --network-attachment "subnet=$subnet,interface=data-0,primary,security-groups=$sg"
bmi=$(osac get baremetalinstances "$demo" -o json | jq -er .id)
osac get baremetalinstances "$bmi"
```

Record the new BMI ID. This is the command that requests a real tray.

## 4. Follow the two NetworkRealization records

**Pilot VM · admin cutaway.** “At admission, Fulfillment selected the validated target and pinned the NICo pool on this BMI. Before launching provisioning, it recorded two network intents: one for the virtual network's VPC and one for the subnet's exact prefix.”

Once the Kubernetes BMI appears, run:

```bash
show_realizations() {
  bash "$inspect" --show "$bmi" | jq '
    select(.kind == "NetworkRealization") |
    if .spec.osac_subnet_id then
      {kind, id, osacSubnet:.spec.osac_subnet_id, cidr:.spec.requested_cidr,
       parentRealization:.spec.parent_realization_id, state:.status.state,
       nicoVpcPrefixId:.status.backend_resource_id}
    else
      {kind, id, osacVirtualNetwork:.spec.osac_virtual_network_id, site:.spec.site_id,
       state:.status.state, nicoVpcId:.status.backend_resource_id}
    end'
}
show_job() {
  kubectl -n osac get baremetalinstance "bmi-$bmi" -o json |
    jq '{uid:.metadata.uid,phase:.status.phase,
         placementTarget:.metadata.annotations["osac.openshift.io/placement-target-id"],
         nicoPool:.metadata.annotations["osac.openshift.io/placement-nico-instance-type-id"],
         vpcRealization:.metadata.annotations["osac.openshift.io/vpc-realization-id"],
         prefixRealization:.metadata.annotations["osac.openshift.io/prefix-realization-id"],
         jobs:[.status.provisioningJobs[]? | {jobID,type,state}],
         nicoInstanceID:.status.nicoInstanceID,nicoMachineID:.status.nicoMachineID}'
}
show_job
show_realizations
```

“The placement target tells us where the GB300 can run. Now follow the two realization IDs on the BMI. The first record connects my OSAC VirtualNetwork to a NICo VPC. The second connects my subnet to a prefix inside that VPC.”

Point to the BMI’s `vpcRealization` and `prefixRealization`, then the matching `id` on each record. On the prefix record, `parentRealization` points back to the VPC realization. Match the prefix's `subnet` and `cidr` to the values the tenant recorded in scene 1. On a fresh network you may catch both intents Pending while AWX runs. The recording can cut here. The previous hardware run took about 18 minutes from NICo instance creation to boot completion.

When the job succeeds, repeat **the same two commands**. Capture both Ready realizations with their backend IDs, the successful AWX job, and the assigned NICo instance and machine IDs. Copy the Kubernetes BMI `uid` from `show_job` for the next scene.

## 5. Provider confirms what actually exists

**NICo hub · provider view.** “I can find the same allocation from the NICo side using its OSAC ownership label.”

```bash
read -rp 'Kubernetes BMI uid from scene 4: ' bmi_uid
instance=$(nicocli --org ncx instance list |
  jq -er --arg uid "$bmi_uid" '[.[] | select(.labels.osacBmiUid == $uid)] |
    select(length == 1) | .[0].id')
actual=$(nicocli --org ncx instance get "$instance")
jq '{id,status,machineId,instanceTypeId,vpcId,
     interfaces:[.interfaces[] | {ipAddresses,vpcPrefixId}]}' <<<"$actual"
vpc=$(jq -er .vpcId <<<"$actual")
prefix=$(jq -er '.interfaces[] | select(.isPhysical) | .vpcPrefixId' <<<"$actual")
machine=$(jq -er .machineId <<<"$actual")
nicocli --org ncx vpc get "$vpc" |
  jq '{id,status,networkVirtualizationType,routingProfile,labels}'
nicocli --org ncx vpc-prefix list | jq --arg id "$prefix" \
  '.[] | select(.id == $id) | {id,status,prefix,ipBlockId,vpcId}'
```

Compare the instance’s `vpcId` with `nicoVpcId` from the first realization. Compare the physical interface’s `vpcPrefixId` with `nicoVpcPrefixId` from the second. The provider prefix should show the tenant’s requested CIDR, and the instance’s `instanceTypeId` should match the pinned pool. Hold on the physical interface's IP address.

## 6. Tenant logs in to the host

**Pilot VM · tenant view.** “OSAC now gives me the address on the network I requested. I'll use the key from my request to log in.”

```bash
osac get baremetalinstances "$bmi" -o json | jq '{id,state:.status.state,
  interfaces:.status.network_attachment_statuses}'
ip=$(osac get baremetalinstances "$bmi" -o json |
  jq -er '.status.network_attachment_statuses[] | select(.primary) | .ip_address')
ssh -i "$HOME/.ssh/nico-fnn-pilot" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=8 "cloud-user@$ip" \
  'hostname; . /etc/os-release; echo "$PRETTY_NAME"; uname -m'
```

End the main recording on the actual hostname, CentOS Stream 10, and `aarch64`. The address on OSAC's primary `data-0` attachment should match the NICo interface from the previous scene.

## Optional epilogue: release the tray

**Pilot VM · tenant view.** When finished with the demo host, delete this run's BMI and wait for deprovisioning.

```bash
osac delete baremetalinstances "$bmi"
kubectl -n osac wait --for=delete "baremetalinstance/bmi-$bmi" --timeout=45m
```

**NICo hub · provider view.** Show the instance gone and the original machine returning to unassigned Ready. The VPC and prefix are retained for later BMIs.

```bash
nicocli --org ncx instance list | jq --arg id "$instance" '[.[] | select(.id == $id) | .id]'
nicocli machine get "$machine" | jq '{id,status,instanceId}'
nicocli --org ncx vpc-prefix list | jq --arg id "$prefix" '.[] | select(.id == $id) | {id,prefix,vpcId,status}'
```
