# Deploy the application

This directory contains two ways to deploy the same frontend, user service,
todo service and PostgreSQL workloads. Both methods create Argo Rollouts
resources and target the `staging` and `production` namespaces.

## Prerequisites and order

Complete these steps before deploying the application:

1. Install the cluster networking, MetalLB and one Gateway API controller.
2. Install [Longhorn](../3-Longhorn/README.md) and create
   `longhorn-storageclass` for persistent database volumes.
3. Install [Argo Rollouts](./argo-rollouts/README.md). The application YAML
   contains `kind: Rollout`, so Kubernetes cannot accept it until the Rollouts
   CRDs and controller exist.
4. Choose one deployment method below.

## Method 1: plain Kubernetes manifests

The [`kubectl`](./kubectl/) directory contains explicit manifests for each
service and environment. This path is useful for learning the Kubernetes
objects directly and seeing exactly what is applied without template
rendering.

Follow [3B-Kubectl-Deploy.md](./kubectl/3B-Kubectl-Deploy.md).

## Method 2: Helm charts

The [`helm`](./helm/) directory contains one reusable chart per service.
Shared configuration lives in `values.yaml`, while staging and production
differences live in their respective values files. This reduces duplicated
YAML and is the deployment model used by the later release automation.

Follow the [Helm deployment guide](./helm/README.md).

These are alternative representations of the same Kubernetes resources; do
not manage both at the same time. When migrating existing kubectl-managed
resources to Helm, follow the ownership and ArgoCD pause instructions in the
Helm guide.
