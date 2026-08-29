# Jenkins Install

Goal: install Jenkins on the Kubernetes cluster with Helm and JCasC.

This file is the runbook. It should stay focused on installation order and the
commands needed to bring Jenkins up.

For how Jenkins works after installation, read:

```text
7-CI-CD-Setup/jenkins/4A-Jenkins.md
```

Jenkins URL after install:

```text
http://jenkins.192.168.0.110.nip.io
```

---

## 1. Files

```text
7-CI-CD-Setup/jenkins/
  4A-Jenkins.md
  4B-Jenkins-Install.md
  jenkins-rbac.yaml
  jenkins-pvc.yaml
  jenkins-secrets.yaml
  jenkins-values.yaml
  jenkins-httproute.yaml
  ci-python-test-runner.Dockerfile
  ci-python-uv-runner.Dockerfile
  kubernetes-tools.Dockerfile
```

---

## 2. Prerequisites

Earlier infrastructure steps should already be complete:

```text
Kubernetes cluster is running
MetalLB is installed
Envoy Gateway is installed
shared-gateway exists in namespace envoy-gateway
Longhorn is installed
longhorn-storageclass exists
Helm is installed locally
kubectl points to the target cluster
```

Check:

```bash
kubectl get nodes
kubectl get sc
kubectl get gateway -n envoy-gateway
helm version --short
```

Expected Gateway address:

```text
192.168.0.110
```

Expected StorageClass:

```text
longhorn-storageclass
```

No manual PV is needed. Longhorn dynamically creates PVs when the PVCs are
created.

---

## 3. Prepare GitHub Token

One GitHub token is enough for this setup.

Required access:

```text
read app repository
read shared library repository
read GitOps/infrastructure repository
read GHCR packages if custom agent images are private
write GHCR packages for release image push
push to Homelab-Infrastructure for deploy updates
```

Keep the token local. Do not commit it.

---

## 4. Prepare Docker Config JSON

`DOCKER_CONFIG_JSON` is not a second token. It is the base64 encoded Docker
config JSON used by the Kubernetes `ghcr-creds` imagePullSecret.

You can generate it after logging in to GHCR:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
cat ~/.docker/config.json
```

If the file contains an `auths.ghcr.io.auth` entry, encode the Docker config:

```bash
export DOCKER_CONFIG_JSON=$(cat ~/.docker/config.json | base64 -w0)
```

If the file uses a `credsStore` entry and `auths.ghcr.io` is empty, Kubernetes
cannot use it as an imagePullSecret. Create a minimal config instead:

```bash
GHCR_AUTH=$(printf "%s:%s" "$GITHUB_USERNAME" "$GITHUB_TOKEN" | base64 -w0)

cat > /tmp/ghcr-dockerconfig.json <<EOF
{
  "auths": {
    "ghcr.io": {
      "auth": "$GHCR_AUTH"
    }
  }
}
EOF

export DOCKER_CONFIG_JSON=$(base64 -w0 /tmp/ghcr-dockerconfig.json)
```

Then copy the value into `.env`.

---

## 5. Prepare SonarQube Token

If SonarQube is already installed, generate a token from the SonarQube UI:

```text
My Account -> Security -> Generate Token
```

Copy it into `.env` as:

```text
SONAR_TOKEN=squ_your_token_here
```

If SonarQube is not installed yet, use a placeholder and update the secret later.

---

## 6. Prepare Dependency-Track API Key

If Dependency-Track is already installed, create an API key from its UI and copy
it into `.env` as:

```text
DEPENDENCY_TRACK_API_KEY=odt_your_api_key_here
```

If Dependency-Track is not installed yet, use a placeholder and update the
secret later.

---

## 7. Prepare Kubeconfig

This is only needed for release helpers that directly run `kubectl` or `helm`
against the cluster. The preferred ArgoCD GitOps path updates Git and lets
ArgoCD sync.

Take the kubeconfig from the Kubernetes master VM:

```bash
ssh <master-vm-user>@<master-vm-ip>

# kubeadm clusters usually keep the admin kubeconfig here:
sudo cp /etc/kubernetes/admin.conf /tmp/homelab-kubeconfig
sudo chown "$USER:$USER" /tmp/homelab-kubeconfig

