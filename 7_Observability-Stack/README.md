# Observability Stack

> The declarative YAML files and [install.md](install.md) are the current
> installation method.

Complete observability stack for Kubernetes implementing the three pillars of
observability: **Metrics**, **Logs**, and **Traces**.

## 📊 Architecture Overview

The observability stack is built around **Grafana Alloy** as a unified collection agent, replacing traditional separate tools (Prometheus Node Exporter, Promtail, etc.) with a single DaemonSet that collects all telemetry data.

### Data Flow

```
┌────────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                                │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Grafana Alloy (DaemonSet - one pod per node)                │  │
│  │  ┌────────────────────────────────────────────────────────┐  │  │
│  │  │  Metrics Collection:                                   │  │  │
│  │  │  • Unix Exporter (node metrics)                        │  │  │
│  │  │  • Kubelet cAdvisor (container metrics)                │  │  │
│  │  │  • Pod Discovery (app metrics via annotations)         │  │  │
│  │  │  • kube-state-metrics (K8s object state)               │  │  │
│  │  │  • Argo Rollouts metrics                               │  │  │
│  │  │  └─> Remote Write → Prometheus                         │  │  │
│  │  │                                                        │  │  │
│  │  │  Logs Collection:                                      │  │  │
│  │  │  • Tail /var/log/pods (all pod logs)                   │  │  │
│  │  │  • Parse CRI/Docker formats                            │  │  │
│  │  │  └─> Push → Loki                                       │  │  │
│  │  │                                                        │  │  │
│  │  │  Traces Collection:                                    │  │  │
│  │  │  • OTLP Receiver (gRPC :4317, HTTP :4318)              │  │  │
│  │  │  └─> Forward → Jaeger                                  │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐               │
│  │ Prometheus  │   │    Loki     │   │   Jaeger    │               │
│  │  (Metrics)  │   │   (Logs)    │   │  (Traces)   │               │
│  └─────────────┘   └─────────────┘   └─────────────┘               │
│         ↓                  ↓                  ↓                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    Grafana (Visualization)                   │  │
│  │  • Dashboards  • Explore  • Alerting  • Correlation          │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

## 🗂️ Installation and configuration

Use [install.md](install.md) for the complete installation order. Component
configuration is stored as declarative YAML under `metrics/`, `logs/`,
`traces/`, and `dashboards/`.

Alloy configuration is separated by signal:

- `metrics/alloy-metrics-config.yaml`
- `logs/alloy-logs-config.yaml`
- `traces/alloy-traces-config.yaml`

Dashboard descriptions are maintained separately in
[README-Dashboards.md](README-Dashboards.md).

---

## 🔍 Component Details

### 1. Prometheus (Metrics Database)

**Configuration Highlights:**
- **Remote Write Receiver**: Enabled to accept metrics from Alloy agents
- **Persistent Storage**: Explicitly created 2 Gi Longhorn PVC
- **Minimal Scraping**: Only self-monitors (Alloy handles all collection)

**Why Remote Write?**
- Decoupled collection: Alloy scrapes, Prometheus stores
- Better scalability: Multiple agents, single database
- Unified agent: Same DaemonSet for metrics, logs, traces

**Key Configuration:**
```yaml
server:
  extraArgs:
    web.enable-remote-write-receiver: ""  # CRITICAL for Alloy
```

### 2. Loki (Logs Database)

**Configuration Highlights:**
- **SingleBinary Mode**: All components in one pod (simple deployment)
- **Filesystem Storage**: Filesystem backend on a persistent Longhorn volume
  (no S3/object store needed)
- **Schema v13**: Latest stable with TSDB index

**Critical Configuration Fix:**
```yaml
loki:
  storage:
    filesystem:
      chunks_directory: /var/loki/chunks  # Note the 's' - common mistake!
  schemaConfig:
    configs:
      - object_store: filesystem  # MUST match storage.type
```

**Common Error Prevented:**
- ❌ `bucketNames required` error → Fixed by matching object_store type
- ❌ `unknown field chunk_directory` → Fixed by using `chunks_directory`

### 3. Grafana Alloy (Unified Agent)

**Deployment Type:** DaemonSet (one pod per node)

**Why DaemonSet?**
- **Metrics**: Access to node's `/proc`, `/sys`, `/root` filesystems
- **Logs**: Access to node's `/var/log/pods` directory
- **Traces**: Distributed receivers across nodes for resilience

**Host Mounts:**
```yaml
volumes:
  - /proc → /host/proc        # Node system metrics
  - /sys → /host/sys          # Node system metrics
  - / → /host/root            # Filesystem metrics
  - /var/log → /var/log       # Pod logs
