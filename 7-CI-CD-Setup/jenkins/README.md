# Jenkins Runtime Architecture

Goal: explain how the Jenkins installation itself works in Kubernetes: the
controller, JCasC settings, Kubernetes cloud, RBAC, credentials, jobs, and
plugins.

This is not the pipeline design document and not the install runbook.

Install steps:

```text
7-CI-CD-Setup/jenkins/4B-Jenkins-Install.md
```

Pipeline helper behavior:

```text
SharedLibrary/README.md
SharedLibrary/vars/*.txt
```

---

## 1. Jenkins In Kubernetes

Jenkins runs in the `jenkins` namespace.

```text
Jenkins controller
  -> StatefulSet: jenkins
  -> ServiceAccount: jenkins
  -> PVC: jenkins-home-pvc
  -> Service: jenkins
  -> HTTPRoute: jenkins.192.168.0.110.nip.io
```

The controller is the long-running Jenkins server. It stores Jenkins state under
`/var/jenkins_home`, backed by `jenkins-home-pvc`.

That state includes:

```text
job definitions
build history
plugin state
Jenkins user metadata
JCasC-managed configuration
```

Builds are not meant to run on the controller. Jenkins creates temporary
Kubernetes agent pods for builds.

---

## 2. Controller Persistence

The Helm chart is configured with an existing PVC:

```yaml
persistence:
  enabled: true
  existingClaim: jenkins-home-pvc
```

This means deleting or restarting the Jenkins pod does not delete Jenkins home.

The PVC is created before the Helm install:

```text
7-CI-CD-Setup/jenkins/jenkins-pvc.yaml
```

The controller PVC is the critical Jenkins data volume. Other Jenkins PVCs are
cache volumes used by agent pods. Their exact mount paths are defined by the
agent pod YAML used by the pipelines, not by the Jenkins controller itself.

---

## 3. JCasC

Jenkins is configured with Configuration as Code through:

```text
7-CI-CD-Setup/jenkins/jenkins-values.yaml
```

The Helm chart renders this into Jenkins Configuration as Code. In this setup,
JCasC configures:

```text
admin user source
installed plugins
Kubernetes cloud
controller environment variables
credentials
global shared library
SonarQube server
SonarQube scanner tool
UI appearance and locale
Job DSL seed jobs
```

The important rule:

```text
jenkins-values.yaml is the source of truth for Jenkins system configuration.
```

If a setting is managed by JCasC, changing it only from the UI is temporary and
can be overwritten by the next Helm/JCasC reload.

---

## 4. Config Reload

The Jenkins Helm chart runs a config reload sidecar. When the JCasC ConfigMap
changes, the sidecar can ask Jenkins to reload configuration without restarting
the controller pod.

This is why some Helm upgrades change Jenkins configuration even when
`jenkins-0` does not restart.

There is one practical caveat: Job DSL can write job config files while Jenkins
is already running, but Jenkins UI may not immediately show newly created jobs.
If the job exists under Jenkins home but does not appear in the UI, use:

```text
Manage Jenkins -> Reload Configuration from Disk
```

Do this only when no builds are running.

---

## 5. Kubernetes Cloud

The Kubernetes plugin is configured by JCasC:

```yaml
jenkins:
  clouds:
    - kubernetes:
        name: "kubernetes"
        serverUrl: "https://kubernetes.default.svc"
        namespace: "jenkins"
        jenkinsUrl: "http://jenkins.jenkins.svc.cluster.local:8080"
```

This tells Jenkins:

```text
There is a Kubernetes cloud named "kubernetes".
Use the in-cluster Kubernetes API.
Create agent pods in the jenkins namespace.
Agents should connect back to the Jenkins service inside the cluster.
```

When a Pipeline requests a Kubernetes agent, the Kubernetes plugin creates a pod
from the Pod YAML supplied by that Pipeline.

The Jenkins controller does not need to know every tool container in advance.
It only needs the Kubernetes cloud connection and permission to create agent
pods.

---

## 6. Agent Pod Lifecycle

The runtime flow is:

```text
1. A Jenkins job starts.
2. The Jenkinsfile requests a Kubernetes agent.
3. The Kubernetes plugin receives Pod YAML from the Jenkinsfile.
4. Jenkins creates a temporary pod in the jenkins namespace.
5. The pod's jnlp container connects back to the controller.
6. Pipeline steps run in the requested containers.
7. Jenkins removes the pod after the build.
```

The `jnlp` container is the Jenkins remoting container. It is how the agent pod
talks to the controller.

Other containers in the same pod are selected by Pipeline code with:

```groovy
container('container-name') {
  sh 'command'
}
```

The exact CI and release pod contents are pipeline implementation details and
are documented in the shared library, not here.

---

## 7. RBAC

`jenkins-rbac.yaml` creates:

```text
Namespace:       jenkins
ServiceAccount: jenkins
Role:           jenkins-agent-manager
RoleBinding:    jenkins-agent-manager
```

The Role is namespace-scoped. Jenkins can manage build-agent runtime objects in
the `jenkins` namespace:

```text
pods
pods/exec
pods/log
persistentvolumeclaims
events
```

Jenkins can also read:

```text
secrets
configmaps
```

This is intentionally not `cluster-admin`.

The permission exists so the Kubernetes plugin can create and manage Jenkins
agent pods. It is not the main deployment permission model for application
namespaces.

Agent pods use:

```yaml
serviceAccountName: jenkins
automountServiceAccountToken: false
```

So the pod is associated with the Jenkins ServiceAccount, but Kubernetes does
not automatically mount a service account token into the agent containers.

---

## 8. Credentials

Kubernetes secrets are created by:

```text
7-CI-CD-Setup/jenkins/jenkins-secrets.yaml
```

