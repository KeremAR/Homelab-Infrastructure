# Jenkins Pipeline Plan

Goal: keep app code and Kubernetes config separate, then let Jenkins validate code automatically and deploy only the selected service manually.

Current application repository:

```text
Homelab-App
├── frontend
├── user-service
└── todo-service
```

Current Jenkins jobs:

```text
homelab-app-ci       -> Multibranch Pipeline, automatic CI
homelab-app-release  -> later, manual parameterized deploy pipeline
```

The CI job proves whether code is healthy. The release/deploy job will build and deploy a selected service when we explicitly ask for it.

---

## 1. Why Multibranch Pipeline?

`homelab-app-ci` is a Jenkins Multibranch Pipeline.

A normal Pipeline job usually runs one fixed `Jenkinsfile` and often needs parameters to select a branch. A Multibranch Pipeline scans a Git repository and creates child jobs for discovered branches and pull requests.

This fits CI because Jenkins can automatically run the same `Jenkinsfile` for:

```text
release/* branch updates
pull requests
```

Feature branch pushes are intentionally not built by Jenkins. Local feedback should come from the dev container and pre-commit hooks. Central CI starts when a PR is opened.

The job is created from JCasC/Job DSL:

```groovy
multibranchPipelineJob('homelab-app-ci')
```

The repository source is GitHub:

```groovy
repoOwner('KeremAR')
repository('Homelab-App')
scriptPath('Jenkinsfile')
```

---

## 2. Branch And PR Discovery

Current GitHub branch source behavior:

```groovy
buildOriginBranch(true)
buildOriginBranchWithPR(false)
buildOriginPRMerge(true)
buildOriginPRHead(false)
buildForkPRMerge(false)
buildForkPRHead(false)
includes('release/* PR-*')
excludes('feature/*')
```

Meaning:

- Direct feature branch pushes are not built.
- Release branches are built.
- PR jobs build the PR merge result, not only the raw feature branch head.
- Fork PRs are not built.

Expected flow:

```text
feature/* push:
  Jenkins does not run

PR opened:
  homelab-app-ci/PR-1 runs

new commit pushed while PR is open:
  PR-1 runs again

PR merged into release/*:
  release/* branch job runs
```

GitHub may still show older branch checks on an existing PR if that branch was built before this filter was added:

```text
continuous-integration/jenkins/branch
continuous-integration/jenkins/pr-merge
```

The current target behavior is that new feature commits trigger only the PR check after a PR exists.

---

## 3. Current CI Stages

The app `Jenkinsfile` currently runs:

```text
Checkout
Linting
Unit Tests
Code Quality Analysis
Prepare Security Scanner
Static Security Scan
```

Linting runs in parallel:

```text
Python linting   -> user-service, todo-service
Frontend linting -> frontend
Hadolint         -> service Dockerfiles
```

Unit tests run for:

```text
user-service
todo-service
```

Static security scans currently use Trivy for:

```text
filesystem/dependency vulnerabilities
secret scanning
```

IaC scanning is not needed in the app repository right now because Kubernetes manifests live in a separate infrastructure/config repository.

---

## 4. Python Unit Test Cache

We are not using the old `Dockerfile.test` approach for unit tests.

Current approach:

```text
persistent pip cache + fresh workspace venv per build
```

The Jenkins Kubernetes agent mounts a PVC-backed pip cache:

```text
/cache/pip
```

For every build and service:

```text
1. Create a fresh venv under the workspace.
2. Run pip install with --cache-dir /cache/pip.
3. Run pytest.
4. Generate JUnit XML and coverage XML.
5. Delete workspace at the end of the build.
```

Why this design:

- Fresh venv avoids stale installed packages between builds.
- Persistent pip cache avoids downloading the same wheels every time.
- Requirements changes are handled naturally by `pip install`.
- The cache contains downloaded packages, not a shared executable environment.

Coverage reports:

```text
coverage-reports/user-service/coverage.xml
coverage-reports/todo-service/coverage.xml
```