```

**Alloy Configuration Components:**

#### Metrics Collection (6 Sources)

1. **Unix Exporter** (Node-level)
   - Replaces `node_exporter`
   - Collects: CPU, memory, disk, network
   - Metrics prefix: `node_*`

2. **Kubelet cAdvisor** (Container-level)
   - Endpoint: `https://<node>:10250/metrics/cadvisor`
   - Collects: Container CPU, memory, network, filesystem
   - Metrics prefix: `container_*`

3. **Pod Discovery** (Application-level)
   - Discovers pods with `prometheus.io/scrape: "true"` annotation
   - Collects: Application-specific metrics
   - Dynamic discovery via Kubernetes API

4. **kube-state-metrics** (Cluster state)
   - Discovered via pod annotations (`prometheus.io/scrape: "true"`)
   - Endpoint: `kube-state-metrics.observability.svc.cluster.local:8080`
   - Metrics prefix: `kube_*`

5. **Argo Rollouts** (Static target)
   - Endpoint: `argo-rollouts-metrics.argo-rollouts.svc.cluster.local:8090`
   - Metrics prefix: `argo_rollouts_*`

6. **Blackbox Exporter** (In-cluster service probing)
   - Discovers services with `blackbox.prometheus.io/scrape: "true"` annotation
   - Probes application Services from the Blackbox Exporter pod inside the cluster
   - Measures in-cluster network and application response latency
   - Metrics: `probe_duration_seconds`, `probe_success`, `probe_http_status_code`

**All metrics → Remote Write → Prometheus**

**Application Metrics - Required Helm Chart Configuration:**

To enable Alloy to discover and scrape your application metrics, add these annotations to your Pod/Deployment template:

```yaml
# Helm values.yaml or deployment manifest
template:
  metadata:
    annotations:
      prometheus.io/scrape: "true"     # REQUIRED: Enable metric scraping
      prometheus.io/port: "8080"       # Optional: Custom metrics port (default: container port)
      prometheus.io/path: "/metrics"   # Optional: Custom path (default: /metrics)
```

#### Logs Collection (6-Step Pipeline)

1. **Discovery**: Find all pods via Kubernetes API
2. **Relabel**: Extract namespace, pod, container labels + build log file path
3. **File Match**: Resolve wildcards (`/var/log/pods/*/container/*.log`)
4. **File Tail**: Read log files in real-time
5. **Parse**: Extract timestamp, stream (stdout/stderr), message
   - Containerd: CRI format parser
   - Docker: JSON format parser
6. **Write**: Push to Loki with labels

**Log File Path Pattern:**
```
/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log
```

**Resulting Loki Labels:**
- `namespace`: Kubernetes namespace
- `pod`: Pod name
- `container`: Container name
- `stream`: stdout or stderr
- `job`: namespace/pod

#### Traces Collection (OTLP Receiver)

- **gRPC Endpoint**: `:4317`
- **HTTP Endpoint**: `:4318`
- **Protocol**: OpenTelemetry Protocol (OTLP)
- **Forwarding**: `jaeger.observability.svc.cluster.local:4317`

**Application Configuration - Required Helm Chart Settings:**

To send traces from your application to Alloy → Jaeger, add these environment variables to your container:

```yaml
# Helm values.yaml
env:
  # REQUIRED: Alloy OTLP endpoint
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://alloy.observability.svc.cluster.local:4318"
  
  # REQUIRED: Protocol (http/protobuf recommended for performance)
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: "http/protobuf"
  
  # REQUIRED: Service name (appears in Jaeger)
  - name: OTEL_SERVICE_NAME
    value: "user-service"
  
  # Optional: Resource attributes (version, environment, etc.)
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.namespace=staging,service.version={{ .Values.image.tag }},deployment.environment=staging"
  
  # Optional: Exporter type (default: otlp)
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
```
**Application Code - Python Example:**

```python
# requirements.txt
opentelemetry-api==1.28.2
opentelemetry-sdk==1.28.2
opentelemetry-exporter-otlp==1.28.2
opentelemetry-instrumentation-fastapi==0.49b2
opentelemetry-instrumentation-psycopg2==0.49b2

# app.py
import os
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

# Configure SDK (reads OTEL_* env vars automatically)
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "user-service"),
})
trace.set_tracer_provider(TracerProvider(resource=resource))
otlp_exporter = OTLPSpanExporter()  # Uses OTEL_EXPORTER_OTLP_ENDPOINT
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# Instrument libraries BEFORE app initialization
Psycopg2Instrumentor().instrument()

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)
```

**Critical Configuration Notes:**
1. **SDK Setup Required**: Auto-instrumentation alone won't export traces without TracerProvider + Exporter
2. **Instrumentation Order**: Call `Psycopg2Instrumentor().instrument()` BEFORE creating database connections
3. **Environment Variables**: OpenTelemetry SDK reads `OTEL_*` variables automatically (no code changes needed)