JCasC reads secret values from controller environment variables and creates
Jenkins credentials.

Current Jenkins credential IDs:

```text
github-token
sonarqube-token
dependency-track-api-key
kubeconfig
```

Current Kubernetes imagePullSecret:

```text
ghcr-creds
```

Difference:

```text
Jenkins credentials
  Used by Jenkins Pipeline steps, Git checkout, plugins, and helper functions.

Kubernetes imagePullSecret
  Used by Kubernetes when pulling private container images for Jenkins pods.
```

`DOCKER_CONFIG_JSON` belongs to `ghcr-creds`. It is not another GitHub token; it
is the Docker config JSON format of the GitHub token.

---

## 9. Global Shared Library

JCasC registers one global shared library:

```text
homelab-shared-library
```

Source:

```text
https://github.com/KeremAR/Homelab-SharedLibrary.git
```

Credential:

```text
github-token
```

Why Jenkins needs this setting:

```text
Jenkinsfiles can call shared Pipeline steps without redefining the Git repository
in every job.
```

This document does not describe the library's internals. The library owns
pipeline-specific logic such as lint helpers, test helpers, build helpers, and
pod templates.

---

## 10. Jobs Managed By JCasC

JCasC uses the Job DSL plugin to create Jenkins jobs.

Automatic CI job:

```text
homelab-app-ci
```

This is a Multibranch Pipeline job. Jenkins scans GitHub and creates child jobs
for matching branches and pull requests.

Manual release jobs:

```text
release-user-service
release-todo-service
release-frontend
```

These are normal parameterized Pipeline jobs. They exist because staging and
production releases are manual operations, not automatic branch-discovery jobs.

The release jobs load their Jenkinsfile from:

```text
Homelab-SharedLibrary/pipelines/release/Jenkinsfile
```

This is a Jenkins job-definition detail. The deployment logic itself is
documented in the shared library and deployment docs.

---

## 11. Multibranch Configuration

The CI job uses GitHub Branch Source:

```groovy
repoOwner('KeremAR')
repository('Homelab-App')
scriptPath('Jenkinsfile')
```

Current discovery behavior:

```groovy
includes('release/* PR-*')
excludes('feature/*')
buildOriginBranch(true)
buildOriginBranchWithPR(false)
buildOriginPRMerge(true)
buildOriginPRHead(false)
buildForkPRMerge(false)
buildForkPRHead(false)
```

Meaning:

```text
release/* branches are built.
Pull request merge jobs are built.
feature/* branch jobs are not built.
Fork pull requests are not built.
```

This belongs in Jenkins configuration because it controls which Jenkins jobs are
created and triggered.

---

## 12. Release Job Parameters

Manual release jobs use the List Git Branches Parameter plugin for branch
selection:

```groovy
listGitBranches {
  name('RELEASE_BRANCH')
  remoteURL('https://github.com/KeremAR/Homelab-App.git')
  credentialsId('github-token')
  type('BRANCH')
  branchFilter('refs/heads/(release/user-service-.*)')
}
```

The user-facing release job parameters are:

```text
RELEASE_BRANCH
DEPLOY_ENVIRONMENT
USE_CI_ARTIFACT
DEPLOY
```

This section only documents how Jenkins exposes the job parameters. What the
pipeline does with those parameters belongs to the shared library docs.

---

## 13. Plugin Map

Plugins installed in `jenkins-values.yaml`:

```text
configuration-as-code
  Loads Jenkins system configuration from JCasC.

credentials
plain-credentials
credentials-binding
  Store and expose Jenkins credentials to jobs and plugins.

git
github
github-branch-source
  Checkout Git repositories, scan GitHub branches and pull requests, and report
  commit status checks.

job-dsl
  Creates Jenkins jobs from the JCasC Job DSL script.

kubernetes
  Creates temporary Kubernetes agent pods for builds.

kubernetes-cli
  Provides Kubernetes Pipeline integrations when a job needs them.

workflow-aggregator
pipeline-stage-view
  Provides Pipeline support and stage visualization.

basic-branch-build-strategies
  Adds branch and PR build strategy controls for Multibranch jobs.

timestamper
  Adds timestamps to Jenkins build logs.

ws-cleanup
  Provides the cleanWs() Pipeline step.

locale
  Forces Jenkins UI language behavior.

antisamy-markup-formatter
  Allows Jenkins shared-library reference pages to render safe HTML.

lockable-resources
  Provides the lock() Pipeline step for serialized operations.

sonar
  Adds SonarQube server configuration, scanner tool installation,
  withSonarQubeEnv(), and waitForQualityGate().

dark-theme
  Enables the darkSystem Jenkins theme.

dependency-track
  Adds dependencyTrackPublisher() for CycloneDX SBOM upload.

copyartifact
  Allows one Jenkins job to copy archived artifacts from another Jenkins job.

list-git-branches-parameter
  Adds the branch selector used by manual release jobs.

build-user-vars-plugin
  Adds build-user environment variables for release build descriptions.
```

---

## 14. UI Settings

JCasC configures appearance:

```yaml
appearance:
  themeManager:
    disableUserThemes: true
    theme: "darkSystem"
  locale:
    systemLocale: "en"
    ignoreAcceptLanguage: true
```

`ignoreAcceptLanguage: true` prevents the browser language from changing the
Jenkins UI language.

---

## 15. Reverse Proxy URL

The public Jenkins URL is set through the Helm value:

```yaml
controller:
  jenkinsUrl: "http://jenkins.192.168.0.110.nip.io"
```

This must match the URL used in the browser. If it does not, Jenkins can show:

```text
It appears that your reverse proxy setup is broken
```

Do not duplicate the same setting under `unclassified.location.url` while the
Helm chart default JCasC config is enabled. That can create JCasC merge
conflicts.
