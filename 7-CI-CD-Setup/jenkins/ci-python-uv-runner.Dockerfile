FROM ghcr.io/astral-sh/uv:0.12.1 AS uv

FROM python:3.11-slim

LABEL org.opencontainers.image.title="ci-python-test-runner"
LABEL org.opencontainers.image.description="Python CI runner for Jenkins linting and unit tests"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV UV_CACHE_DIR=/cache/uv
ENV UV_LINK_MODE=copy
ENV UV_PYTHON_DOWNLOADS=0

WORKDIR /workspace

COPY --from=uv /uv /uvx /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN uv pip install --system --no-cache ruff==0.16.0

RUN mkdir -p /cache/uv /workspace

CMD ["sleep", "infinity"]
