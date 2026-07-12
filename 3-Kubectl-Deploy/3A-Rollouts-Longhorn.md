# Deploy Todo App with Kubectl

Goal: deploy the todo application manually with plain Kubernetes manifests first. No Helm and no ArgoCD in this phase. Argo Rollouts is still required because the app resources are `Rollout`, not `Deployment`.

Prerequisites from earlier steps:

- CAPI/Proxmox cluster is running.
- Calico is installed.
- MetalLB is installed with pool `192.168.0.110-192.168.0.115`.
- NGINX Gateway Fabric is installed.
- `shared-gateway` exists in namespace `nginx-gateway`.
- Current Gateway IP is `192.168.0.110`.

---

## 1. Install Longhorn

PostgreSQL StatefulSets need a default `StorageClass`. Old K3s had `local-path` by default; this CAPI cluster does not. Longhorn is used here.

On all three worker nodes, prepare the storage path and install the prerequisites:

```bash
sudo mkdir -p /mnt/longhorn-storage
```

Install node prerequisites. Package names depend on the OS:

```bash
# Debian/Ubuntu style
sudo apt update
sudo apt install -y open-iscsi nfs-common util-linux e2fsprogs xfsprogs
sudo systemctl enable --now iscsid
```

Label the three worker nodes before installing Longhorn. Replace the example names below with the current names shown by `kubectl get nodes` if a CAPI Machine has been recreated:

```bash
kubectl get nodes

kubectl label node \
  homelab-workers-pve1-qn44f-mdvk6 \
  homelab-workers-pve2-4jwgz-wvsmc \
  homelab-workers-pve2-4jwgz-2tl55 \
  node.longhorn.io/create-default-disk=true
```

Do not add this label to the control-plane node.

Install Longhorn:

```bash
git clone --single-branch --branch v1.12.x https://github.com/longhorn/longhorn.git
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
    default-replica-count: 3
```

`create-default-disk-labeled-nodes` defaults to `false`. When it is left disabled, Longhorn does not use the label as a filter and registers `default-data-path` as a Longhorn disk on every newly detected eligible node. Setting it to `true` makes Longhorn register the default storage path only on nodes labeled `node.longhorn.io/create-default-disk=true`; this keeps Longhorn replica storage on the three workers and off the control-plane node.

Here, “create default disk” means registering `/mnt/longhorn-storage/` as a storage location in Longhorn—it does not create a physical disk, partition, or filesystem. The directory and any intended disk mount must already be prepared on every labeled worker.

`default-replica-count: 3` means that each newly created Longhorn volume has three data copies, which Longhorn distributes across the available worker storage nodes.

Then apply:

```bash
kubectl apply -f deploy/longhorn.yaml
kubectl get pods -n longhorn-system -w
kubectl get sc
```

Expected: Longhorn creates the default StorageClass.

Expose the Longhorn UI through NGF:

```bash
kubectl apply -f 3-DeployWithManifests/longhorn-httproute.yaml
```

UI:

```text
http://longhorn.192.168.0.110.nip.io
```

---

## 2. Install Argo Rollouts

```bash
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argo-rollouts \
  -n argo-rollouts \
  --timeout=180s

kubectl apply -f 3-DeployWithManifests/argo-rollouts-rbac.yaml
```

Optional CLI plugin:

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

---
