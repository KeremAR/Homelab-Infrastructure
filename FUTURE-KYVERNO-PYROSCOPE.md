# Future Architecture Roadmap: Policy Management & Continuous Profiling

This document outlines the architectural decisions, trade-off evaluations, rejected alternatives, and integration strategies for adding **Policy Management (Kyverno)** and **Continuous Profiling (Grafana Pyroscope)** to our Kubernetes infrastructure.

---

## 1. Kubernetes Policy Management: Kyverno

### 🎯 Why Kyverno?
**Kyverno** was selected to enforce Kubernetes API-level security hardening (Pod Security Standards), guarantee resource request/limit constraints, and automate multi-tenancy configurations.

* **Kubernetes-Native (Zero New Language):** Eliminates the steep learning curve of Domain Specific Languages like Rego (used by OPA). All policies are written in standard Kubernetes declarative YAML.
* **Core Capabilities:**
  * **Validation:** Blocks non-compliant resources (e.g., running as root, missing CPU/memory limits) from entering the API server.
  * **Mutation:** Automatically injects missing default labels, annotations, or resource limits into incoming manifests.
  * **Generation:** Dynamically provisions required resources (e.g., default `ResourceQuota`, `LimitRange`, `NetworkPolicy`) upon the creation of a new `Namespace`.
* **GitOps & CI/CD Ready:** Integrates with `kyverno CLI` to validate policies within CI/CD pipelines before applying manifests to live clusters.

### ❌ What Was Rejected & Why?
* **OPA / Gatekeeper:**
  * **Reason for Rejection:** High complexity caused by the **Rego** query language, leading to longer onboard times and increased operational maintenance. Kyverno delivers the same functional outcomes using native declarative YAML.

### 🚀 Rollout Strategy
1. **Phase 1 (Audit Mode):** Deploy policies with `validationFailureAction: Audit` to observe violations via `PolicyReport` CRDs without disrupting running workloads.
2. **Phase 2 (Enforce Mode):** Transition policies to `Enforce` mode to block non-compliant resource submissions after resolving pre-existing violations.

---

## 2. Continuous Profiling: Grafana Pyroscope

### 🎯 Primary Selection Factor: Cross-Signal Telemetry Correlation
The **decisive factor** for selecting Grafana Pyroscope over all other profiling solutions is its unmatched ability to achieve **seamless telemetry correlation** across our existing observability stack (Grafana, Jaeger, Prometheus, and Elasticsearch via Grafana Alloy).

While standalone profilers offer CPU/Memory flamegraphs in isolation, Pyroscope allows us to correlate profiling data directly with our existing Traces, Metrics, and Logs:

* **Span-Level Trace-to-Profile Correlation:** By propagating OpenTelemetry `TraceID`s into the Pyroscope SDK, we can jump directly from a slow Jaeger trace span to the exact lines of code executing in that specific millisecond window.
* **Contextual Metadata Alignment:** Pyroscope natively inherits Kubernetes labels and timestamps, enabling immediate correlation across all four telemetry pillars within Grafana without manual context switching.

### 🎯 Additional Key Benefits
* **Seamless Fit with Existing Topology:**
  * **Collector:** Ingests data natively using our deployed **Grafana Alloy** collector instance.
  * **Visualization:** Renders directly inside our existing **Grafana UI** as a native data source.
* **Dual Ingestion Flexibility:**
  * Supports zero-code eBPF-based cluster-wide profiling out of the box.
  * Supports language-specific SDKs for critical microservices requiring granular Span/Trace-level correlation.

### ❌ What Was Rejected & Why?
* **Parca:**
  * **Reason for Rejection:** Although Parca is a capable eBPF profiler, it lacks native, deep correlation mechanisms with our Grafana and Jaeger tracing setup. Furthermore, following Grafana Labs' acquisition of Polar Signals (the team behind Parca), Pyroscope incorporated eBPF capability natively while preserving superior correlation capabilities.
* **Running Both Profilers Concurrently:**
  * **Reason for Rejection:** Running Parca and Pyroscope simultaneously introduces unnecessary CPU/Memory overhead on nodes and creates storage/data duplication. **Pyroscope was chosen as the single source of truth.**

### 🔗 Architecture Integration & Datastores

The addition of Pyroscope rounds out our telemetry architecture as follows:

| Telemetry Signal | Collector | Storage Backend (Database) | Correlation Key |
| :--- | :--- | :--- | :--- |
| **Metrics** | Grafana Alloy | Prometheus | `pod`, `namespace`, `service_name` |
| **Traces** | Grafana Alloy | Jaeger | `trace_id`, `span_id` |
| **Logs** | Grafana Alloy | Elasticsearch | `trace_id`, `pod`, `timestamp` |
| **Profiles (NEW)** | **Grafana Alloy** | **Pyroscope Server** | `trace_id`, `pod`, `timestamp` |

### 🔍 Correlation Strategy in Practice
* **eBPF-Based Correlation (Zero-Code):** Correlates Flamegraphs with Jaeger Traces and Elasticsearch Logs using shared Kubernetes metadata (`pod`, `namespace`, `container`) and precise Time-Range windows in Grafana.
* **SDK-Based Correlation (Selective / High-Value Services):** For latency-critical services, the Pyroscope SDK will be enabled to inject `TraceID` tags, enabling exact **Span-to-Profile** jumping in Grafana dashboards.

---

## 📅 Architectural Decision Summary (TL;DR)
* **Kyverno:** Selected over OPA for its Kubernetes-native YAML syntax, avoiding Rego complexity while enforcing cluster guardrails.
* **Pyroscope:** Selected specifically because its **cross-signal correlation capabilities** bridge the gap between our **Alloy -> Jaeger / Elasticsearch / Prometheus** pipeline and code-level performance, creating a unified observability experience.