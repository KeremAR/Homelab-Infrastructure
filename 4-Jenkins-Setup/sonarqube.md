# SonarQube Setup

Goal: install SonarQube for Jenkins code quality analysis. Jenkins runs the
pipeline; SonarQube stores analysis results, issues, quality gates, and coverage.

SonarQube URL after install:

```text
http://sonarqube.192.168.0.110.nip.io
```

---

## 1. Files

```text
4-Jenkins-Setup/
  sonarqube.md
  sonarqube-secrets.yaml
  sonarqube-pvc.yaml
  sonarqube-postgresql-values.yaml
  sonarqube-values.yaml
  sonarqube-httproute.yaml
```

`sonarqube-values.yaml` is used by the SonarQube Helm chart.
`sonarqube-pvc.yaml` creates two manually managed claims using the cluster-wide,
single-replica `longhorn-storageclass`: 2 GiB for PostgreSQL and 5 GiB for the
SonarQube application.
`sonarqube-postgresql-values.yaml` is used by the PostgreSQL Helm chart.
`sonarqube-httproute.yaml` exposes SonarQube through Envoy Gateway.

---

## 2. Why PostgreSQL Is Separate

Older SonarQube Helm chart versions could install PostgreSQL as a chart
dependency. Current SonarQube charts removed that dependency.

The chart can bootstrap with embedded H2, but H2 is not the state model we want
for a homelab CI service. SonarQube data should survive pod restarts and chart
upgrades, so this setup uses a separate PostgreSQL release.

Official migration guidance after the dependency removal is also this shape:
move the database out, then point SonarQube at it with JDBC settings.

Chosen setup:

```text
SonarQube Helm chart -> SonarQube app
PostgreSQL Helm chart -> SonarQube database
jdbcOverwrite -> connects SonarQube to PostgreSQL
```

Bitnami PostgreSQL is not mandatory. It is just the smallest clean option for
now. Later alternatives are CloudNativePG, CrunchyData, Zalando Postgres
Operator, a manual StatefulSet, or an external managed PostgreSQL.

Version pins:

```text
SonarQube Helm chart: 2026.3.1
SonarQube app version: 2026.3.1
PostgreSQL Helm chart: 18.7.13
PostgreSQL app version: 18.4.0
```

These versions come from `helm search repo ... --versions` after `helm repo
update`. The chart version is pinned; image tags are left to the chart defaults.

---

## 3. Secrets

SonarQube secrets are not Jenkins secrets. They live in the `sonarqube`
namespace.

Add these values to local `.env`:

```bash
SONARQUBE_POSTGRES_ADMIN_PASSWORD=change-me
SONARQUBE_DB_PASSWORD=change-me
SONARQUBE_MONITORING_PASSCODE=change-me
```

`SONARQUBE_POSTGRES_ADMIN_PASSWORD` is the PostgreSQL admin password.

`SONARQUBE_DB_PASSWORD` is the password for the `sonarqube` PostgreSQL user.
The old script had the application user password hardcoded as `sonarqube123`.

`SONARQUBE_MONITORING_PASSCODE` is used by the SonarQube chart for internal
liveness/monitoring calls. The old script also had it hardcoded as
`monitoringPasscode: "define_it"`.

Apply:

```bash
set -a
source .env
set +a

envsubst < 4-Jenkins-Setup/sonarqube-secrets.yaml | kubectl apply -f -
```

Expected:

```text
namespace/sonarqube
secret/sonarqube-db-secret
secret/sonarqube-monitoring-secret
```

`sonarqube-db-secret` must contain both keys:

```text
postgres-password
password
```

`postgres-password` is for the PostgreSQL admin user. `password` is for the
`sonarqube` application user.

---

## 4. Install Helm Repositories

SonarQube and PostgreSQL come from separate Helm repos.

```bash
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

---

## 5. Install PostgreSQL

PostgreSQL is installed first because SonarQube needs a database at startup.
Create its dedicated PVC before applying the PostgreSQL Helm values:

```bash
kubectl apply -f 4-Jenkins-Setup/sonarqube-pvc.yaml
kubectl get pvc sonarqube-postgresql-pvc sonarqube-data-pvc -n sonarqube
```

The PostgreSQL values set
`primary.persistence.existingClaim: sonarqube-postgresql-pvc`, so the chart
mounts this claim.

```bash
helm upgrade --install sonarqube-postgresql bitnami/postgresql \
  --namespace sonarqube \
  --version 18.7.13 \
  --values 4-Jenkins-Setup/sonarqube-postgresql-values.yaml \
  --timeout 10m \
  --wait
```

Check:

```bash
kubectl get pods -n sonarqube
kubectl get pvc -n sonarqube
```

---

## 6. Install SonarQube

SonarQube runs as Community Build and connects to PostgreSQL through
`jdbcOverwrite`. Its values set
`persistence.existingClaim: sonarqube-data-pvc`, so the chart mounts the
manually created application claim instead of generating a PVC.

```bash
helm upgrade --install sonarqube sonarqube/sonarqube \
  --namespace sonarqube \
  --version 2026.3.1 \
  --values 4-Jenkins-Setup/sonarqube-values.yaml \
  --timeout 20m \
  --wait