# k3s clusters usually keep it here:
# sudo cp /etc/rancher/k3s/k3s.yaml /tmp/homelab-kubeconfig
# sudo chown "$USER:$USER" /tmp/homelab-kubeconfig
```

Make sure the Kubernetes API server address is the master VM IP, not
`127.0.0.1`.

Then encode it as one line:

```bash
base64 -w0 /tmp/homelab-kubeconfig
```

Copy the output into `.env` as:

```text
KUBECONFIG_B64=base64_encoded_kubeconfig
```

Base64 is used here to avoid multiline YAML and shell quoting problems while the
value moves through `.env`, `envsubst`, a Kubernetes Secret, controller
environment variables, and JCasC.

---

## 8. Create Local `.env`

Create `.env` in the infrastructure repo root:

```bash
cd /mnt/c/Users/kerem/Documents/infrastructure

cat > .env <<'EOF'
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=change-me
GITHUB_USERNAME=KeremAR
GITHUB_TOKEN=ghp_your_token_here
DOCKER_CONFIG_JSON=base64_encoded_docker_config_json
SONAR_TOKEN=squ_your_token_here
DEPENDENCY_TRACK_API_KEY=odt_your_api_key_here
KUBECONFIG_B64=base64_encoded_kubeconfig
EOF
```

Do not commit `.env`.

---

## 9. Create Namespace And RBAC

```bash
kubectl apply -f 7-CI-CD-Setup/jenkins/jenkins-rbac.yaml
```

Check:

```bash
kubectl get namespace jenkins
kubectl get serviceaccount -n jenkins jenkins
kubectl get role,rolebinding -n jenkins
```

---

## 10. Create Jenkins PVCs

```bash
kubectl apply -f 7-CI-CD-Setup/jenkins/jenkins-pvc.yaml
kubectl get pvc -n jenkins
```

Current PVCs:

```text
jenkins-home-pvc
jenkins-tools-cache-pvc
jenkins-npm-cache-pvc
jenkins-trivy-cache-pvc
jenkins-sonar-cache-pvc
jenkins-docker-cache-user-service-pvc
jenkins-docker-cache-todo-service-pvc
jenkins-docker-cache-frontend-pvc
jenkins-venv-cache-pvc
jenkins-uv-cache-pvc
```

`jenkins-venv-cache-pvc` remains for legacy pip-based Shared Library steps.
Current uv pipelines mount `jenkins-uv-cache-pvc` at `/cache/uv` and persist
only uv download/build cache data.

---

## 11. Create Secrets From `.env`

Load `.env`:

```bash
set -a
source .env
set +a
```

Apply the declarative Secret manifest:

```bash
envsubst < 7-CI-CD-Setup/jenkins/jenkins-secrets.yaml | kubectl apply -f -
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

---

## 12. Build Required Agent Images

Build and push the CI Python runner:

```bash
docker build \
  -f 7-CI-CD-Setup/jenkins/ci-python-uv-runner.Dockerfile \
  -t ghcr.io/keremar/ci-python-test-runner:py3.11-uv-v1 .

docker push ghcr.io/keremar/ci-python-test-runner:py3.11-uv-v1
```

This runner contains Python 3.11, uv 0.12.1, and Ruff 0.16.0. Service test
dependencies come from each application's committed `uv.lock`; they are not
baked into the runner image.

Build and push the Kubernetes tools image:

```bash
docker build \
  -f 7-CI-CD-Setup/jenkins/kubernetes-tools.Dockerfile \
  -t ghcr.io/keremar/kubernetes-tools:kubectl-1.36.1-helm-3.20.1-argocd-3.4.2-rollouts-1.9.1 .

docker push ghcr.io/keremar/kubernetes-tools:kubectl-1.36.1-helm-3.20.1-argocd-3.4.2-rollouts-1.9.1
```

---

## 13. Install Jenkins With Helm

Add the Jenkins Helm repo:

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

Install or upgrade Jenkins:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 7-CI-CD-Setup/jenkins/jenkins-values.yaml \
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

---

## 14. Expose Jenkins

```bash
kubectl apply -f 7-CI-CD-Setup/jenkins/jenkins-httproute.yaml
kubectl get httproute -n jenkins
```

Open:

```text
http://jenkins.192.168.0.110.nip.io
```

Login with:

```text
JENKINS_ADMIN_USER
JENKINS_ADMIN_PASSWORD
```
