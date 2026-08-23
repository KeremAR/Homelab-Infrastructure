# Longhorn

Longhorn provides persistent block storage for workloads running on the
Kubernetes cluster. It creates replicated volumes from storage registered on
the Kubernetes nodes and dynamically provisions PersistentVolumes for PVCs.

The application PostgreSQL StatefulSets and the later CI/CD services depend on
the `longhorn-storageclass` created in this step. Install Longhorn before Argo
Rollouts and the application workloads.

## Installation

The Cluster API workload cluster does not include a default persistent-storage
provider, so Longhorn is installed explicitly.

Install PSSH on the administration machine (the machine where `kubectl` and the SSH private key are available):

```bash
sudo apt update
sudo apt install -y pssh
```

On Debian/Ubuntu, the command installed by the `pssh` package is named `parallel-ssh`. Build its host list automatically from the worker nodes' Kubernetes `InternalIP` addresses:

```bash
kubectl get nodes \
  -l node-role.kubernetes.io/node \
  -o jsonpath='{range .items[*]}root@{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  > '3-Longhorn/longhorn-workers.txt'

cat '3-Longhorn/longhorn-workers.txt'
```

The CAPI configuration adds `$HOME/.ssh/id_ed25519.pub` to the `root` user's `sshAuthorizedKeys`, so PSSH must connect as `root` with the matching private key.

When CAPI recreates a VM while reusing its previous IP address, the VM receives a new SSH host key. After confirming that these are the expected recreated worker VMs, remove only their stale entries from `known_hosts`; `StrictHostKeyChecking=accept-new` will then record the new keys during the first connection:

```bash
while IFS= read -r host; do
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${host#*@}"
done < '3-Longhorn/longhorn-workers.txt'
```

In a security-sensitive environment, verify each new host-key fingerprint through the Proxmox console before accepting it. Prepare the Longhorn storage path on all three workers in parallel:

```bash
parallel-ssh \
  -h '3-Longhorn/longhorn-workers.txt' \
  -i \
  -x "-i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
  "mkdir -p /mnt/longhorn-storage"
```

Install the Longhorn node prerequisites on all workers in parallel. Package names depend on the OS:

```bash
# Debian/Ubuntu style
parallel-ssh \
  -h '3-Longhorn/longhorn-workers.txt' \
  -i \
  -x "-i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
  "apt-get update && \
   env DEBIAN_FRONTEND=noninteractive apt-get install -y open-iscsi nfs-common util-linux e2fsprogs xfsprogs && \
   systemctl enable --now iscsid"
```

If these VMs do not use real SAN multipath storage, disable `multipathd` on the
Longhorn nodes:

```bash
parallel-ssh \
  -h '3-Longhorn/longhorn-workers.txt' \
  -i \
  -x "-i $HOME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
  "systemctl disable --now multipathd.service multipathd.socket"
```

Otherwise, `multipathd` can claim a Longhorn iSCSI device and cause new volumes
to fail during formatting or mounting with `is apparently in use by the
system`. Do not disable it on nodes that actually depend on multipath storage.

Label all worker nodes before installing Longhorn. The selector uses the worker-role label, so this command continues to work when CAPI recreates a Machine with a different node name:

```bash
kubectl label nodes \
  -l node-role.kubernetes.io/node \
  node.longhorn.io/create-default-disk=true \
  --overwrite
```

Do not add this label to the control-plane node.

Install Longhorn:

```bash
git clone --single-branch --branch v1.12.0 https://github.com/longhorn/longhorn.git
cd longhorn
```

Edit `deploy/longhorn.yaml`, find the `longhorn-default-setting` ConfigMap, and set:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-default-setting
  namespace: longhorn-system
data:
  default-setting.yaml: |-
    create-default-disk-labeled-nodes: true
    default-data-path: /mnt/longhorn-storage/
```

`create-default-disk-labeled-nodes` defaults to `false`. When it is left disabled, Longhorn does not use the label as a filter and registers `default-data-path` as a Longhorn disk on every newly detected eligible node. Setting it to `true` makes Longhorn register the default storage path only on nodes labeled `node.longhorn.io/create-default-disk=true`; this keeps Longhorn replica storage on the three workers and off the control-plane node. This behavior is described in the official Longhorn documentation under [Configuring Defaults for Nodes and Disks](https://longhorn.io/docs/1.12.0/nodes-and-volumes/nodes/default-disk-and-node-config/).

Here, “create default disk” means registering `/mnt/longhorn-storage/` as a storage location in Longhorn—it does not create a physical disk, partition, or filesystem. The directory and any intended disk mount must already be prepared on every labeled worker.

> **Replica-count scope:** Longhorn's `default-replica-count` setting is used
> primarily for volumes created through the Longhorn UI. For volumes
> dynamically provisioned from Kubernetes PVCs, replica count is configured
> with the StorageClass `parameters.numberOfReplicas` field. Changing
> `default-replica-count` does not edit an existing or generated StorageClass.
> If `numberOfReplicas` is omitted from a StorageClass, its documented default
> is still `3`; it does not fall back to `default-replica-count`.

For example, even if Longhorn were installed with:

```yaml
default-replica-count: 1
```

the installation manifest's default `longhorn` StorageClass still contains:

```yaml
parameters:
  numberOfReplicas: "3"
```

Therefore, a PVC with `storageClassName: longhorn` receives three replicas, not
one. This is why `default-replica-count` is intentionally omitted above: this
setup creates volumes through Kubernetes PVCs. The custom
`longhorn-storageclass` created below explicitly sets
`numberOfReplicas: "1"` for workloads that require one replica.

Then apply:

```bash
kubectl apply -f deploy/longhorn.yaml
kubectl get pods -n longhorn-system -w
kubectl get sc
cd ..
```

Expected: Longhorn creates the default StorageClass.

Expose the Longhorn UI through the shared Envoy Gateway:

```bash
kubectl apply -f '3-Longhorn/longhorn-httproute.yaml'
```

UI:

```text
http://longhorn.192.168.0.110.nip.io
```

As the final Longhorn installation step, create the cluster-wide,
single-replica StorageClass used explicitly by workloads that do not require
three Longhorn data copies:

```bash
kubectl apply -f '3-Longhorn/longhorn-storageclass.yaml'
kubectl get storageclass longhorn-storageclass
```

This class is not marked as the cluster default. Workloads select it with
`storageClassName: longhorn-storageclass`.