```

SonarQube can take several minutes to become ready because it starts its web
process and embedded search engine.

Check:

```bash
kubectl get pods -n sonarqube
kubectl logs -n sonarqube statefulset/sonarqube-sonarqube
```

---

## 7. Expose SonarQube

This cluster already uses Envoy Gateway and the shared Gateway IP
`192.168.0.110`, so SonarQube is exposed with HTTPRoute.

```bash
kubectl apply -f 4-Jenkins-Setup/sonarqube-httproute.yaml
kubectl get httproute -n sonarqube
```

Open:

```text
http://sonarqube.192.168.0.110.nip.io
```

Initial login:

```text
admin / admin
```

Change the admin password after first login.

---

## 8. Create Jenkins Token

Jenkins does not need the SonarQube DB password or monitoring passcode.
Jenkins only needs a SonarQube user token for analysis.

In SonarQube:

```text
My Account > Security > Generate Token
```

Add the token to `.env`:

```bash
SONAR_TOKEN=squ_your_token_here
```

Re-apply Jenkins secrets:

```bash
set -a
source .env
set +a
export GITHUB_DOCKER_AUTH=$(printf "%s:%s" "$GITHUB_USERNAME" "$GITHUB_TOKEN" | base64 -w0)

envsubst < 4-Jenkins-Setup/jenkins-secrets.yaml | kubectl apply -f -
```

Then upgrade Jenkins so JCasC creates:

```text
sonarqube-token credential
SonarQube Scanner tool
sonarqube server URL
```

### What Jenkins Creates For SonarQube

The Jenkins Helm values install the `sonar` plugin:

```yaml
installPlugins:
  - sonar
```

That plugin adds two important Jenkins features:

- a `SonarQube Scanner` tool type under Jenkins tools
- a `SonarQube servers` section under global configuration

JCasC uses those plugin-provided configuration types.

First, the SonarQube token is stored in Kubernetes:

```text
jenkins-app-secrets
  sonar-token: SONAR_TOKEN
```

Then the Jenkins pod receives it as an environment variable:

```yaml
SONAR_TOKEN <- jenkins-app-secrets/sonar-token
```

Then JCasC turns that environment variable into a Jenkins credential:

```text
credentialsId: sonarqube-token
secret: ${SONAR_TOKEN}
```

This keeps the token out of `jenkins-values.yaml`.

Next, JCasC creates the SonarQube server entry:

```text
name: sonarqube
serverUrl: http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000
credentialsId: sonarqube-token
```

This is what `withSonarQubeEnv('sonarqube')` uses in the pipeline. It injects
the SonarQube URL and token into the scanner environment.

SonarQube server does not scan the repository by itself. The server stores
analysis results, shows issues, calculates Quality Gates, and sends webhook
callbacks. It does not have the Jenkins workspace, checked-out branch, generated
coverage XML, or pipeline context.

The scanner runs inside the Jenkins agent, where the code actually exists:

```text
Jenkins agent
  checkout repo
  run tests
  produce coverage reports
  run sonar-scanner

sonar-scanner
  reads source files and reports
  sends analysis to SonarQube server

SonarQube server
  stores the result
  calculates Quality Gate
  notifies Jenkins through webhook
```

The name is `sonarqube` instead of `sq1` because the shared library already
defaults to:

```groovy
withSonarQubeEnv(serverName ?: 'sonarqube')
```

Using `sonarqube` keeps the Jenkins global config, shared library default, and
cluster service name easy to connect mentally. `sq1` would also work, but then
each pipeline would need to pass `serverName: 'sq1'` or the shared library
default would have to change.

Finally, JCasC installs the scanner tool:

```text
tool name: SonarQube Scanner
installer: sonar-scanner 7.3.0.5189
```

This is what the pipeline uses here:

```groovy
def scannerHome = tool 'SonarQube Scanner'
sh "${scannerHome}/bin/sonar-scanner"
```

The Jenkins agent pod mounts `jenkins-tools-cache-pvc` at:

```text
/home/jenkins/agent/tools
```

That path is the agent tools directory used by Jenkins tool installers. With the
PVC mounted there, the SonarQube Scanner download can survive new ephemeral
Kubernetes agent pods.

This cache only stores Jenkins-side tool binaries. It is separate from the
SonarQube server and from SonarQube's PostgreSQL database.

So the Jenkins-side flow is:

```text
SONAR_TOKEN in .env
-> jenkins-app-secrets
-> Jenkins pod env SONAR_TOKEN
-> Jenkins credential sonarqube-token
-> SonarQube server named sonarqube
-> withSonarQubeEnv('sonarqube')
-> sonar-scanner uses URL + token
-> waitForQualityGate waits for webhook result
```

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 4-Jenkins-Setup/jenkins-values.yaml \
  --timeout 10m \
  --wait
```

---

## 9. Webhook

`waitForQualityGate` needs SonarQube to call Jenkins back after analysis.

Create webhook in SonarQube:

```text
Administration > Configuration > Webhooks
```

Webhook URL:

```text
http://jenkins.192.168.0.110.nip.io/sonarqube-webhook/
```
