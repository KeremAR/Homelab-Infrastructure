# Observability Stack

> The declarative YAML files and [install.md](install.md) are the current
> installation method.

Complete observability stack for Kubernetes covering four telemetry signals:
**Metrics**, **Logs**, **Traces**, and **Profiles**.

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
│  │  │  └─> OTLP/HTTP → Elasticsearch                         │  │  │
│  │  │                                                        │  │  │
│  │  │  Traces Collection:                                    │  │  │
│  │  │  • OTLP Receiver (gRPC :4317, HTTP :4318)              │  │  │
│  │  │  └─> Forward → Jaeger                                  │  │  │
│  │  │                                                        │  │  │
│  │  │  Profiles Collection:                                  │  │  │
│  │  │  • Pyroscope HTTP Receiver (:4040)                     │  │  │
│  │  │  └─> Forward → Pyroscope                               │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─────────────┐ ┌─────────────┐ ┌──────────┐ ┌───────────┐        │
│  │ Prometheus  │ │Elasticsearch│ │  Jaeger  │ │ Pyroscope │        │
│  │  (Metrics)  │ │   (Logs)    │ │ (Traces) │ │(Profiles) │        │
│  └─────────────┘ └─────────────┘ └──────────┘ └───────────┘        │
│         ↓                  ↓                  ↓                    │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ Grafana (metrics/profiles) + Kibana (logs) + Jaeger (traces) │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

## 🗂️ Installation and configuration

Use [install.md](install.md) for the complete installation order. Component
configuration is stored as declarative YAML under `metrics/`, `logs/`,
`traces/`, `profiling/`, and `dashboards/`.

Alloy configuration is separated by signal:

- `metrics/alloy-metrics-config.yaml`
- `logs/alloy-logs-config.yaml`
- `traces/alloy-traces-config.yaml`
- `profiling/alloy-profiles-config.yaml`

Dashboard descriptions are maintained separately in
[README-Dashboards.md](README-Dashboards.md).

---

## 🔍 Component Details

### 1. Prometheus (Metrics Database)

**Configuration Highlights:**
- **Remote Write Receiver**: Enabled to accept metrics from Alloy agents
- **Exemplar Storage**: Enabled so metric samples can retain trace IDs
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
    enable-feature: exemplar-storage       # Keep trace exemplars
```

### 2. Elasticsearch and Kibana (Logs)

**Configuration Highlights:**
- **ECK-managed**: The operator manages Elasticsearch, Kibana, TLS, and updates
- **Persistent Storage**: An ECK-managed 2 Gi Longhorn PVC stores Elasticsearch data
- **OTLP Ingestion**: Alloy sends logs to Elasticsearch over OTLP/HTTP
- **Field Exploration**: Kibana Discover provides field-based filtering
- **Homelab Topology**: One Elasticsearch node; persistent but not HA

### 3. Grafana Alloy (Unified Agent)

**Deployment Type:** DaemonSet (one pod per node)

**Why DaemonSet?**
- **Metrics**: Access to node's `/proc`, `/sys`, `/root` filesystems
- **Logs**: Access to node's `/var/log/pods` directory
- **Traces and profiles**: Distributed receivers across nodes for resilience

**Host Mounts:**
```yaml
volumes:
  - /proc → /host/proc        # Node system metrics
  - /sys → /host/sys          # Node system metrics
  - / → /host/root            # Filesystem metrics
  - /var/log → /var/log       # Pod logs
```

**Alloy Configuration Components:**

#### Collection Models at a Glance

The four signals reach Alloy in different ways:

```text
Metrics  → The application exposes /metrics; Alloy periodically pulls it.
Logs     → The container runtime writes log files; Alloy tails and sends them to Elasticsearch.
Traces   → Application instrumentation creates spans and pushes them to Alloy over OTLP.
Profiles → The Pyroscope SDK samples running code and pushes profiles to Alloy over HTTP.
```

Alloy collects and forwards telemetry, but it cannot invent application-level
metrics or traces that the application has never produced.
The same is true for code-level profiles: Alloy receives and forwards them,
while the language SDK performs the actual in-process sampling.

#### Metrics Collection (12 Sources)

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
   - Target: the dynamically discovered pod IP and its annotated port `8080`
   - Metrics prefix: `kube_*`
   - No dedicated Alloy `prometheus.scrape "kube_state_metrics"` component is
     needed because the generic Pod Discovery pipeline already includes it

5. **Argo Rollouts** (Static target)
   - Endpoint: `argo-rollouts-metrics.argo-rollouts.svc.cluster.local:8090`
   - Metrics prefix: `argo_rollouts_*`

6. **CoreDNS** (EndpointSlice discovery)
   - Discovered from the annotated `kube-dns` Service
   - Scrapes every ready backend on the Service port named `metrics`
   - Endpoint: `<coredns-pod-ip>:9153/metrics`

7. **kube-apiserver**
   - Endpoint: `https://kubernetes.default.svc:443/metrics`
   - Uses the Alloy ServiceAccount token and verifies the cluster CA