Each service has its own `.coveragerc`. Coverage thresholds are configured per service in the `Jenkinsfile`.

---

## 5. SonarQube Policy

SonarQube analysis runs in the `Code Quality Analysis` stage.

Current source list:

```text
user-service
todo-service
frontend
```

Current coverage reports:

```text
coverage-reports/user-service/coverage.xml
coverage-reports/todo-service/coverage.xml
```

Issue fetch policy:

```text
release/* branch:
  project-level issues

everything else, mainly PR jobs:
  new-code issues
```

This keeps PR feedback focused on what changed, while release branch validation can look at the whole project before becoming a deploy candidate.

Quality Gate behavior:

- Jenkins waits for the SonarQube Quality Gate result.
- If the Quality Gate fails and `abortPipeline` is true, the build fails.
- If `abortPipeline` is false, the build is marked unstable.

---

## 6. Trivy Cache And Security Scan

Trivy DB is prepared before scans:

```text
Prepare Security Scanner -> ensureTrivyDB()
```

The shared library keeps a persistent Trivy cache on PVC. For actual scans, each scan uses an isolated temporary copy of the cache. This avoids file locking problems when multiple Trivy scans run in parallel.

Current dependency scan is strict:

```text
failOnVulnerabilities: true
```

Current secret scan is strict:

```text
failOnSecrets: true
```

---

## 7. Release Branch Role

Release branches carry the release version:

```text
release/3.40 -> v3.40
release/3.41 -> v3.41
```

Feature branches are merged into a release branch by PR:

```text
feature/my-change -> release/3.40
```

When the PR is opened or updated, Jenkins runs the PR pipeline. When the PR is merged, Jenkins runs the release branch pipeline. This matters because another PR may have been merged between PR creation and PR approval.

The release branch CI result is what the later staging deploy job should trust.

---

## 8. Manual Staging Deploy Pipeline

This should be a separate manual parameterized Pipeline job, not the Multibranch CI job.

Planned parameters:

```text
SERVICE = frontend / user-service / todo-service
ENV = staging
BRANCH = release/3.40
```

Rules:

- Derive version from `BRANCH`.
- Resolve the exact commit SHA from the branch.
- Check that this commit passed the release branch CI pipeline.
- Build only the selected service image.
- Push image to GHCR.
- Deploy/update only that service in staging.

Image tag format:

```text
<service>:<commit>-v<release-version>-staging
```

Example:

```text
todo-service:abc1234-v3.40-staging
```

This job should not repeat all CI checks if the selected commit already passed the release branch pipeline.

---

## 9. Manual Production Deploy Pipeline

Production should also be manual.

Rules:

- Do not rebuild the image.
- Promote the same artifact that was tested in staging.
- Retag or copy the staging image digest with a production tag.
- Deploy that exact image to production.
- Run a small smoke check after deploy.
- After production succeeds, merge the release branch back to `main`.

Image promotion example:

```text
todo-service:abc1234-v3.40-staging
todo-service:abc1234-v3.40-prod
```

The important rule:

```text
build once -> deploy staging -> approve -> promote same digest -> deploy production
```

---

## 10. Main Branch And Versioning

`main` represents what has already been released to production.

After production deploy succeeds:

```text
release/3.40 -> main
```

The repo contains multiple services, so service image tags carry service identity:

```text
frontend:abc1234-v3.40-staging
user-service:abc1234-v3.40-staging
todo-service:abc1234-v3.40-staging
```

Git tags are optional later. If needed, prefer service-scoped tags:

```text
frontend/v1.1.0
user-service/v1.2.0
todo-service/v1.6.0
```

For now, release branch name gives the release version and commit SHA gives traceability.

---

## 11. Later Work

- Add manual `homelab-app-release` pipeline.
- Add GHCR image build and push logic.
- Add config repo update or direct `kubectl apply` logic.
- Add staging e2e pipeline.
- Make production deploy depend on approved staging result.
- Promote production images by digest.
