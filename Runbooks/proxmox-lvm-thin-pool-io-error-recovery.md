# Proxmox LVM-Thin Pool Full And VM I/O Error Recovery Runbook

This runbook explains how to investigate and recover Proxmox VMs that appear
as `running (io-error)` after the underlying LVM-thin pool becomes full.

Example incident:

```text
Proxmox VM status = running (io-error)
SSH to the affected VMs fails
Kubernetes nodes hosted by those VMs become NotReady
local-lvm reports 100% usage
```

`running (io-error)` means that the QEMU process still exists, but QEMU has
paused guest execution after a storage write failed. Do not immediately hard
stop or power-cycle the VM. First restore free space in the backing storage,
then resume the paused VM.

---

## 1. Connect To The Affected Proxmox Host

Example host:

```bash
PVE_HOST="192.168.0.101"
SSH_KEY="$HOME/.ssh/id_ed25519"

ssh -i "$SSH_KEY" root@"$PVE_HOST"
```

In this incident, the affected host was `pve2` and the affected VMs were:

```text
VM 103  homelab-workers-pve2-dk699-g9fc8
VM 105  homelab-workers-pve2-dk699-bz5l2
```

---

## 2. Check Host Filesystems And Proxmox Storage

Check normal filesystems, inode usage, Proxmox storage, and the VM list:

```bash
hostname
pveversion
uptime
df -hT
df -i
pvesm status
qm list
```

The important distinction is:

```text
local      -> directory storage on the Proxmox root filesystem
local-lvm  -> LVM-thin pool that normally stores VM disks
```

Example result from this incident:

```text
local      30.84% used
local-lvm  100.00% used
```

The Proxmox root filesystem was not full. The VM disk thin-pool was full.

---

## 3. Inspect The LVM Layout

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
pvs -o pv_name,pv_size,pv_free
vgs -o vg_name,vg_size,vg_free
lvs -a -o lv_name,vg_name,lv_size,pool_lv,origin,data_percent,metadata_percent,lv_attr
pvesm list local-lvm
```

Example physical layout:

```text
128 GB manufacturer SSD
  -> 119.2 GiB visible to Linux
  -> 1 GiB EFI partition
  -> 118 GiB LVM physical volume

pve/root          39.5 GiB
pve/swap           8.0 GiB
pve/data          63.87 GiB initially
thin metadata      1.0 GiB
metadata spare     1.0 GiB
unallocated VG     4.63 GiB initially
```

`PFree` and `VFree` show physical extents that belong to the volume group but
have not been assigned to a logical volume. They are not part of `/` or the
thin-pool until explicitly allocated.

Thin provisioning permits logical VM disks to be larger than the physical
pool. In this incident, the logical allocation was approximately:

```text
template disk  20 GiB
VM 103 disk    40 GiB
VM 105 disk    40 GiB
---------------
logical total 100 GiB

physical thin-pool: 63.87 GiB
```

This is safe only while the real written blocks remain below the physical
thin-pool capacity.

---

## 4. Confirm The QEMU I/O Error State

Use the Proxmox API output instead of relying only on the web UI:

```bash
pvesh get /nodes/pve2/qemu/103/status/current --output-format json-pretty
pvesh get /nodes/pve2/qemu/105/status/current --output-format json-pretty
```

Look for:

```json
{
  "status": "running",
  "qmpstatus": "io-error"
}
```

The `blockstat` section can also show failed write operations.

Check the storage-related host logs:

```bash
journalctl -b --no-pager -p warning..alert | tail -n 200
journalctl -b --no-pager | \
  grep -Ei "no space|enospc|io-error|i/o error|thin pool|qemu.*(error|paused)" | \
  tail -n 150
dmesg --level=err,warn | tail -n 120
```

Example timeline from this incident:

```text
13:11  thin-pool data 90.02% full
13:25  thin-pool data 95.98% full
16:06  thin-pool reached its low-water mark
16:06  thin-pool data 100.00% full
16:07  QEMU guest agent timeouts begin
```

There were no corresponding NVMe hardware I/O errors. The failure was caused
by thin-pool exhaustion.

---

## 5. Emergency Recovery With Unallocated VG Space

Use this step only after confirming that `vgs` reports free extents.

In this incident, the volume group had approximately `4.63 GiB` free. Four GiB
was added to the thin-pool:

```bash
lvextend -L +4G /dev/pve/data
```

This extends the thin-pool online. It does not resize a guest filesystem.

Verify the result:

```bash
lvs -o lv_name,lv_size,data_percent,metadata_percent
pvesm status
```

Example result:

```text
pve/data:       63.87 GiB -> 67.87 GiB
Data%:          100.00%   -> 94.11%
remaining VFree: approximately 644 MiB
```

Do not copy the `+4G` value blindly. Always calculate it from the current
`VFree` value and leave some emergency space when possible.

### 5.1 Resume The Paused VMs

After storage space exists again:

```bash
qm resume 103
qm resume 105
```

Verify:

```bash
pvesh get /nodes/pve2/qemu/103/status/current --output-format json-pretty
pvesh get /nodes/pve2/qemu/105/status/current --output-format json-pretty
```

Expected:

```json
"qmpstatus": "running"
```

Then verify Kubernetes:

```bash
kubectl get nodes
```

### 5.2 Watch The Pool Closely

```bash
watch -n 5 \
  "ssh -i ~/.ssh/id_ed25519 root@192.168.0.101 pvesm status"
