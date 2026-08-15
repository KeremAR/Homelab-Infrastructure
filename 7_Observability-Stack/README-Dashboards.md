
## 📊 Pre-Built Dashboards

Dashboard definitions are declarative ConfigMaps in the `dashboards/`
directory. Grafana's dashboard sidecar loads them automatically.

### Kubernetes Control Plane & Networking

**Manifest:** `dashboards/dashboard-kubernetes-components.yaml`

**Purpose:** Monitor the Kubernetes components collected directly by Alloy.
The dashboard discovers nodes and component instances dynamically and covers:

- Scrape health for API server, scheduler, controller-manager, etcd,
  kube-proxy, and CoreDNS
- API server request rate and p99 latency
- Scheduler pending pods, attempt results, and p99 latency
- Controller-manager workqueue depth
- etcd leader state, database size, WAL fsync latency, and failed proposals
- kube-proxy rule synchronization and pending changes
- CoreDNS response codes and request latency

---

### Dynamic Node Memory Analysis

**Manifest:** `dashboards/dashboard-memory-analysis.yaml`

**Purpose:** Compare memory utilization and the largest pod consumers across
all cluster nodes without hard-coding node names.

The dashboard obtains node names dynamically from `node_uname_info`. Its three
base panels repeat for every selected node:

1. **Memory Usage** — percentage of node memory currently in use.
2. **Top Memory-Consuming Pods** — the 20 largest pod consumers on that node.
3. **Top Five Pods Over Time** — memory history for the five largest pod consumers.

The node selector supports one node, multiple nodes, or all nodes. This means
new worker or control-plane nodes appear without editing the dashboard.

---


### Global SRE Overview - Cluster Health & Service Status

**Manifest:** `dashboards/dashboard-global-sre-overview.yaml`

**Purpose:** High-level cluster monitoring dashboard for SRE teams. Provides instant cluster health status and enables drill-down into individual services.

**Dashboard Structure (9 Panels):**

#### 🎯 Global KPIs (Top Row - 4 Panels)
Instant cluster-wide health metrics:

1. **Global Success Rate (%)** - Overall cluster health indicator
   - Red (< 95%): Critical issues across cluster
   - Yellow (95-99%): Some services degraded
   - Green (> 99%): Healthy cluster

2. **Global Traffic (RPS)** - Total request volume across all services
   - Shows cluster-wide traffic patterns

3. **Global Error Rate (5xx)** - Total server errors across cluster
   - Green (< 0.1 req/s): Healthy
   - Yellow (0.1-1 req/s): Warning
   - Red (> 1 req/s): Critical

4. **Global P95 Latency** - Worst-case performance across cluster
   - Identifies performance bottlenecks

#### 🔥 Error Analysis (Row 2 - 2 Panels)

5. **Top 5 Error Generators (5xx Rate)** - Which services produce most errors?
   - Table showing namespace, service, pod, and error rate
   - Sorted by error rate (highest first)
   - Color-coded thresholds

6. **Service Traffic Distribution (RPS)** - Traffic breakdown by service
   - Top 10 services by request volume
   - Time series showing traffic patterns

#### 🏥 Service Health Grid (Drill-Down Enabled)
**The core panel for service discovery and drill-down**

7. **Service Health Grid** - Comprehensive service health table
   - **Namespace** - Environment (staging, production)
   - **Service** - Service name (clickable for drill-down)
   - **Total RPS** - Total request rate
   - **Success RPS** - 2xx response rate
   - **Error RPS** - 5xx error rate (color-coded)
   - **P95 Latency (s)** - 95th percentile response time
   - **Success Rate** - Calculated success percentage

**Drill-Down Feature:**
- Click any service name → Navigate to Microservice Detail Dashboard
- URL parameters automatically passed: `?var-namespace=<namespace>&var-service=<service>`
- Enables quick deep-dive from cluster overview to service details

#### 📈 Trend Analysis (Bottom Row - 2 Panels)

8. **Global Success Rate Trend** - Historical success rate over time
   - Shows if cluster health is improving or degrading
   - Color-coded thresholds (red < 95%, yellow 95-99%, green > 99%)

