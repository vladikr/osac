# One tenant network, from OSAC to a GB300

**Opening narration.** “As an OSAC tenant, I can request VMs, Kubernetes clusters, and bare-metal nodes, including a GB300. I want to define my workload network once and choose the subnet when I request a service. I'll start by creating that network in OSAC. Then I'll request a GB300 and log in to the address it gets on my subnet.”

## Before recording

Use two Bash terminals. **Pilot VM** is `cloud-user@osac-nico-fnn-pilot`, with the OSAC CLI logged in as `tenant1_user`. Use that terminal for both the tenant commands and the clearly labeled admin cutaways. **NICo hub** is the existing `control-plane-2` shell with a working `nicocli --org ncx` session. Authenticate before recording. Keep the shells open so their variables survive camera cuts.

For a **creation** demo, reserve a fresh, nonoverlapping /28 inside the validated `10.181.0.0/24` with the site operator. Check current OSAC network/subnet allocations and NICo prefixes. The earlier run used `10.181.0.32/28`. Reusing its existing network demonstrates reuse. Confirm a tray is available and the SSH key pair exists on the pilot VM.

**NICo hub · pre-recording check.** Enter the reserved CIDR. Capture the baseline. The matching prefix list for a fresh CIDR should be empty.

```bash
read -rp 'Reserved demo CIDR: ' cidr
nicocli --org ncx vpc-prefix list |
  jq --arg cidr "$cidr" '[.[] | select(.prefix == $cidr) | {id,vpcId,prefix}]'
```

If you want a text transcript as well as video, run `script -q "$HOME/fnn-demo-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"` in each terminal **before** setting variables. Use `exit` to finish each transcript.

## 1. Tenant creates the workload network

**Pilot VM · tenant view.** Start recording here. Run the identity check as you deliver the opening narration.

```bash
osac whoami
```

Create the demo network. Enter the same reserved CIDR as in the baseline. Keep the generated name for the rest of the recording.

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

## 4. Admin follows the placement and both network records

**Pilot VM · admin cutaway.** “At admission, Fulfillment selected the validated target and pinned the NICo pool on this BMI. Before launching provisioning, it recorded two network intents: one for the virtual network's VPC and one for the subnet's exact prefix.”

Once the Kubernetes BMI appears, run:

```bash
show_placement() {
  bash "$inspect" --show "$bmi" | jq -c '
    if .kind == "BareMetalPlacementTarget" then {kind,id,ready:.status.ready}
    elif .kind == "BareMetalInstance" then {kind,id,state,target,nico_instance_type_id}
    else {kind,id,vn:.spec.osac_virtual_network_id,subnet:.spec.osac_subnet_id,
          parent:.spec.parent_realization_id,cidr:.spec.requested_cidr,
          state:.status.state,backend:.status.backend_resource_id} end'
}
show_job() {
  kubectl -n osac get baremetalinstance "bmi-$bmi" -o json |
    jq '{uid:.metadata.uid,phase:.status.phase,jobs:[.status.provisioningJobs[]? | {jobID,type,state}],
         nicoInstanceID:.status.nicoInstanceID,nicoMachineID:.status.nicoMachineID}'
}
show_placement
show_job
```

Point to the BMI's pinned pool ID from scene 2 and the prefix record's `parent`, which equals the VPC realization's `id`. Match the prefix's `subnet` and `cidr` to the values the tenant recorded in scene 1. On a fresh network you may catch both intents Pending while AWX runs. The recording can cut here. The previous hardware run took about 18 minutes from NICo instance creation to boot completion.

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

Show three matches: the instance's `instanceTypeId` equals the pinned pool, the VPC and prefix IDs equal the two realization backend IDs, and the prefix CIDR equals the tenant's subnet. Hold on the physical interface's IP address.

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