```

In this incident, the pool filled again within minutes. Resuming the VMs
released buffered guest writes, Longhorn reattachment activity, container
runtime activity, and image pulls:

```text
VM 103 real thin allocation increased by approximately 2.1 GiB
VM 105 real thin allocation increased by approximately 1.9 GiB
```

The emergency `lvextend` created time to recover; it did not remove the source
of storage growth.

---

## 6. Move A Stopped Template Out Of The Full Thin-Pool

This procedure can create emergency space when:

- the template is stopped;
- Proxmox root storage has enough free space;
- the existing VMs are full clones rather than linked clones; and
- the template must remain available for future provisioning.

Inspect the template and root storage first:

```bash
qm config 101
df -hT /var/lib/vz
cat /etc/pve/storage.cfg
```

The example template was:

```text
VM ID:        101
name:         ubuntu-2404-kube-v1.36.1
state:        stopped template
scsi0:        local-lvm:base-101-disk-1
virtual size: 20 GiB
real usage:   approximately 5.9 GiB
```

The existing CAPI VMs were created as full clones, so moving the template did
not break their disks. Do not use this procedure without dependency checks if
the VMs are linked clones.

### 6.1 Allow VM Images On `local`

The first move attempt failed with:

```text
storage 'local' does not support vm images
```

The storage configuration allowed only `iso,vztmpl,backup`. Preserve the
existing content types and add `images`:

```bash
pvesm set local --content iso,vztmpl,backup,images
```

This changes which content types Proxmox permits on the directory storage. It
does not move or delete existing ISOs, templates, or backups.

### 6.2 Move The Template Disk

```bash
qm move_disk 101 scsi0 local --format qcow2 --delete 1
```

`--delete 1` removes the old source volume only after the copy completes
successfully. Do not interrupt the conversion.

Verify the new template configuration and storage usage:

```bash
qm config 101
pvesm status
lvs -a -o lv_name,lv_size,data_percent,metadata_percent
df -hT /var/lib/vz
```

Result from this incident:

```text
template scsi0: local:101/base-101-disk-0.qcow2
local-lvm:      100.00% -> 91.33%
thin free:      approximately 6.17 GiB
root used:      approximately 12 GiB -> 18 GiB
root free:      approximately 19 GiB
```

The template ID remained `101`, so it remained available as the CAPI clone
source.

Resume the affected VMs again if they returned to `io-error` while the pool was
full:

```bash
qm resume 103
qm resume 105
```

Final immediate state in this incident:

```text
VM 103 qmpstatus: running
VM 105 qmpstatus: running
all Kubernetes nodes: Ready
local-lvm: approximately 92.5% used
```

---

## 7. Investigate Guest Disk Consumption

After the VMs are reachable, inspect the guest disks. Example worker IPs:

```bash
for host in 192.168.0.153 192.168.0.154; do
  ssh -i ~/.ssh/id_ed25519 root@"$host" '
    hostname
    df -hT
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
    du -xhd1 /mnt/longhorn-storage 2>/dev/null
    du -xhd1 /var/lib 2>/dev/null
    systemctl is-active fstrim.timer
  '
done
```

Findings from this incident:

```text
192.168.0.153
  /mnt/longhorn-storage  7.8 GiB
  /var/lib/containerd   16 GiB

192.168.0.154
  /mnt/longhorn-storage  7.4 GiB
  /var/lib/containerd   17 GiB