9. **Global Error Rate Trend (5xx)** - Historical error rate over time
   - Identifies error rate spikes and patterns

**Key Features:**
- ✅ **Namespace Filtering**: Dropdown to filter by namespace (staging, production, or All)
- ✅ **Drill-Down Navigation**: One-click from service health grid to detailed service analysis
- ✅ **Color-Coded Health**: Visual indicators for quick health assessment
- ✅ **Top-Down View**: Start here, drill down to service details when needed

**Usage Pattern:**
```
1. Open Global SRE Overview Dashboard
   └─ Check Global KPIs → Is cluster healthy?
   
2. High error rate detected?
   └─ Check Top 5 Error Generators → Which service?
   └─ Check Service Health Grid → Find the problematic service
   
3. Click service name in Service Health Grid
   └─ Drill down to Microservice Detail Dashboard
   └─ Analyze RED metrics, logs, and traces
```

---

### Infrastructure & Cluster - Node & Pod Resource Analysis

**Manifest:** `dashboards/dashboard-infrastructure-cluster.yaml`

**Purpose:** Infrastructure-level monitoring for identifying resource bottlenecks, noisy neighbors, and cluster capacity issues.

**Dashboard Structure (12 Panels):**

#### 🖥️ Cluster-Wide Saturation (Top Row - 4 Panels)
Overall resource utilization across the cluster:

1. **Cluster CPU Saturation (%)** - Average CPU usage across all nodes
   - Green (< 70%): Healthy
   - Yellow (70-85%): High usage
   - Red (> 85%): Critical saturation

2. **Cluster Memory Saturation (%)** - Average memory usage across all nodes
   - Green (< 75%): Healthy
   - Yellow (75-90%): High usage
   - Red (> 90%): Critical saturation

3. **Cluster Disk Usage (%)** - Disk space utilization
   - Green (< 80%): Healthy
   - Yellow (80-90%): High usage
   - Red (> 90%): Critical - action required

4. **Network Traffic (In/Out)** - Cluster-wide network throughput (MB/s)
   - Shows receive and transmit rates

#### 🔍 Node Detail Section (Variable: $node)
**Filterable by node** - Select specific node or "All" from dropdown

5. **Node CPU Usage (%)** - Per-node CPU utilization over time
   - Filtered by `$node` variable
   - Shows which node is CPU-saturated

6. **Node Memory Usage (%)** - Per-node memory utilization over time
   - Filtered by `$node` variable
   - Identifies memory pressure per node

7. **Node Disk I/O (Read/Write MB/s)** - Disk throughput per node
   - Filtered by `$node` variable
   - Detects disk bottlenecks

8. **Node Network Traffic (MB/s)** - Network throughput per node
   - Filtered by `$node` variable
   - Shows receive/transmit rates per node

#### 🏆 Noisy Neighbor Analysis (Middle Section - 2 Tables)

9. **Top 15 Memory Consumers** - Which pods use most RAM?
   - Node, Namespace, Pod, Memory (MB)
   - Sorted by memory usage (highest first)
   - Color-coded: 100MB+ (orange), 500MB+ (red)

10. **Top 15 CPU Consumers** - Which pods use most CPU?
    - Node, Namespace, Pod, CPU (cores)
    - Sorted by CPU usage (highest first)
    - Color-coded: 0.5+ cores (orange), 1+ cores (red)

#### ⚠️ Problematic Pod Events (Bottom Section - 2 Panels)

11. **Problematic Pod Events Table** - Critical pod status issues
    - 🔴 **OOMKilled** → Memory limit exceeded
    - 🟠 **CrashLoopBackOff** → Application repeatedly crashing
    - 🟡 **ImagePullBackOff/ErrImagePull** → Image not found
    - 🟣 **Evicted** → Node resource pressure forced eviction
    - 🔵 **FailedScheduling** → No resources available for scheduling

12. **Pod Restart Rate (Last 5m)** - Top 10 restarting pods
    - Bar chart showing restart rate per pod/container
    - Spikes indicate instability

