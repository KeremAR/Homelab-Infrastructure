FROM python:3.11-slim

LABEL org.opencontainers.image.title="ci-python-test-runner"
LABEL org.opencontainers.image.description="Python CI runner for Jenkins linting and unit tests"

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /workspace

# Build tools are kept in the image so service dependencies can be installed
# quickly using the PVC-backed pip cache during Jenkins runs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    git \
    jq \
    libffi-dev \
    libpq-dev \
    openssh-client \
    pkg-config \
    python3-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip setuptools wheel \
    && python -m pip install \
      black==25.9.0 \
      flake8==7.3.0 \
      pytest==8.3.4 \
      pytest-asyncio==0.24.0 \
      pytest-cov==6.0.0 \
      ruff==0.9.3

RUN mkdir -p /cache/pip /workspace

CMD ["sleep", "infinity"]
