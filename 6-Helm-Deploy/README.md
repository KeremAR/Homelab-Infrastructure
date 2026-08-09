# Helm Deploy

This phase introduces Helm charts for the same workloads that were previously
managed with plain Kubernetes manifests and then ArgoCD Applications.

The first goal is manual Helm deployment. ArgoCD should be paused temporarily
while testing this, otherwise ArgoCD can reconcile the same resources back to
the plain manifest state.

---

## 1. Install Helm CLI

Install Helm locally if it is not already available:

```bash
if ! command -v helm >/dev/null 2>&1; then
  echo "Helm not found. Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm version --short
```

---

## 2. Charts

This directory contains one chart per service:

```text
6-Helm-Deploy/
  frontend/
  user-service/
  todo-service/
```

Each chart has:

```text
Chart.yaml
values.yaml
values-staging.yaml
values-production.yaml
templates/
```

The resource names intentionally stay the same as the plain manifest names:

```text
frontend
user-service
todo-service
user-db
todo-db
```

This prevents service discovery, HTTPRoute backends, and Argo Rollouts service
references from changing during the migration.

`values.yaml` contains shared defaults. `values-staging.yaml` and
`values-production.yaml` keep environment-specific choices visible: namespace,
replica count, image tag, resources, hostnames, and database storage class.

The chart value is named `replicaCount` because that is the common Helm chart
convention. It renders to the Kubernetes field named `spec.replicas`.

---

## 3. Pause ArgoCD First

ArgoCD is currently managing the same resources through Applications in
`homelab-gitops`. Pause sync from the top of the App of Apps tree down.

```bash
for app in \
  root-app \
  staging \
  production \
  staging-frontend \
  staging-user-service \
  staging-todo-service \
  production-frontend \
  production-user-service \
  production-todo-service
do
  kubectl patch application "$app" \
    -n argocd \
    --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
```

Why top-down?

`root-app` manages the environment Applications. The environment Applications
manage the service Applications. If only a service Application is changed,
its parent can self-heal it back. Pausing from the root prevents that tug of
war while Helm is tested.

Check:

```bash
kubectl get application -n argocd
```

---

## 4. Render Before Installing

Render staging:

```bash
helm template staging-user-service ./6-Helm-Deploy/user-service \
  --namespace staging \
  -f 6-Helm-Deploy/user-service/values-staging.yaml

helm template staging-todo-service ./6-Helm-Deploy/todo-service \
  --namespace staging \
  -f 6-Helm-Deploy/todo-service/values-staging.yaml

helm template staging-frontend ./6-Helm-Deploy/frontend \
  --namespace staging \
  -f 6-Helm-Deploy/frontend/values-staging.yaml
```

Render production:

```bash
helm template production-user-service ./6-Helm-Deploy/user-service \
  --namespace production \
  -f 6-Helm-Deploy/user-service/values-production.yaml

helm template production-todo-service ./6-Helm-Deploy/todo-service \
  --namespace production \
  -f 6-Helm-Deploy/todo-service/values-production.yaml

helm template production-frontend ./6-Helm-Deploy/frontend \
  --namespace production \
  -f 6-Helm-Deploy/frontend/values-production.yaml
```

---

## 5. Install Or Upgrade With Helm

The cluster already has these resources from the plain manifest phase. A first
Helm install would normally fail with ownership metadata errors because the
existing resources are not labeled as Helm-owned.

This Helm version supports:

```text
--take-ownership
```

Use it during the first migration so Helm can adopt existing resources instead
of deleting and recreating them.

In other words, ownership means Helm records the existing Deployment/Rollout,
Service, ConfigMap, StatefulSet, and related resources as part of a Helm
release. After that, `helm upgrade` can manage them. Without ownership metadata
or `--take-ownership`, Helm refuses to adopt resources it did not create.

Staging:

```bash
helm upgrade --install staging-user-service ./6-Helm-Deploy/user-service \
  --namespace staging \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/user-service/values-staging.yaml

helm upgrade --install staging-todo-service ./6-Helm-Deploy/todo-service \
  --namespace staging \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/todo-service/values-staging.yaml

helm upgrade --install staging-frontend ./6-Helm-Deploy/frontend \
  --namespace staging \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/frontend/values-staging.yaml
```

Production:

```bash
helm upgrade --install production-user-service ./6-Helm-Deploy/user-service \
  --namespace production \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/user-service/values-production.yaml

helm upgrade --install production-todo-service ./6-Helm-Deploy/todo-service \
  --namespace production \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/todo-service/values-production.yaml

helm upgrade --install production-frontend ./6-Helm-Deploy/frontend \
  --namespace production \
  --create-namespace \
  --take-ownership \
  -f 6-Helm-Deploy/frontend/values-production.yaml
```

Check:

```bash
helm list -n staging
helm list -n production

kubectl get rollouts.argoproj.io -n staging
kubectl get rollouts.argoproj.io -n production
```

---

## 6. Image Updates

For manual Helm testing, image tags can be overridden directly:

```bash
helm upgrade --install staging-frontend ./6-Helm-Deploy/frontend \
  --namespace staging \
  --take-ownership \
  -f 6-Helm-Deploy/frontend/values-staging.yaml \
  --set image.tag=5ca78aa-v1.1-staging
```

Later, the GitOps version of this flow should update Helm values in Git and let
ArgoCD sync the Helm Application.

---

## 7. Recreate Staging Database PVCs If Needed

Both staging and production database charts use:

```yaml
database:
  storageClassName: longhorn-storageclass
```

If staging PVCs were previously created with another StorageClass, Kubernetes
will not mutate the existing PVC. Because there is no important staging data
right now, delete the StatefulSets and PVCs, then install with Helm again:

```bash
kubectl delete sts -n staging user-db todo-db
kubectl delete pvc -n staging postgres-storage-user-db-0 postgres-storage-todo-db-0
```

Then run the Helm install commands from the previous section.

---

## 8. Resume ArgoCD

Do not resume ArgoCD until the ArgoCD Applications are moved to the Helm chart
paths. If ArgoCD still points to `3-Kubectl-Deploy/.../templates`, it will
continue comparing against the old plain manifests.

When ready, re-enable automated sync:

```bash
for app in \
  root-app \
  staging \
  production \
  staging-frontend \
  staging-user-service \
  staging-todo-service \
  production-frontend \
  production-user-service \
  production-todo-service
do
  kubectl patch application "$app" \
    -n argocd \
    --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done
```

For the real Helm GitOps migration, create a separate ArgoCD tree such as:

```text
homelab-gitops/
  argocd-helm/
```

and point those Applications at the Helm charts instead of the plain manifest
directories.

---

## 9. Why Helm

Helm adds indirection: you often look at a template and then jump to values.
That can feel slower than reading one plain YAML file. The benefit appears when
the same application has repeated environment-specific variants.

In this project Helm helps with:

- Keeping staging and production manifests generated from one chart.
- Changing image tags, replica counts, resources, hostnames, and storage class
  from values files instead of editing many YAML files.
- Packaging each service as a versioned deployable unit.
- Making future ArgoCD Helm Applications smaller, because ArgoCD can point to a
  chart plus values files.
- Reducing copy/paste drift between staging and production.

The style used here is a service-per-chart model. It is not one giant umbrella
chart. That keeps each microservice independently deployable and matches the
release pipeline direction.

Use plain manifests when the YAML is small, unique, and unlikely to vary by
environment. Use Helm when the same resource set needs repeatable parameterized
deployments.

---

## 10. Notes

- Backend charts include their PostgreSQL StatefulSet and headless Service.
- Production database PVCs use `longhorn-storageclass`.
- Staging database PVCs also use `longhorn-storageclass`.
- Do not casually uninstall backend releases if you care about local database
  data. Review StatefulSet/PVC retention before destructive cleanup.