**Key Features:**
- ✅ **Node Filtering**: `$node` variable to focus on specific nodes
- ✅ **Noisy Neighbor Detection**: Identify resource-hogging pods quickly
- ✅ **Root Cause Analysis**: Link pod events to resource exhaustion
- ✅ **Capacity Planning**: Understand cluster resource utilization

**Troubleshooting Workflow:**
```
1. Check Cluster-Wide Saturation
   └─ High CPU/Memory? → Capacity issue or noisy neighbor
   
2. Select specific node from $node dropdown
   └─ Check Node CPU/Memory/Disk/Network panels
   └─ Which node is saturated?
   
3. Check Noisy Neighbor Tables
   └─ Which pod is consuming excessive resources?
   └─ Is it expected (batch job) or unexpected (memory leak)?
   
4. Check Problematic Pod Events
   └─ OOMKilled? → Increase memory limits
   └─ Evicted? → Node pressure, scale cluster or reduce pod resources
   └─ CrashLoopBackOff? → Application bug, check logs
```

---

### Microservice Detail - RED Method Analysis

**Manifest:** `dashboards/dashboard-microservice-detail.yaml`

**Purpose:** Deep-dive service analysis using RED Method (Rate, Errors, Duration). Provides comprehensive service health monitoring with logs and tracing integration.

**Dashboard Structure (14 Panels):**

#### 🎯 RED Method KPIs (Top Row - 4 Panels)
Instant service health status:

1. **Rollout Status** - Argo Rollouts replica availability
   - Shows Available vs Desired replicas
   - Red (< 1): Service down
   - Green (≥ 1): Service healthy

2. **📊 Rate - Request Rate (RPS)** - Current request volume
   - Total requests per second to this service

3. **🔥 Errors - Error Rate (5xx)** - Server error rate
   - Green (< 0.01 req/s): Healthy
   - Yellow (0.01-0.1 req/s): Warning
   - Red (> 0.1 req/s): Critical

4. **⏱️ Duration - P95 Latency** - 95th percentile response time
   - Green (< 0.5s): Fast
   - Yellow (0.5-1s): Slow
   - Red (> 1s): Very slow

#### 📈 RED Method Details (Rows 2-3)

5. **Rate - Request Rate Over Time** - Request volume trend per pod
   - Shows traffic distribution across pods
   - Identifies load balancing issues

6. **Errors - HTTP Status Code Distribution** - Status code breakdown
   - 2xx (green): Success
   - 4xx (yellow): Client errors
   - 5xx (red): Server errors

7. **Duration - Latency Percentiles (p50/p95/p99)** - Full latency distribution
   - p50: Median response time (typical user experience)
   - p95: 95th percentile (slowest 5% of requests)
   - p99: 99th percentile (tail latency)

8. **In-Cluster Probe Latency** - Blackbox Exporter response time
   - Measures the path from the Blackbox Exporter pod to the target ClusterIP Service
   - Includes in-cluster networking and application response time
   - Does not measure the external user, Gateway, or public network path

#### 💻 Resources (Row 4 - 2 Panels)

9. **CPU Usage by Pod** - CPU consumption per pod
   - Identifies CPU-heavy pods
   - Shows CPU spikes during load

10. **Memory Usage by Pod** - Memory consumption per pod
   - Identifies memory leaks
   - Shows memory growth patterns

#### 📝 Logs & Tracing (Row 5 - 2 Panels)

11. **Service Logs (Loki)** - Real-time log stream
    - Filtered by namespace and service
    - Shows timestamps, log levels, and messages
    - Searchable and filterable

12. **Tracing - Jaeger Link** - Distributed tracing integration
    - Direct link to Jaeger UI for this service
    - Pre-filtered by service name
    - Enables trace analysis for slow requests

#### ⚠️ Health Indicators (Bottom Row - 2 Panels)

13. **Pod Restart Rate** - Pod restart frequency
    - Detects pod instability
    - Shows which pods are restarting frequently