```

`/mnt/longhorn-storage` was a directory on each VM's 40 GiB root disk, not a
separate physical or virtual disk. Longhorn replicas and the containerd image
store therefore competed for the same guest disk and the same Proxmox thin-pool
capacity.

Longhorn-attached block devices such as `/dev/sdb` are workload volumes. They
must not be confused with a dedicated disk backing
`/mnt/longhorn-storage`.

---

## 8. Delete Or Recreate PVCs Safely

Deleting a PVC can free Longhorn replica files when the StorageClass uses:

```yaml
reclaimPolicy: Delete
```

Check before deletion:

```bash
kubectl get pvc -A
kubectl get pv
kubectl get storageclass longhorn-storageclass -o yaml
```

Do not delete PVCs while their nodes are paused in `io-error`. Longhorn may be
unable to detach and remove the replica data.

Recommended order when the data is disposable:

1. If Argo CD manages the workload, pause reconciliation temporarily.
2. Change the requested size in the source Helm values or Kubernetes manifest.
3. Stop, scale down, or uninstall the controller that owns the PVC.
4. Confirm that no pod is mounting or writing to the claim.
5. Delete only the intended PVCs.
6. Confirm that the PVC, PV, VolumeAttachment, Longhorn volume, and replica are
   deleted.
7. Restore the workload and Argo CD reconciliation only after the desired PVC
   size has been changed in Git.

### Why a PVC can remain `Terminating`

Kubernetes normally adds this finalizer to a PVC that is in use:

```text
kubernetes.io/pvc-protection
```

It prevents the claim from disappearing while a Pod still mounts it. Deleting
the PVC before stopping its workload therefore leaves the PVC in
`Terminating`; this is expected protection, not usually a broken finalizer.

Inspect the claim and the Pod using it:

```bash
kubectl get pvc -A
kubectl describe pvc <claim> -n <namespace>
kubectl get pvc <claim> -n <namespace> \
  -o jsonpath='{.metadata.finalizers}{"\n"}'
```

Scale down the owning Deployment or StatefulSet first, then wait for its Pods
to terminate:

```bash
kubectl scale deployment <name> -n <namespace> --replicas=0
kubectl scale statefulset <name> -n <namespace> --replicas=0
kubectl get pods -n <namespace> -w
kubectl delete pvc <claim> -n <namespace>
```

Do not remove `kubernetes.io/pvc-protection` manually while a Pod still uses the
claim. Force-removing the finalizer can leave stale mounts, attachments, or
Longhorn resources behind.

### Prevent Argo CD from recreating the claims

Scaling a GitOps-managed workload down only in the cluster is temporary. Argo
CD can reconcile it back to the replica count stored in Git and immediately
recreate deleted PVCs with the old size. During this incident, production and
staging database claims were recreated for this reason.

Pause the Argo CD application controller while performing the destructive PVC
cleanup:

```bash
kubectl scale statefulset argocd-application-controller \
  -n argocd --replicas=0
```

After changing and committing the desired PVC sizes, restore reconciliation:

```bash
kubectl scale statefulset argocd-application-controller \
  -n argocd --replicas=1
