# Argo Rollouts

The application manifests use the `Rollout` custom resource instead of a
standard Kubernetes `Deployment`. Argo Rollouts must therefore be installed
before either the kubectl or Helm deployment method is used. It provides the
controller, CRDs and canary promotion behavior used by all three application
components.

## Installation

```bash
kubectl create namespace argo-rollouts --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argo-rollouts \
  -n argo-rollouts \
  --timeout=180s

kubectl apply -f '4-Deploy-App/argo-rollouts/argo-rollouts-rbac.yaml'
```

The project RBAC permits the Rollouts controller to read and patch HTTPRoutes
in `staging` and `production`. It needs that access to shift traffic between
the stable and canary Services during a rollout.

## kubectl plugin

The optional plugin adds commands for inspecting, promoting, aborting and
retrying rollouts:

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

It can also start a temporary dashboard on `localhost:3100`:

```bash
kubectl argo rollouts dashboard
```

The terminal process must remain running. Use the in-cluster dashboard below
for an always-available UI.

## Dashboard

```bash
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

kubectl wait --for=condition=available deployment/argo-rollouts-dashboard \
  -n argo-rollouts \
  --timeout=180s

kubectl apply -f \
  '4-Deploy-App/argo-rollouts/argo-rollouts-dashboard-httproute.yaml'
kubectl get httproute -n argo-rollouts
```

The dashboard is available at:

```text
http://rollouts.192.168.0.110.nip.io
```

It has no login screen in this setup, so expose it only on the private homelab
network.