14. **Pod Status Events** - Critical pod status issues
    - 🔴 **OOMKilled** → Increase memory limits
    - 🟠 **CrashLoopBackOff** → Check logs for crashes
    - 🟡 **ImagePullBackOff** → Verify image name/registry
    - 🔴 **Error** → Pod terminated with error

**Key Features:**
- ✅ **RED Method Compliance**: Industry-standard service monitoring (Rate, Errors, Duration)
- ✅ **Variable Driven**: `$namespace` and `$service` variables for dynamic filtering
- ✅ **Log Integration**: Direct access to service logs via Loki
- ✅ **Trace Integration**: One-click to Jaeger for distributed tracing
- ✅ **Resource Correlation**: Link service performance to resource usage
- ✅ **Drill-Down Target**: Designed to receive drill-down from Global SRE Dashboard

**Variable Usage:**
- **$namespace**: Select target namespace (staging, production, etc.)
- **$service**: Select target service (auto-populated from Argo Rollouts)

**Troubleshooting Workflow:**
```
1. Arrived from Global SRE Dashboard drill-down
   └─ Namespace and service already selected
   
2. Check RED Method KPIs (Top Row)
   └─ High error rate? → Check "Errors - HTTP Status Code Distribution"
   └─ High latency? → Check "Duration - Latency Percentiles"
   
3. High error rate detected?
   └─ Check "Service Logs" panel
   └─ Search for error messages, stack traces
   
4. High latency detected?
   └─ Click "Jaeger Link" → Analyze slow traces
   └─ Check "CPU Usage" → Is service CPU-saturated?
   
5. Check "Pod Restart Rate" + "Pod Status Events"
   └─ OOMKilled? → Increase memory limits
   └─ CrashLoopBackOff? → Application bug in logs
```

**Integration with Global SRE Dashboard:**
- URL: `/d/microservice-detail?var-namespace=<namespace>&var-service=<service>`
- Automatically receives namespace and service parameters from drill-down
- Enables seamless navigation from cluster overview to service details

---

## 🏗️ Architecture Decisions

### Why Grafana Alloy Instead of Separate Agents?

**Traditional Stack:**
- Prometheus Node Exporter (metrics)
- Promtail (logs)
- OpenTelemetry Collector (traces)
- = 3+ DaemonSets

**Our Stack:**
- Grafana Alloy (all three)
- = 1 DaemonSet

**Benefits:**
- ✅ Reduced resource usage (fewer pods)
- ✅ Unified Alloy process with separate metrics, logs, and traces ConfigMaps
- ✅ Consistent labeling across signals
- ✅ Easier troubleshooting (one agent to debug)

### Why Remote Write for Metrics?

**Traditional:** Prometheus scrapes targets directly

**Our Setup:** Alloy scrapes → Prometheus receives via remote write

**Benefits:**
- ✅ Decoupled collection from storage
- ✅ Alloy handles service discovery complexity
- ✅ Better scalability (stateless agents)
- ✅ Simplified RBAC (only Alloy needs cluster permissions)

### Why DaemonSet for Alloy?

**Alternatives:** Deployment, StatefulSet

**Why DaemonSet:**
- ✅ Node-level metrics need host filesystem access
- ✅ Logs are stored per-node (local file tailing)
- ✅ Distributed trace collection (resilience)
- ✅ Automatic scaling (new nodes get agent automatically)

### Why Filesystem Storage for Loki?

**Alternatives:** S3, GCS, Azure Blob

**Why Filesystem:**
- ✅ Simple setup (no external dependencies)
- ✅ Good for dev/small clusters
- ✅ No cloud costs
- ✅ Persistent filesystem storage on the Longhorn-backed volume

**Production Consideration:** Switch to object storage for multi-node Loki deployments

### Why Annotation-Based Pod Discovery?

**Alternatives:** ServiceMonitor (Prometheus Operator), PodMonitor

**Why Annotations:**
- ✅ No operator dependency
- ✅ Simple opt-in model (`prometheus.io/scrape: "true"`)
- ✅ Works with any deployment tool
- ✅ Standard pattern across ecosystem
