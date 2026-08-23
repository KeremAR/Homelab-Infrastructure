# CI/CD setup

This directory installs the services used by the release pipeline. SonarQube
performs code-quality and coverage analysis, Dependency-Track stores SBOMs and
tracks component vulnerabilities, and Jenkins orchestrates the complete CI/CD
workflow using ephemeral Kubernetes agents.

## Prerequisites

Before starting, the cluster should have:

- Longhorn and `longhorn-storageclass` for persistent service data.
- MetalLB and the shared Envoy Gateway for the web interfaces.
- Working `kubectl` and Helm clients pointed at the target cluster.
- Access to the application, Shared Library, infrastructure and GHCR
  repositories required by Jenkins.

## Installation order

1. Install [SonarQube](./sonarqube/sonarqube.md), create its Jenkins token and
   configure the webhook described in that guide.
2. Install [Dependency-Track](./dependency-track/dependency-track.md), then
   create the API key Jenkins uses to upload generated SBOMs.
3. Install Jenkins last by following
   [4B-Jenkins-Install.md](./jenkins/4B-Jenkins-Install.md). At this point the
   SonarQube token and Dependency-Track API key are available when
   `jenkins-secrets.yaml` is rendered.

SonarQube and Dependency-Track do not depend on Jenkins to start, so their
order relative to each other is not important. Both must be ready before the
current Jenkins configuration and pipeline integrations are considered
complete.

## Components

### SonarQube

SonarQube receives scanner results from Jenkins and retains source-code issues,
coverage and Quality Gate results. It uses its own PostgreSQL release and
Longhorn-backed PVCs.

### Dependency-Track

Dependency-Track receives CycloneDX SBOMs generated during the pipeline and
correlates their components with vulnerability data. It also uses a separate
PostgreSQL release and persistent storage.

### Jenkins

Jenkins is the pipeline controller. Its configuration is managed with JCasC;
build stages run in temporary Kubernetes agent Pods rather than on the
controller. Read [4A-Jenkins.md](./jenkins/4A-Jenkins.md) for the runtime
architecture, then use the installation runbook linked above.

The resulting flow is:

```text
Git repository
  -> Jenkins pipeline and ephemeral agents
  -> tests, SonarQube analysis, image and SBOM scans
  -> image published to GHCR
  -> deployment configuration updated for the target environment
```