8. **kube-proxy**
   - Optional and disabled in the Alloy config by default
   - Used only by the classic networking option
   - Scrapes every node on `<node-internal-ip>:10249/metrics`
   - Not present when Cilium uses `kubeProxyReplacement: true`

9. **kube-scheduler**
   - Scrapes each control-plane node on HTTPS port `10259`

10. **kube-controller-manager**
    - Scrapes each control-plane node on HTTPS port `10257`

11. **etcd**
    - Scrapes each control-plane node on HTTP port `2381`

12. **Blackbox Exporter** (In-cluster service probing)
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
6. **Convert and write**: Convert the processed entries to OTLP and send them
   to Elasticsearch over HTTPS

**Log File Path Pattern:**
```
/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log
```

**Resulting Elasticsearch log attributes:**
- `namespace`: Kubernetes namespace
- `pod`: Pod name
- `container`: Container name
- `cluster`: Kubernetes cluster name (`homelab`)
- `service_name`: Application service name when the pod label is present
- `stream`: stdout or stderr
- `job`: namespace/pod

These Kubernetes fields are filterable in Kibana Discover. Fields that exist
inside application JSON are parsed by Alloy and retained as structured fields.
Plain-text logs from other containers are preserved without being discarded.

#### Application JSON Logs And Correlation

**Log source and path:**

| Item | Value |
|---|---|
| Producers | `user-service`, `todo-service` |
| Application output | One JSON object per stdout line |
| Container envelope | CRI or Docker format; removed by Alloy before JSON parsing |
| Collector | Grafana Alloy DaemonSet |
| Destination | Elasticsearch over OTLP/HTTP |
| UI | Kibana Discover |

**Collection flow:**

```text
FastAPI application
    ↓ JsonLogFormatter
JSON record on stdout
    ↓ container runtime envelope
Alloy: CRI/Docker parse → native OTel LogRecord + Resource mapping
    ↓ OTLP/HTTP
Elasticsearch
    ↓
Kibana Discover
```

**JSON record fields:**

- **Formatter source:** `user-service/logging_config.py` and
  `todo-service/logging_config.py`
- **Optional fields:** Fields that are not relevant to an event are omitted or
  set to `null`.

| Field | Meaning | Example |
|---|---|---|
| `timestamp` | UTC event time | `2026-08-29T14:37:27.412Z` |
| `severity` | Log level | `INFO`, `ERROR` |
| `logger` | Python logger name | `app` |
| `message` | Human-readable message after redaction | `HTTP request completed` |
| `service_name` | Application service | `user-service` |
| `service_namespace` | Logical service namespace | `homelab-app` |
| `service_version` | Image or runtime version | `dev`, `1f1170f-v1.0-staging` |
| `deployment_environment` | Deployment environment | `development`, `staging` |
| `event_name` | Stable audit/request event name | `auth.login_failed` |
| `outcome` | Event result | `success`, `failure` |
| `http_method` | HTTP method | `GET`, `POST` |
| `http_route` | FastAPI route template | `/api/v1/todos` |
| `http_status_code` | HTTP response status | `200`, `401` |
| `duration_ms` | Server-side request duration | `34.07` |
| `actor_id` | Authenticated user ID, when applicable | `7` |
| `resource_type` / `resource_id` | Affected resource identity | `todo` / `42` |
| `changed_fields` | Fields changed by an update | `["completed"]` |
| `trace_id` / `span_id` | OpenTelemetry correlation IDs | `99b077...` |
| `trace_sampled` | Whether the trace was sampled | `true` |
| `exception_*` | Exception type, message, and stack trace | `ValueError` |

**Application logging rules:**

- `JsonLogFormatter` adds service identity, environment, request context, and
  trace correlation to every application record.
