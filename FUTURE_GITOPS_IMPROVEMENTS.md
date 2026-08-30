# Future GitOps Improvements

This document describes planned improvements for the current GitOps structure.

The main planned change is to keep the existing **App-of-Apps** pattern and add **Argo CD ApplicationSet** to reduce repeated `Application` YAML files.

---

## Current Structure

The current GitOps repository uses an App-of-Apps structure with separate environment layers:

```text
root-app
  -> staging
       -> staging-user-service
       -> staging-todo-service
       -> staging-frontend
  -> production
       -> production-user-service
       -> production-todo-service
       -> production-frontend
```

This works well, but every service and environment needs its own Argo CD `Application` YAML file.

For example:

```text
staging-user-service.yaml
staging-todo-service.yaml
staging-frontend.yaml

production-user-service.yaml
production-todo-service.yaml
production-frontend.yaml
```

As more services are added, this creates unnecessary repeated YAML.

---

## Planned Structure

The App-of-Apps pattern will stay.

The root Application will bootstrap and manage two environment-specific `ApplicationSet` resources:

```text
                         root-app
                            |
                 manages / bootstraps
                            |
             +--------------+--------------+
             |                             |
             v                             v
     staging-services              production-services
      ApplicationSet                ApplicationSet
             |                             |
      auto sync policy              conservative policy
             |                             |
         generates                     generates
             |                             |
      +------+------+               +------+------+ 
      |      |      |               |      |      |
      v      v      v               v      v      v
    user    todo  frontend         user    todo  frontend
```

This gives us both patterns:

- **App-of-Apps** for bootstrap and high-level GitOps hierarchy.
- **ApplicationSet** for generating repeated service Applications.

---

## Why Two ApplicationSets

Staging and production should stay as separate operational units.

Instead of one large ApplicationSet for all environments, there will be:

```text
staging-services
production-services
```

This allows each environment to have its own policy.

### Staging

Staging can stay fully automatic:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

Flow:

```text
Git change
  -> Argo CD detects drift
  -> automatic sync
  -> Argo Rollouts starts the rollout
```

### Production

Production can use a more conservative policy.

For example, automatic sync can be disabled:

```yaml
# No automated sync policy
```

Flow:

```text
Git change
  -> Application becomes OutOfSync
  -> manual approval / sync
  -> Argo Rollouts starts the rollout
```

This keeps an important advantage of the current design:

> Production sync policy can later become more conservative than staging.

Production may also use stricter options later, such as disabling automatic pruning.

---

## Why ApplicationSet

ApplicationSet does not replace Argo CD.

It generates Argo CD `Application` resources from a template.

Instead of manually creating:

```text
staging-user-service
staging-todo-service
staging-frontend
production-user-service
production-todo-service
production-frontend
```

ApplicationSet creates them automatically.

The generated Applications still behave like normal Argo CD Applications.

The deployment flow remains:

```text
ApplicationSet
  -> generates Application
  -> Argo CD reads application manifests
  -> Argo CD applies Rollout resources
  -> Argo Rollouts performs progressive delivery
```

Argo Rollouts does not need any special change because of ApplicationSet.

---

## Git Directory Generator

The planned ApplicationSets will use the **Git Directory Generator**.

The infrastructure repository already has the environment and service information in its directory structure:

```text
3-Kubectl-Deploy/
  staging/
    user-service/
      templates/
    todo-service/
      templates/
    frontend/
      templates/

  production/
    user-service/
      templates/
    todo-service/
      templates/
    frontend/
      templates/
```

Because this information already exists in Git, there is no reason to write the same service list again inside the GitOps repository.

The staging ApplicationSet can watch:

```text
3-Kubectl-Deploy/staging/*/templates
```

The production ApplicationSet can watch:

```text
3-Kubectl-Deploy/production/*/templates
```

For every matching directory, ApplicationSet creates one Argo CD Application.

Example:

```text
3-Kubectl-Deploy/staging/todo-service/templates
```

becomes:

```text
staging-todo-service
```

and targets:

```text
namespace: staging
```

---

## Why Git Generator Instead of Matrix Generator

A Matrix Generator could also solve this problem.

For example:

```text
Services:
- user-service
- todo-service
- frontend

Environments:
- staging
- production
```

Matrix would create:

