FROM debian:13-slim

ARG KUBECTL_VERSION=v1.36.1
ARG ARGOCD_VERSION=v3.4.2
ARG ARGO_ROLLOUTS_VERSION=v1.9.1
ARG TARGETARCH=amd64

LABEL org.opencontainers.image.title="kubernetes-tools"
LABEL org.opencontainers.image.description="Jenkins Kubernetes release tools: kubectl, argocd, and Argo Rollouts kubectl plugin"

ENV HOME=/home/jenkins

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    tar \
    gzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL -o /usr/local/bin/argocd \
      "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${TARGETARCH}"; \
    curl -fsSL -o /usr/local/bin/kubectl-argo-rollouts \
      "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/kubectl-argo-rollouts-linux-${TARGETARCH}"; \
    chmod 555 /usr/local/bin/kubectl /usr/local/bin/argocd /usr/local/bin/kubectl-argo-rollouts; \
    ln -s /usr/local/bin/kubectl-argo-rollouts /usr/local/bin/argo-rollouts; \
    ln -s /usr/local/bin/kubectl-argo-rollouts /usr/local/bin/rollouts; \
    mkdir -p /home/jenkins /workspace; \
    chown -R 1000:1000 /home/jenkins /workspace

USER 1000:1000
WORKDIR /workspace

CMD ["sleep", "infinity"]