- The request middleware emits completion events with route, status, and
  duration fields.
- Authentication, todo mutations, administrative actions, and runtime config
  reloads use stable `event_name` values.
- Request bodies, JWTs, passwords, token values, email addresses, and todo
  content are redacted or intentionally excluded.

**Alloy field mapping:**

Alloy uses Loki components only to discover pod log files and remove the
CRI/Docker envelope. It does not send these records to a Loki server. The
Elasticsearch path parses the application JSON, maps correlation and severity
to native OTel LogRecord fields, and promotes stable service and Kubernetes
identity to OTel Resources. Request and audit details remain searchable
LogRecord attributes rather than indexed Loki labels.

Names such as `TraceId` and `SeverityText` below are the logical field names in
the OpenTelemetry data model, not the literal JSON keys used by every backend.
Alloy OTTL and Elasticsearch represent these native fields with snake_case
keys. Native here means that the values are typed top-level LogRecord fields,
not ordinary entries under `attributes` or text embedded in the log body.

| Application JSON | Native OTel field | Elasticsearch `_source` / query field |
|---|---|---|
| `trace_id` | `TraceId` | `trace_id` / `trace.id` |
| `span_id` | `SpanId` | `span_id` / `span.id` |
| `trace_sampled` | `TraceFlags` | Set as Alloy's native `flags`; the current Elasticsearch OTel log mapping does not expose it in `_source` |
| `severity` | `SeverityText`, `SeverityNumber` | `severity_text`, `severity_number` / `log.level`, `event.severity` |
| `event_name` | `EventName` | `event_name` |

| Mapping | Fields |
|---|---|
| OTel Resource attributes | `service.name`, `service.namespace`, `service.version`, `deployment.environment.name`, `k8s.cluster.name`, `k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name` |
| OTel LogRecord attributes | `logger`, `event.outcome`, `http.request.method`, `http.route`, `http.response.status_code`, `actor_id`, `resource_type`, `resource_id`, `duration_ms`, `changed_fields`, `exception.type`, `exception.message`, `exception.stacktrace`, plus log file/stream metadata |
| Log body / Kibana message | The application `message` value; the raw JSON object is not kept as the displayed message |

`otelcol.processor.groupbyattrs` performs the Resource promotion after the JSON
transform. This is important because a collector batch can contain records from
different pods; grouping prevents one record's service identity from being
written onto another record's Resource.

**Cardinality rule:** Trace IDs, actor IDs, request paths, and exception text
remain available for investigation without becoming Loki labels. Adding a new
application JSON field also requires an explicit Alloy mapping; this allow-list
prevents accidental field and mapping growth in Elasticsearch.

**Kibana Discover examples:**

```text
service.name: "user-service" AND event_name: "auth.login_failed"
service.name: "todo-service" AND event_name: "todo.updated"
attributes.actor_id: 7 AND event_name: "todo.deleted"
trace.id: "<trace-id>"
```

#### Traces Collection (OTLP Receiver)

A trace follows a request through timed operations called spans, such as HTTP
handlers and database calls. These internal spans cannot be obtained by
scraping the application like Prometheus metrics. OpenTelemetry instrumentation
creates them, the application pushes them to Alloy, and Alloy forwards them to
Jaeger. Zero-code agents and eBPF tools can also produce traces, but generally
provide less application-level detail than explicit instrumentation.

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
opentelemetry-instrumentation-psycopg==0.49b2

# app.py
import os
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.psycopg import PsycopgInstrumentor

# Configure SDK (reads OTEL_* env vars automatically)
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "user-service"),
})
trace.set_tracer_provider(TracerProvider(resource=resource))
otlp_exporter = OTLPSpanExporter()  # Uses OTEL_EXPORTER_OTLP_ENDPOINT
span_processor = BatchSpanProcessor(otlp_exporter)
trace.get_tracer_provider().add_span_processor(span_processor)

# Instrument libraries BEFORE app initialization
PsycopgInstrumentor().instrument()