### Prometheus Metrics (Python)

To expose detailed **Backend Application Latency** (processing time within FastAPI, excluding network/proxy overhead) with custom buckets:

```python
from prometheus_fastapi_instrumentator import Instrumentator, metrics

# CRITICAL: .add() OVERRIDES default metrics!
# Must explicitly add both requests() and latency() when using custom buckets
Instrumentator().add(
    metrics.requests()  # Request counter (http_requests_total)
).add(
    metrics.latency(        buckets=[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]
)  # Latency histogram with custom buckets
).instrument(app).expose(app)

#  ALTERNATIVE: Use defaults (no custom buckets)
Instrumentator().instrument(app).expose(app)
# Result: All default metrics with default buckets
```

**Why Custom Buckets?**
Prometheus Histograms count requests in specific "buckets" (e.g., "requests faster than 0.1s").
- **Default Buckets**: Often too wide, making it impossible to distinguish between fast (0.2s) and slow (4.9s) requests.
- **Custom Buckets**: Essential for accurate **Quantiles** (p95, p99).
  - **p95 (95th Percentile)**: "95% of requests are faster than X".
  - To accurately measure if p95 is < 250ms, you **must** have a bucket boundary near 0.25s. Without it, Prometheus interpolates (guesses) the value, leading to inaccurate graphs.

### 4. kube-state-metrics

**Purpose:** Kubernetes API object metrics (not container runtime metrics)

**Metrics Examples:**
- `kube_pod_info`: Pod metadata
- `kube_deployment_status_replicas`: Deployment replica counts
- `kube_node_status_condition`: Node health status

**Discovery Method:** Annotation-based
```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
```

**Difference from Kubelet Metrics:**
- **Kubelet**: Container resource usage (CPU, memory)
- **kube-state-metrics**: Kubernetes desired vs actual state

### 5. Jaeger (Distributed Tracing)

**Deployment:** All-in-one mode

**Features:**
- OTLP collector (receives from Alloy)
- In-memory storage (development setup)
- Query service + UI

**Trace Flow:**
```
Python App (OTel SDK) → Alloy (OTLP) → Jaeger Collector → Jaeger UI
```

**Application Instrumentation:**
```python
# Library instrumentation (automatic spans)
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

Psycopg2Instrumentor().instrument()  # Before app init
FastAPIInstrumentor.instrument_app(app)
```

### 6. Blackbox Exporter (In-Cluster Service Monitoring)

**Deployment:** Single pod in observability namespace

**Purpose:** Probe application Services from a separate pod to measure
in-cluster network and application response latency.

**Why Blackbox Exporter?**
- ✅ **Network Chaos Validation**: Detects network latency/packet loss during chaos engineering
- ✅ **Independent Service Check**: Measures the path from the Blackbox
  Exporter pod to the target ClusterIP Service
- ✅ **SLA Monitoring**: Tracks service uptime and availability
- ✅ **Complementary to App Metrics**: Application metrics only measure internal processing time

**Probe Flow:**
```
Blackbox Exporter → HTTP Request → Service (http://service.namespace:port/path)
                  ↓
        Measures: In-cluster network + Processing + Transfer
                  ↓
            Prometheus Metrics
```

**Service Discovery:**
- Alloy auto-discovers services with `blackbox.prometheus.io/scrape: "true"` annotation
- Scrapes Blackbox Exporter's `/probe` endpoint (not `/metrics`)
- **Clustering enabled** to prevent duplicate probes across Alloy instances

**Service Annotation Example:**
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    blackbox.prometheus.io/scrape: "true"      # Enable blackbox probing
    blackbox.prometheus.io/path: "/ready"      # Health endpoint (default: /ready)
    blackbox.prometheus.io/port: "8002"        # Port to probe (default: first service port)
    blackbox.prometheus.io/module: "http_2xx"  # Probe module (default: http_2xx)
```
**Network Chaos Example:**
```
Application Metric (internal):
  http_request_duration_seconds = 0.05s  ← Unchanged during network chaos

Blackbox Metric (independent in-cluster probe):
  probe_duration_seconds = 2.10s  ← Sees 2s network latency!
```
**Blackbox vs Application Metrics:**

| Metric | Measured From | Includes Network? | Use Case |
|--------|---------------|-------------------|----------|
| `http_request_duration_seconds` | Inside pod | ❌ No | Application performance |
| `probe_duration_seconds` | Blackbox Exporter pod | ✅ In-cluster network | Service reachability and in-cluster response latency |


**Amplification Effect:**
During network chaos, observed latency may be higher than injected latency due to multiple delayed network operations (TCP handshake, database connection, HTTP response).

---
