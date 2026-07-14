# Jenkins Setup

Goal: install Jenkins on the Kubernetes cluster with Helm and JCasC. This first phase is intentionally small:

- Jenkins controller runs in the `jenkins` namespace.
- Jenkins is configured with JCasC.
- GitHub credentials come from Kubernetes Secrets.
- App CI is created as a Multibranch Pipeline.
- The pipeline agent pod template lives in the shared library.
- The agent uses PVC-backed caches for Trivy and Python virtualenvs.
- SonarQube integration uses a token generated from SonarQube after it is installed.
- ArgoCD, GitOps deploy, Docker image build, and production deploy are not included yet.

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
  ci-python-test-runner.Dockerfile
```

`jenkins-values.yaml` is used by the Jenkins Helm chart. The other YAML files are applied with `kubectl`.

SonarQube has its own install notes in:

```text
4-Jenkins-Setup/sonarqube.md
```

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

Jenkins uses a dedicated single-replica Longhorn StorageClass:

```text
longhorn-jenkins-single
```

Reason: Jenkins cache volumes are not critical application data. With Longhorn
replica count `3`, the 28Gi Jenkins PVC set needs roughly 84Gi of Longhorn
replica capacity. Single replica keeps disk usage reasonable for the homelab.

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
# Fill this after SonarQube is installed and a token is generated.
SONAR_TOKEN=squ_your_token_here
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

## 5. Create Jenkins StorageClass And PVCs

```bash
kubectl apply -f 4-Jenkins-Setup/jenkins-storageclass.yaml
kubectl apply -f 4-Jenkins-Setup/jenkins-pvc.yaml
kubectl get pvc -n jenkins
```

PVCs:

```text
jenkins-home-pvc
jenkins-npm-cache-pvc
jenkins-trivy-cache-pvc
jenkins-venv-cache-pvc
```

These PVCs use Longhorn with one replica:

```yaml
storageClassName: longhorn-jenkins-single
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
jenkins-app-secrets
ghcr-creds
```

If `envsubst` is missing on Debian/Ubuntu:

```bash
sudo apt install -y gettext-base
```

If SonarQube is not installed yet, `SONAR_TOKEN` can stay as a placeholder.
Before upgrading Jenkins with SonarQube enabled, generate a real token in the
SonarQube UI and re-apply `jenkins-secrets.yaml`.

---

## 7. Install Jenkins With Helm

Before installing Jenkins, build and push the CI runner image referenced by the shared library pod template.

Build:

```bash
docker build \
  -f 4-Jenkins-Setup/ci-python-test-runner.Dockerfile \
  -t ghcr.io/keremar/ci-python-test-runner:py3.11-v1 .
```

Login to GHCR:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
```

Push:

```bash
docker push ghcr.io/keremar/ci-python-test-runner:py3.11-v1
```

This image contains common CI tools only. Service dependencies are still installed later into the PVC-backed venv cache.

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

Important: the shared library pod template currently references this CI agent image:

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
- SonarQube credentials exist as `sonarqube-token`.
- SonarQube scanner tool exists as `SonarQube Scanner`.
- SonarQube server exists as `sonarqube`.
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

The Kubernetes agent pod template is intentionally not stored in `jenkins-values.yaml`. It lives in the shared library:

```text
SharedLibrary/src/com/company/jenkins/Utils.groovy
SharedLibrary/vars/ciPythonPodTemplate.groovy
SharedLibrary/resources/com/company/jenkins/pods/lint-pod.yaml
```

That keeps pipeline runtime details versioned with pipeline code instead of Jenkins installation config.
The pod template is loaded with `libraryResource`, so changing the pod YAML requires committing and pushing the `SharedLibrary` repo.

Because `SharedLibrary` is a Git submodule, Jenkins will not read the local working tree directly. Commit and push the shared library repo before expecting Jenkins to use a changed helper:

```bash
cd SharedLibrary
git add README.md src/com/company/jenkins/Utils.groovy vars/ciPythonPodTemplate.groovy
git commit -m "Add CI Python pod template"
git push
```

Then update the submodule pointer in the infrastructure repo when needed.

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
- Kubernetes dynamic agents, with pod template supplied by the shared library
- frontend linting through the `node` container
- Dockerfile linting through the `hadolint` container
- Trivy cache

Added:

- Longhorn-backed PVCs
- venv cache PVC
- npm cache PVC
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

Reverse proxy warning in Jenkins UI:

```text
It appears that your reverse proxy setup is broken
```

Jenkins must know the same public URL that the browser uses. Keep these values in `jenkins-values.yaml`:
Jenkins must know the same public URL that the browser uses. Keep this value in `jenkins-values.yaml`:

```yaml
controller:
  jenkinsUrl: "http://jenkins.192.168.0.110.nip.io"
```

Do not also set `unclassified.location.url` manually while `controller.JCasC.defaultConfig` is enabled. The Jenkins Helm chart already renders the location URL from `controller.jenkinsUrl`; setting both causes a JCasC conflict.

JCasC obsolete `git` warning:

```text
'git' is obsolete, please use 'gitSource'
```

Use `gitSource` for the global shared library retriever.

Re-apply changed values:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 4-Jenkins-Setup/jenkins-values.yaml \
  --timeout 10m \
  --wait
```

ServiceAccount ownership error:

```text
ServiceAccount "jenkins" exists and cannot be imported into the current release
```

This happens when the Jenkins ServiceAccount was created with `kubectl`, but the Helm chart also tries to create it. Keep this setting at the top level of `jenkins-values.yaml`:

```yaml
serviceAccount:
  create: false
  name: jenkins
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
