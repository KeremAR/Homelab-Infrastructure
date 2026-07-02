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

On the worker node, prepare the storage path:

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

Install Longhorn:

```bash
git clone --single-branch --branch v1.12.x https://github.com/longhorn/longhorn.git
cd longhorn
```

Edit `deploy/longhorn.yaml`, find the `longhorn-default-setting` ConfigMap, and set:

```yaml
default-data-path: /mnt/longhorn-storage/
default-replica-count: 1
```

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

