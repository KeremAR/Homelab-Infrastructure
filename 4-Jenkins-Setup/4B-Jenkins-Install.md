# Jenkins Setup

Goal: install Jenkins on the Kubernetes cluster with Helm and JCasC. This first phase is intentionally small:

- Jenkins controller runs in the `jenkins` namespace.
- Jenkins is configured with JCasC.
- GitHub credentials come from Kubernetes Secrets.
- App CI is created as a Multibranch Pipeline.
- The agent has PVC-backed caches for Trivy and Python virtualenvs.
- SonarQube, ArgoCD, GitOps deploy, Docker image build, and production deploy are not included yet.

Current Jenkins URL after install:

```text
http://jenkins.192.168.0.110.nip.io
```

---

## 1. Files

This folder contains the Jenkins install manifests:

```text
4-Jenkins-Setup/
  4A-Jenkins.md
  jenkins-rbac.yaml
  jenkins-pvc.yaml
  jenkins-secrets.yaml
  jenkins-values.yaml
  jenkins-httproute.yaml
```

`jenkins-values.yaml` is used by the Jenkins Helm chart. The other YAML files are applied with `kubectl`.

---

## 2. Prerequisites

The earlier infrastructure steps should already be done:

- Kubernetes cluster is running.
- MetalLB is installed.
- NGINX Gateway Fabric is installed.
- `shared-gateway` exists in namespace `nginx-gateway`.
- Longhorn is installed.
- Longhorn StorageClass exists.
- Helm is installed locally.
- `kubectl` points to the target cluster.

Check:

```bash
kubectl get nodes
kubectl get sc
kubectl get gateway -n nginx-gateway
helm version --short
```

Expected Gateway address:

```text
192.168.0.110
```

Expected StorageClass:

```text
longhorn
```

No manual PV is needed for Jenkins in this setup. Longhorn dynamically creates PVs when the Jenkins PVCs are created.

---

## 3. Prepare GitHub Token

One GitHub token is enough for this phase.

Required access:

- read the app repository
- read the shared library repository
- read GHCR packages if the Jenkins agent image is private

Later, when image push is added, the same token can also need `write:packages`.

Create a local `.env` file in the infrastructure repo root:

```bash
cd /mnt/c/Users/kerem/Documents/infrastructure

cat > .env <<'EOF'
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=change-me
GITHUB_USERNAME=KeremAR
GITHUB_TOKEN=ghp_your_token_here
EOF
```

Do not commit `.env`.

`GITHUB_DOCKER_AUTH` is not a second token. It is only this value:

```text
base64("GITHUB_USERNAME:GITHUB_TOKEN")
```

It is needed because `jenkins-secrets.yaml` declares the GHCR pull secret in Kubernetes `dockerconfigjson` format.

---

## 4. Create Namespace And RBAC

```bash
kubectl apply -f 4-Jenkins-Setup/jenkins-rbac.yaml
```

This creates:

- `jenkins` namespace
- `jenkins` ServiceAccount
- namespace-scoped Role/RoleBinding for Jenkins agent pod management

This is intentionally not `cluster-admin`. The first phase only needs Jenkins to run CI agents in its own namespace.

---

## 5. Create PVCs

```bash
kubectl apply -f 4-Jenkins-Setup/jenkins-pvc.yaml
kubectl get pvc -n jenkins
```

PVCs:

```text
jenkins-home-pvc
jenkins-trivy-cache-pvc
jenkins-venv-cache-pvc
```

These PVCs use Longhorn:

```yaml
storageClassName: longhorn
```

Old setup note: the previous K3s install created manual `hostPath` PVs because it depended on `local-path` and a fixed node name, `k3s-worker`. This cluster should not use that pattern.

---

## 6. Create Secrets From `.env`

Load `.env`:

```bash
set -a
source .env
set +a
```

Create the Docker auth value:

```bash
export GITHUB_DOCKER_AUTH=$(printf "%s:%s" "$GITHUB_USERNAME" "$GITHUB_TOKEN" | base64 -w0)
```

Apply the declarative Secret manifest with `envsubst`:

```bash
envsubst < 4-Jenkins-Setup/jenkins-secrets.yaml | kubectl apply -f -
```

Check:

```bash
kubectl get secret -n jenkins
```

Expected secrets:

```text
jenkins-admin-secret
jenkins-github-secret
ghcr-creds
```