```text
3 services x 2 environments = 6 Applications
```

This works, but it duplicates information that already exists in the repository structure.

We would need to maintain the service list inside ApplicationSet:

```yaml
- service: user-service
- service: todo-service
- service: frontend
```

Then, when a new service is added, we would need to update both:

1. The infrastructure repository directories.
2. The ApplicationSet service list.

This creates two sources of information.

With the Git Directory Generator, the repository structure itself becomes the source.

Example:

```text
Add:

3-Kubectl-Deploy/staging/notification-service/templates
3-Kubectl-Deploy/production/notification-service/templates
```

ApplicationSet automatically discovers the new directories and creates:

```text
staging-notification-service
production-notification-service
```

No additional service entry is needed in the GitOps repository.

For the current repository layout, Git Directory Generator is simpler and keeps less duplicated configuration than Matrix Generator.

---

## Planned GitOps Repository Layout

The GitOps repository can be simplified to something similar to:

```text
argocd-manifests/
  root-application.yaml

  applicationsets/
    staging.yaml
    production.yaml
```

The large number of per-service Application files can be removed.

The root Application watches the `applicationsets/` directory and creates the two ApplicationSets.

---

## Example Staging ApplicationSet

A simplified staging configuration can look like this:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: staging-services
  namespace: argocd

spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error

  generators:
    - git:
        repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
        revision: main
        directories:
          - path: '3-Kubectl-Deploy/staging/*/templates'

  template:
    metadata:
      name: 'staging-{{index .path.segments 2}}'
      labels:
        environment: staging

    spec:
      project: default

      source:
        repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
        targetRevision: main
        path: '{{.path.path}}'

      destination:
        server: https://kubernetes.default.svc
        namespace: staging

      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

---

## Example Production ApplicationSet

Production can use the same Git discovery logic but a different sync policy:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: production-services
  namespace: argocd

spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error

  generators:
    - git:
        repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
        revision: main
        directories:
          - path: '3-Kubectl-Deploy/production/*/templates'

  template:
    metadata:
      name: 'production-{{index .path.segments 2}}'
      labels:
        environment: production

    spec:
      project: default

      source:
        repoURL: https://github.com/KeremAR/Homelab-Infrastructure.git
        targetRevision: main
        path: '{{.path.path}}'

      destination:
        server: https://kubernetes.default.svc
        namespace: production

      # Keep production sync more conservative.
      # Automated sync can be enabled later if needed.
```

---

## Expected Benefits

After this change:

- The App-of-Apps bootstrap model stays in place.
- Staging and production remain separate operational units.
- Staging and production can have different sync policies.
- Per-service Argo CD Application YAML files are removed.
- New services can be discovered automatically from Git directories.
- There is less repeated configuration.
- Adding a service requires fewer GitOps changes.
- Argo Rollouts continues to work without changes.
- The GitOps repository becomes easier to maintain as the number of services grows.

---

## Possible Future Improvements

After ApplicationSet is added, the following improvements can be considered later:

### Progressive Delivery Analysis

Connect Argo Rollouts with Prometheus `AnalysisTemplate` resources.

Example flow:

```text
new image
  -> 10% traffic
  -> check error rate and latency
  -> PASS
  -> 25%
  -> check metrics
  -> PASS
  -> 50%
  -> 100%
```

This would make the existing rollout strategy metric-driven instead of only using fixed pauses.

### Platform Components in App-of-Apps

The root GitOps structure may later manage platform components too:

```text
root-app
  -> platform
       -> Argo Rollouts
       -> cert-manager
       -> Prometheus
       -> other platform tools

  -> staging ApplicationSet
  -> production ApplicationSet
```

This would allow a larger part of the cluster to be bootstrapped and managed from Git.

---

## Final Target

The planned GitOps model is:

```text
Developer / Jenkins
  -> build image
  -> push image to GHCR
  -> update image tag in Homelab-Infrastructure
  -> commit and push
  -> Argo CD detects the change
  -> generated Application syncs the service
  -> Argo Rollouts performs the rollout
```

ApplicationSet changes how Argo CD `Application` resources are created.

It does not replace Jenkins, Argo CD, or Argo Rollouts.

The final goal is to keep the current GitOps architecture while reducing repeated YAML and keeping staging and production independently manageable.