```

Then restore or synchronize the workloads and verify the newly created claims:

```bash
kubectl get pvc,pv -A
kubectl get volumeattachments
kubectl get volumes.longhorn.io,replicas.longhorn.io -n longhorn-system
```

The cleanup order used in this incident was therefore:

1. Pause Argo CD reconciliation.
2. Update the desired sizes in Git.
3. Scale PVC-consuming workloads to zero and wait for their Pods to stop.
4. Delete the PVCs and allow the protection finalizer to clear naturally.
5. Verify that PVs, attachments, Longhorn volumes, and replicas disappear.
6. Restore Argo CD and the workloads.

If the controller remains active, it may immediately recreate a deleted claim
at its old size.

PVC request size and physical usage are different:

```text
PVC request / Longhorn scheduled size = logical reservation
Longhorn actual size                 = blocks containing data
Proxmox thin-pool usage              = guest blocks ever written and not discarded
```

Reducing PVC requests improves Longhorn scheduling capacity, but Proxmox space
is reclaimed only after guest blocks are released and discard/TRIM reaches the
host.

---

## 9. Enable Discard And Reclaim Deleted Guest Blocks

This was performed after the PVC and Longhorn volume cleanup.

The running QEMU command line showed:

```text
discard: ignore
```

Without discard, deleting files, container images, or Longhorn replicas inside
the guest may not reduce the Proxmox thin-pool allocation.

Recommended maintenance procedure:

1. Drain one Kubernetes worker when it still hosts workloads. Drain is a
   Kubernetes availability precaution, not a requirement for enabling discard.
2. Shut down that VM cleanly.
3. Enable `Discard` for its Proxmox `scsi0` disk.
4. Start the VM with a full shutdown/start cycle; a guest reboot may not apply
   the changed QEMU disk option.
5. Wait for the Kubernetes node to become Ready.
6. Verify discard support and run `fstrim` inside the guest.
7. Verify thin-pool usage before repeating on the next worker.

Guest command:

```bash
sudo fstrim -av
```

Verify discard support inside the guest:

```bash
lsblk -D /dev/sda
systemctl status fstrim.timer
```

Non-zero `DISC-GRAN` and `DISC-MAX` values confirm that the guest disk exposes
discard. The procedure was applied to every VM one at a time. One worker
reported 21.7 GiB trimmed, and the final Proxmox `local-lvm` usage was 61.82%
instead of the earlier 94.66%. This confirmed that the discard path reached the
LVM thin pool.

Do not restart all storage nodes simultaneously. Handle them one at a time so
Kubernetes and Longhorn can recover between nodes.

---

## 10. Optional Offline Root LV Shrink

This was discussed as a capacity follow-up; it was not performed during the
incident.

The Proxmox root filesystem is ext4. Ext4 cannot be shrunk while mounted, so do
not run `lvreduce` against the live Proxmox root filesystem.

A root shrink requires:

- verified backups;
- all VMs on the host shut down cleanly;
- booting the physical Proxmox host from a live/rescue USB;
- the root filesystem unmounted; and
- filesystem verification before resizing.

Use `lvreduce --resizefs` rather than reducing the LV without resizing the
filesystem. A plain `lvreduce` with the wrong ordering can permanently damage
the root filesystem.

After moving the template to `local`, root usage increased to approximately
18 GiB. A 25 GiB root LV would leave little operational headroom. A 30 GiB root
LV is a safer target and would return approximately 9.5 GiB to the volume group.

After an offline shrink, add only the intended free extents to `pve/data` and
retain emergency VG free space when possible.

---

## 11. Optional Control-Plane Longhorn Storage

This was investigated but not changed during the immediate recovery.

Allowing Longhorn to store replicas on the control-plane does not require
removing the Kubernetes control-plane taint or scheduling normal application
workloads there.

Check the label-controlled default-disk setting and registered Longhorn nodes:

```bash
kubectl get settings.longhorn.io -n longhorn-system \
  create-default-disk-labeled-nodes -o yaml
kubectl get nodes.longhorn.io -n longhorn-system
```

In this incident:

```text
create-default-disk-labeled-nodes = true
control-plane Longhorn node       = not found
```

The label alone is not sufficient when `longhorn-manager` cannot run on the
tainted control-plane node. Before labeling the node:

1. Install the Longhorn node prerequisites on the control-plane.
2. Prepare and mount the intended Longhorn storage path.
3. Configure Longhorn components to tolerate the control-plane taint.
4. Confirm that the control-plane appears as a Longhorn node.
5. Add the default-disk label.

```bash
kubectl label node homelab-control-plane-8vt27 \
  node.longhorn.io/create-default-disk=true
```

Keep this taint in place if normal workloads should remain off the
control-plane:

```text
node-role.kubernetes.io/control-plane:NoSchedule
```

Adding another Longhorn storage node improves future replica placement, but it
does not directly free an already-full Proxmox thin-pool on another physical
host.

---

## 12. Prevention And Monitoring

Monitor both logical allocations and real pool usage:

```bash
pvesm status
lvs -o lv_name,lv_size,data_percent,metadata_percent
vgs -o vg_name,vg_size,vg_free
```

Recommended safeguards:

- alert before thin-pool `Data%` reaches 80-85%;
- enable discard on thin-provisioned VM disks;
- keep `fstrim.timer` enabled in guests;
- prune unused container images safely;
- size Jenkins build caches according to real usage;
- remove obsolete Longhorn volumes and PVCs;
- avoid placing a logical 100 GiB VM/template allocation on a 64 GiB physical
  pool without monitoring;
- retain some unallocated VG space for emergency extension; and
- add or replace physical storage instead of relying indefinitely on LVM
  over-provisioning.

LVM thin-pool auto-extension only works while the volume group still has free
extents. It cannot protect a pool when all physical capacity has already been
assigned.

---

## 13. Quick Decision Tree

```text
VM says running (io-error):
  check pvesm status and lvs

local-lvm is 100% and VG has free extents:
  lvextend pve/data -> verify -> qm resume

pool fills again immediately:
  leave VMs paused -> find removable/movable host-side data

stopped template consumes thin-pool and root local has space:
  allow images on local -> move template disk -> verify source deletion

VMs are reachable again:
  inspect Longhorn and containerd usage -> clean disposable data

guest files were deleted but thin-pool usage did not fall:
  enable disk discard -> restart one worker at a time -> run fstrim

considering root LV shrink:
  do it only offline from rescue media with backups
```