If `envsubst` is missing on Debian/Ubuntu:

```bash
sudo apt install -y gettext-base
```

---

## 7. Install Jenkins With Helm

Add the Jenkins Helm repo:

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

Install:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 4-Jenkins-Setup/jenkins-values.yaml \
  --timeout 10m \
  --wait
```

Check:

```bash
kubectl get pods -n jenkins
kubectl get svc -n jenkins
kubectl get pvc -n jenkins
```

Jenkins controller should become `Running`.

Important: `jenkins-values.yaml` currently references this CI agent image:

```text
ghcr.io/keremar/ci-python-test-runner:py3.11-v1
```

That image must exist and Jenkins must be able to pull it. If it does not exist yet, either build/push it first or temporarily change the agent image.

---

## 8. Expose Jenkins

```bash
kubectl apply -f 4-Jenkins-Setup/jenkins-httproute.yaml
kubectl get httproute -n jenkins
```

Open:

```text
http://jenkins.192.168.0.110.nip.io
```

Login uses the values from `.env`:

```text
JENKINS_ADMIN_USER
JENKINS_ADMIN_PASSWORD
```

---

## 9. Verify JCasC

In Jenkins UI, check:

- Jenkins language is English.
- `homelab-shared-library` exists under global libraries.
- `homelab-app-ci` Multibranch Pipeline exists.
- GitHub credentials exist as `github-token`.
- Kubernetes cloud exists.

From CLI:

```bash
kubectl logs -n jenkins statefulset/jenkins
```

If JCasC fails, the controller logs usually show the exact YAML path or plugin symbol that failed.

---

## 10. Multibranch Pipeline

The JCasC job creates:

```text
homelab-app-ci
```

It scans:

```text
https://github.com/KeremAR/Homelab-App
```

It expects:

```text
Jenkinsfile
```

at the root of the app repo.

Multibranch Pipeline means Jenkins discovers branches and pull requests automatically. For this project it will be used for CI:

- `feature/*` branch push
- PR into `release/*`
- updates on `release/*`

Manual staging/production deploy should be a separate parameterized job later.

---

## 11. What Changed From The Old Jenkins Install

Removed for this phase:

- SonarQube plugin/config/token
- ArgoCD credentials and CLI config
- GitOps manifest update logic
- `cluster-admin`
- manual `hostPath` PVs
- `local-path`
- `k3s-worker` node affinity
- Docker-in-Docker cache PVC
- Blue Ocean

Kept or adapted:

- Helm chart install
- JCasC
- GitHub Branch Source
- Multibranch Pipeline
- Shared Library
- Kubernetes dynamic agents
- Trivy cache

Added:

- Longhorn-backed PVCs
- venv cache PVC
- narrower namespace RBAC
- English Jenkins UI locale
- declarative Secret YAML with `.env` + `envsubst`

---

## 12. Troubleshooting

PVC pending:

```bash
kubectl get sc
kubectl describe pvc -n jenkins jenkins-home-pvc
```

If Longhorn is default or `storageClassName: longhorn` exists, PVCs should bind.

Jenkins pod pending:

```bash
kubectl describe pod -n jenkins -l app.kubernetes.io/component=jenkins-controller
```

Agent cannot pull image:

```bash
kubectl describe pod -n jenkins
kubectl get secret ghcr-creds -n jenkins
```

JCasC job not created:

```bash
kubectl logs -n jenkins statefulset/jenkins | grep -i casc
```

Re-apply changed values:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 4-Jenkins-Setup/jenkins-values.yaml \
  --timeout 10m \
  --wait
```

---

## 13. Current Pipeline Plan

The pipeline design is still:

```text
feature push        -> lint + static checks + unit tests
PR to release/*     -> lint + static checks + unit tests
merge to release/*  -> release-candidate checks
manual staging      -> build selected service image and deploy staging
manual production   -> promote same image digest to production
```

Manual deploy parameters later:

```text
SERVICE=frontend | user-service | todo-service
ENV=staging | production
BRANCH=release/3.40
```

Version is derived from the branch name:

```text
release/3.40 -> v3.40
```

Image tag format:

```text
<service>:<commit>-v<release-version>-staging
<service>:<commit>-v<release-version>-prod
```

Example:

```text
todo-service:abc1234-v3.40-staging
todo-service:abc1234-v3.40-prod
```

Production should not rebuild. It should retag/promote the same digest that was tested in staging.