app = FastAPI()
FastAPIInstrumentor.instrument_app(
    app,
    excluded_urls=r"/health$,/ready$,/metrics$",
)
```

**Critical Configuration Notes:**
1. **SDK Setup Required**: Auto-instrumentation alone won't export traces without TracerProvider + Exporter
2. **Instrumentation Order**: Call `PsycopgInstrumentor().instrument()` BEFORE creating database connections
3. **Environment Variables**: OpenTelemetry SDK reads `OTEL_*` variables automatically (no code changes needed)
4. **OTLP Endpoint**: Set `OTEL_EXPORTER_OTLP_ENDPOINT` to the receiver base URL, such as `http://alloy.observability.svc.cluster.local:4318`. With HTTP/protobuf, `OTLPSpanExporter()` resolves this as `...:4318/v1/traces`. A signal-specific `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is used exactly as provided, so that value must already include `/v1/traces`.
5. **Probe Noise**: Exclude successful health, readiness, and metrics traffic from application traces and metrics; failed probe responses remain visible in logs and application metrics.

### Prometheus Metrics (Python)

To expose detailed **Backend Application Latency** (processing time within FastAPI, excluding network/proxy overhead) with custom buckets:

```python
from prometheus_client import Counter, Histogram
from prometheus_client.openmetrics.exposition import generate_latest

request_count = Counter(
    "http_requests_total",
    "Total number of HTTP requests",
    ("method", "status", "handler"),
)
request_duration = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration",
    ("method", "status", "handler"),
    buckets=[0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0],
)

# On a sampled request, observe(..., exemplar={"trace_id": ...}).
# /metrics returns generate_latest(REGISTRY) with the OpenMetrics content type.
```

The application middleware observes each non-probe request while the active
FastAPI OpenTelemetry span is available. It increments the request counter and
records latency. For sampled spans, the histogram observation carries the
32-character `trace_id` as an exemplar. The Python process keeps these values
in memory and exposes them through `/metrics`; `/metrics` is not a hidden page
and should normally remain reachable only from the intended monitoring network.

The complete application-metrics flow is:

```text
Python service custom Prometheus instrumentation
    ↓ records counters and exemplar-capable request durations in process memory
Pod IP:<annotated-port>/metrics
    ↓ Alloy discovers the annotated pod and performs an OpenMetrics HTTP GET
Grafana Alloy
    ↓ Prometheus remote_write, including exemplars
Prometheus
```

The port in `prometheus.io/port` must match the port on which the application
exposes `/metrics`; `8080` in this document is an example rather than a fixed
requirement.

#### Trace Exemplars

The Python services use a custom `prometheus_client` histogram and expose
`/metrics` using the official OpenMetrics exposition API. A sampled active
OpenTelemetry span contributes its 32-character `trace_id` as an exemplar to a
latency bucket; it is not a regular metric label. `/health`, `/ready`, and
`/metrics` requests are excluded from application request metrics, so successful
probes do not inflate the request counter or latency histogram.

Prometheus must run with `exemplar-storage` enabled. Grafana needs a Jaeger
datasource and a Prometheus datasource mapping from exemplar field `trace_id`
to the Jaeger datasource UID. The local Dev Container stack exercises this
application-to-Prometheus-to-Grafana/Jaeger path directly.

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

The generic Kubernetes Pod Discovery pipeline watches pod metadata through the
Kubernetes API and keeps targets whose `prometheus.io/scrape` annotation is
`true`. The kube-state-metrics pod has this annotation, so it enters the same
pipeline as annotated application pods. Alloy therefore scrapes its discovered
pod IP on port `8080`; a separate kube-state-metrics-specific scrape component
is unnecessary.

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
from opentelemetry.instrumentation.psycopg import PsycopgInstrumentor

PsycopgInstrumentor().instrument()  # Before app init
FastAPIInstrumentor.instrument_app(
    app,
    excluded_urls=r"/health$,/ready$,/metrics$",
)
```

### 6. Pyroscope (Continuous Profiling)

The Python SDK samples the backend processes and sends CPU profiles to Alloy's
Pyroscope-compatible HTTP receiver on port `4040`. Alloy forwards them to the
single-binary Pyroscope backend, which stores them on a 2 Gi Longhorn PVC.
Grafana reads that backend through the provisioned `Pyroscope` datasource.

```text
Python service (Pyroscope SDK) → Alloy :4040 → Pyroscope → Grafana Explore
```

The profiling SDK is enabled only when `PYROSCOPE_SERVER_ADDRESS` is present.
See [`profiling/README.md`](profiling/README.md) for installation, verification,
and the current Jaeger correlation limitation.

### 7. Blackbox Exporter (In-Cluster Service Monitoring)

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
