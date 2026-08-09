# ArgoCD Setup

Goal: install ArgoCD as the GitOps controller for the homelab cluster.

This phase intentionally keeps the application manifests in the infrastructure
repository. The separate `homelab-gitops` repository will hold ArgoCD
`Application` definitions, not duplicated Kubernetes manifests.

Current ArgoCD URL after install:

```text
http://argocd.192.168.0.110.nip.io
```

---

## 1. Files

This folder contains the small local manifests around the official ArgoCD
install:

```text
5-ArgoCD/
  5A-ArgoCD.md
  argocd-namespace.yaml
  argocd-cmd-params-cm.yaml
  argocd-httproute.yaml
```

The ArgoCD core components are installed from the official upstream manifest
URL. We do not vendor the full upstream manifest into this repo.

---

## 2. Prerequisites

Earlier infrastructure steps should already be done:

- Kubernetes cluster is running.
- MetalLB is installed.
- NGINX Gateway Fabric is installed.
- `shared-gateway` exists in namespace `nginx-gateway`.
- Argo Rollouts CRDs and controller are already installed from the kubectl
  deploy phase.
- `kubectl` points to the target cluster.

Check:

```bash
kubectl get nodes
kubectl get gateway -n nginx-gateway
kubectl get rollouts.argoproj.io -A
```

Expected Gateway address:

```text
192.168.0.110
```

---

## 3. GitOps Repository Role

The `homelab-gitops` repository is not where application manifests need to live.
In this setup it should contain ArgoCD control-plane objects:

```text
homelab-gitops/
  argocd-manifests/
    root-application.yaml
    environments/
      staging.yaml
      production.yaml
      staging/
        staging-user-service.yaml
        staging-todo-service.yaml
        staging-frontend.yaml
      production/
        production-user-service.yaml
        production-todo-service.yaml
        production-frontend.yaml
```

Those ArgoCD `Application` resources can point to this infrastructure
repository:

```text
repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
path: 3-Kubectl-Deploy/staging/todo-service/templates
```

That means:

- App manifests stay in this infrastructure repo.
- ArgoCD application definitions stay in `homelab-gitops`.
- Jenkins release jobs can later update image tags in this infrastructure repo.
- ArgoCD watches the manifest paths and applies the drift.

Every commit to `homelab-gitops` can trigger ArgoCD reconciliation, but that
does not mean every application pod restarts. ArgoCD compares desired state and
live state. If only an Application definition changes, it reconciles that
Application. If the rendered app manifests do not change, Kubernetes workloads
do not roll out.

---

## 4. Create Namespace

```bash
kubectl apply -f 5-ArgoCD/argocd-namespace.yaml
```

This creates the namespace where ArgoCD components and `Application` resources
will live:

```text
argocd
```

---

## 5. Install ArgoCD

Install the upstream non-HA ArgoCD manifest:

```bash
kubectl apply \
  -n argocd \
  --server-side \
  --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/install.yaml
```

`--server-side` is important because ArgoCD CRDs can exceed the annotation size
limit used by client-side apply. `--force-conflicts` lets this install own the
fields from the upstream manifest during fresh installs and upgrades.

This is the standard multi-tenant install. It creates the UI/API server,
repo-server, application-controller, Redis, CRDs, RBAC, and supporting services.

Wait:

```bash
kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

---

## 6. Configure HTTP Mode

The homelab exposes ArgoCD through NGINX Gateway Fabric over plain HTTP. ArgoCD
server should therefore run in insecure mode behind the gateway.

Apply:

```bash
kubectl apply -f 5-ArgoCD/argocd-cmd-params-cm.yaml
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
```

This sets:

```yaml
server.insecure: "true"
```

in `argocd-cmd-params-cm`. The restart is needed because the server deployment
reads this config at startup.

---

## 7. Expose ArgoCD

```bash
kubectl apply -f 5-ArgoCD/argocd-httproute.yaml
kubectl get httproute -n argocd
```

The route uses:

```text
argocd.192.168.0.110.nip.io
```

Open:

```text
http://argocd.192.168.0.110.nip.io
```

---

## 8. Initial Login

Username:

```text
admin
```

Get the generated initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

Optional CLI login:

```bash
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

argocd login argocd.192.168.0.110.nip.io:80 \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --plaintext \
  --grpc-web
```

The Jenkins `kubernetes-tools` image already contains an ArgoCD CLI for future
pipeline steps. Local CLI installation is optional for manual administration.

---

## 9. Bootstrap Applications Later

Do not apply the root app until the `homelab-gitops` Application manifests are
cleaned up for the current plain-manifest layout.

The later bootstrap command will be:

```bash
kubectl apply -f homelab-gitops/argocd-manifests/root-application.yaml
```

Before that, replace old Helm references in `homelab-gitops` with plain
directory Applications that point to this repo:

```yaml
source:
  repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
  targetRevision: main
  path: 3-Kubectl-Deploy/staging/todo-service/templates
  directory:
    recurse: false
```

Also fix any finalizer typo:

```text
resources-finalizer.argocd.argoproj.io
```

---

## 10. References

- ArgoCD getting started:
  <https://github.com/argoproj/argo-cd/blob/master/docs/getting_started.md>
- ArgoCD declarative setup and App of Apps:
  <https://argo-cd.readthedocs.io/en/release-3.0/operator-manual/declarative-setup/>
- ArgoCD ingress notes:
  <https://argo-cd.readthedocs.io/en/latest/operator-manual/ingress/>
