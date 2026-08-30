# Observability Stack Installation

This stack uses Prometheus for metrics, Elasticsearch and Kibana for logs,
Jaeger for traces, Pyroscope for profiles, Grafana for visualization, and
Grafana Alloy as the collection agent. Run all commands from the repository
root.

## Prerequisites

- `kubectl` targets the `homelab` cluster.
- Helm 3 is installed.
- `longhorn-storageclass` exists.
- `shared-gateway` exists in `envoy-gateway` and uses `192.168.0.110`.
- Kubelet serving certificates are enabled and approved. Alloy verifies the
  kubelet HTTPS endpoint with the cluster CA.

```bash
kubectl config current-context
kubectl get storageclass longhorn-storageclass
kubectl get gateway shared-gateway -n envoy-gateway
kubectl get nodes
```

## Expose Kubernetes component metrics

The API server and CoreDNS metrics are already reachable through Kubernetes
Services. kube-scheduler, kube-controller-manager and etcd use loopback metrics
addresses by default, which normal Alloy pods cannot reach. This cluster uses
Cilium kube-proxy replacement, so there is no kube-proxy endpoint to expose.

> These changes expose metrics ports on the node network. Use them only on a
> trusted homelab network, or restrict TCP ports `10257`, `10259`, and
> `2381` to the cluster node and Pod CIDRs with a firewall.

On every control-plane node, back up and edit the static Pod manifests:

```bash
sudo install -d -m 0700 /etc/kubernetes/manifest-backups
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml \
  /etc/kubernetes/manifest-backups/kube-scheduler.yaml.before-metrics
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /etc/kubernetes/manifest-backups/kube-controller-manager.yaml.before-metrics
sudo cp /etc/kubernetes/manifests/etcd.yaml \
  /etc/kubernetes/manifest-backups/etcd.yaml.before-metrics

sudo sed -i \
  's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' \
  /etc/kubernetes/manifests/kube-scheduler.yaml \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

sudo sed -i \
  's#--listen-metrics-urls=http://127.0.0.1:2381#--listen-metrics-urls=http://0.0.0.0:2381#' \
  /etc/kubernetes/manifests/etcd.yaml
```

Do not keep backup files inside `/etc/kubernetes/manifests`; kubelet scans all
non-hidden files in that directory and may interpret a backup as another
static Pod manifest.

Kubelet notices these manifest changes and restarts the three static Pods.
This briefly interrupts the affected components, so change one control-plane
node at a time in an HA cluster. Verify the listeners from the node:

These are node-local static manifest changes. If Cluster API replaces a
control-plane VM, repeat this section for the new node or add the equivalent
component `extraArgs` to the `KubeadmControlPlane` configuration before
provisioning it.

```bash
sudo ss -lntp | grep -E ':(2381|10257|10259)\b'
```

### Optional: expose kube-proxy metrics on a classic cluster

Skip this section when Cilium runs with `kubeProxyReplacement: true`. If the
classic networking option still uses kube-proxy, edit its ConfigMap:

```bash
kubectl edit configmap kube-proxy -n kube-system
```

Set `metricsBindAddress` inside `data.config.conf`:

```yaml
data:
  config.conf: |-
    # Keep the other KubeProxyConfiguration fields unchanged.
    metricsBindAddress: "0.0.0.0:10249"
```

```bash
kubectl rollout restart daemonset/kube-proxy -n kube-system
kubectl rollout status daemonset/kube-proxy -n kube-system
```

Then uncomment the optional `kube_proxy` discovery and scrape components in
`metrics/alloy-metrics-config.yaml`. Port `10249` must also be restricted to
the node and Pod networks when a firewall is used.

The Alloy configuration scrapes these endpoints as follows:

| Component | Target |
|---|---|
| kube-apiserver | `https://kubernetes.default.svc:443/metrics` |
| kube-proxy (classic option only) | `<node-internal-ip>:10249/metrics` |
| kube-scheduler | `https://<control-plane-ip>:10259/metrics` |
| kube-controller-manager | `https://<control-plane-ip>:10257/metrics` |
| etcd | `http://<control-plane-ip>:2381/metrics` |

The scheduler and controller-manager generate self-signed serving
certificates by default. Their Alloy scrape blocks therefore skip serving
certificate verification but still authenticate with Alloy's ServiceAccount
token. API server verification continues to use the cluster CA.

## 1. Add the Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# Grafana community chart
helm repo add grafana-community https://grafana-community.github.io/helm-charts
# Alloy is still published from Grafana's product repository
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo update
```

## 2. Create the namespace, storage, and Secrets

Prometheus, Pyroscope and Grafana use explicitly created PVCs. ECK creates
Elasticsearch's StatefulSet PVC from the `volumeClaimTemplates` in
`logs/elasticsearch.yaml`.

```bash
kubectl apply -f 8_Observability-Stack/namespace.yaml
kubectl apply -f 8_Observability-Stack/metrics/prometheus-pvc.yaml
kubectl apply -f 8_Observability-Stack/profiling/pyroscope-pvc.yaml
kubectl apply -f 8_Observability-Stack/grafana-pvc.yaml
```

Add these variables to the repository root `.env` file:

```dotenv
GRAFANA_ADMIN_PASSWORD=replace-with-a-strong-password
ELASTIC_PASSWORD=replace-with-a-strong-password
```

```bash
set -a
source .env
set +a
envsubst < 8_Observability-Stack/grafana-secrets.yaml | kubectl apply -f -
envsubst < 8_Observability-Stack/logs/elastic-credentials-secret.yaml | kubectl apply -f -
```

## 3. Install Prometheus and its exporters

Alloy collects node, pod, and container metrics, so the Prometheus chart's
bundled exporters are disabled. kube-state-metrics and Blackbox Exporter are
installed separately.

```bash
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace observability \
  --values 8_Observability-Stack/metrics/prometheus-values.yaml \
  --wait

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace observability \
  --values 8_Observability-Stack/metrics/kube-state-metrics-values.yaml \
  --wait

helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --namespace observability \
  --values 8_Observability-Stack/metrics/blackbox-exporter-values.yaml \
  --wait
```

Expose the Prometheus web interface through the shared Gateway:

```bash
kubectl apply -f 8_Observability-Stack/metrics/prometheus-httproute.yaml
```

Prometheus: <http://prometheus.192.168.0.110.nip.io>

## 4. Install Elasticsearch and Kibana with ECK

ECK manages the Elasticsearch StatefulSet, Kibana Deployment, TLS certificates,
credentials, and rolling updates. This homelab deployment uses one
Elasticsearch node and a 2 Gi Longhorn volume, so it is persistent but not HA.

ECK does not use a Helm-style `existingClaim` setting for its managed
Elasticsearch data volume. The `volumeClaimTemplates` entry creates the
StatefulSet PVC with a deterministic name. `DeleteOnScaledownOnly` preserves
that claim if the Elasticsearch resource is deleted, allowing ECK to adopt it
when the resource is recreated with the same cluster and node-set names. The
2 Gi size is suitable only for this small lab; it can be increased later when
the StorageClass supports expansion, but Kubernetes does not allow shrinking
an existing claim.

```bash
helm upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system \
  --create-namespace \
  --version 3.5.0 \
  --wait

kubectl apply -f 8_Observability-Stack/logs/elasticsearch.yaml
kubectl apply -f 8_Observability-Stack/logs/kibana.yaml
kubectl get elasticsearch -n observability
kubectl get kibana -n observability
kubectl get pods -n observability -w
```

Wait until Elasticsearch reports `green` (or `yellow` only because this is a
single-node cluster) and Kibana becomes healthy, then stop the watch with
`Ctrl+C`. Kibana's public HTTP listener is intentionally plain HTTP because
this trusted homelab exposes it through the existing shared Gateway.
Elasticsearch remains HTTPS-only.

```bash
kubectl get pods,pvc -n observability
kubectl apply -f 8_Observability-Stack/logs/kibana-httproute.yaml
```

Kibana: <http://kibana.192.168.0.110.nip.io>

Log in as `elastic` with `ELASTIC_PASSWORD`. In Kibana, open **Stack
Management → API Keys → Create API key** and use the role descriptor stored in
`8_Observability-Stack/logs/alloy-api-key-role.json`. Copy the encoded API key
and add the complete authorization value to `.env`:

```dotenv
ELASTIC_AUTHORIZATION=ApiKey replace-with-the-encoded-api-key
```

Create the Secret consumed by Alloy:

```bash
set -a
source .env
set +a
envsubst < 8_Observability-Stack/logs/elastic-key-secret.yaml | kubectl apply -f -
```

ECK creates `logs-es-http-certs-public`. Alloy mounts this Secret directly and
uses its `ca.crt` to verify Elasticsearch; no copied CA file is required.

## 5. Install Jaeger

Jaeger uses an in-memory backend, so traces are ephemeral. The unified Jaeger
v2 Service exposes both OTLP and the query UI.

```bash
helm upgrade --install jaeger jaegertracing/jaeger \
  --namespace observability \
  --values 8_Observability-Stack/traces/jaeger-values.yaml \
  --wait
```

Expose the Jaeger query UI through the shared Gateway:

```bash
kubectl apply -f 8_Observability-Stack/traces/jaeger-httproute.yaml
```

Jaeger: <http://jaeger.192.168.0.110.nip.io>

## 6. Install Pyroscope

Pyroscope runs as a single binary and stores profiles on the pre-created 2 Gi
Longhorn claim. The chart's bundled Alloy is disabled because this stack uses
the existing Alloy DaemonSet.

```bash
helm upgrade --install pyroscope grafana/pyroscope \
  --version 2.2.1 \
  --namespace observability \
  --values 8_Observability-Stack/profiling/pyroscope-values.yaml \
  --wait

kubectl apply -f 8_Observability-Stack/profiling/pyroscope-httproute.yaml
```

Pyroscope: <http://pyroscope.192.168.0.110.nip.io>

The SDK and Alloy integration are described in
[`profiling/README.md`](profiling/README.md).

## 7. Install Grafana Alloy

Alloy runs once per node and sends metrics to Prometheus, logs to Elasticsearch,
traces to Jaeger, and profiles to Pyroscope. Its configuration is kept in four
signal-specific ConfigMaps. Kubernetes projects them into one directory, which
Alloy loads as a single configuration.

The log collector still uses `loki.source.file` and `loki.process`. These are
local Alloy pipeline components, not a Loki server. `otelcol.receiver.loki`
converts their output to OpenTelemetry logs, and `otelcol.exporter.otlphttp`
sends them to Elasticsearch's `/_otlp/v1/logs` endpoint.

Pod Discovery and EndpointSlice Discovery are both enabled. They do not
inherently duplicate data, but the same workload would be scraped twice if
both its Pod template and Service had `prometheus.io/scrape: "true"`. Use only
one annotation level per workload. This stack uses Pod annotations for
kube-state-metrics and a Service annotation for CoreDNS. An annotated Service
must expose its metrics port with the name `metrics`.

```bash
kubectl apply -f 8_Observability-Stack/alloy-bootstrap-config.yaml
kubectl apply -f 8_Observability-Stack/metrics/alloy-metrics-config.yaml
kubectl apply -f 8_Observability-Stack/logs/alloy-logs-config.yaml
kubectl apply -f 8_Observability-Stack/traces/alloy-traces-config.yaml
kubectl apply -f 8_Observability-Stack/profiling/alloy-profiles-config.yaml

helm upgrade --install alloy grafana/alloy \
  --namespace observability \
  --values 8_Observability-Stack/alloy-values.yaml \
  --wait

# Allow EnvoyProxy in envoy-gateway to reference Alloy across namespaces.
kubectl apply -f '2-Gateway-API-and-MetalLB/envoy-gateway/alloy-referencegrant.yaml'
```

The Helm chart's config reloader only watches its primary ConfigMap and does
not watch the projected signal ConfigMaps. After editing one of them, apply it
and restart Alloy:

```bash
kubectl apply -f 8_Observability-Stack/metrics/alloy-metrics-config.yaml
kubectl apply -f 8_Observability-Stack/logs/alloy-logs-config.yaml
kubectl apply -f 8_Observability-Stack/traces/alloy-traces-config.yaml
kubectl apply -f 8_Observability-Stack/profiling/alloy-profiles-config.yaml
kubectl rollout restart daemonset/alloy -n observability
kubectl rollout status daemonset/alloy -n observability
```

Expose the Alloy UI through the shared Gateway:

```bash
kubectl apply -f 8_Observability-Stack/alloy-httproute.yaml
```

Alloy: <http://alloy.192.168.0.110.nip.io>

Applications can send OTLP data to:

```text
http://alloy.observability.svc.cluster.local:4318
alloy.observability.svc.cluster.local:4317
http://alloy.observability.svc.cluster.local:4040
```

Ports `4317` and `4318` receive OTLP traces; port `4040` receives Pyroscope
SDK profiles.

## 8. Install Grafana

The Prometheus datasource UID is fixed, so dashboard manifests do not need a
script to discover a generated UID. Logs are explored in Kibana Discover.

```bash
helm upgrade --install grafana grafana-community/grafana \
  --namespace observability \
  --values 8_Observability-Stack/grafana-values.yaml \
  --wait
```

Expose the Grafana UI through the shared Gateway:

```bash
kubectl apply -f 8_Observability-Stack/grafana-httproute.yaml
```

Grafana: <http://grafana.192.168.0.110.nip.io>

## 9. Install the dashboards

```bash
kubectl apply -f 8_Observability-Stack/dashboards/dashboard-memory-analysis.yaml
kubectl apply -f 8_Observability-Stack/dashboards/dashboard-global-sre-overview.yaml
kubectl apply -f 8_Observability-Stack/dashboards/dashboard-infrastructure-cluster.yaml
kubectl apply -f 8_Observability-Stack/dashboards/dashboard-microservice-detail.yaml
kubectl apply -f 8_Observability-Stack/dashboards/dashboard-kubernetes-components.yaml

# Official dashboards, pinned to the installed component versions
kubectl apply --server-side -k 8_Observability-Stack/dashboards/official/istio
kubectl apply --server-side -k 8_Observability-Stack/dashboards/official/cilium
kubectl apply --server-side -k 8_Observability-Stack/dashboards/official/envoy-gateway
```

The Grafana sidecar loads ConfigMaps labeled `grafana_dashboard: "1"`
automatically; Grafana does not need to be restarted. The official dashboards
use the existing Prometheus datasource and do not deploy another observability
backend. See `dashboards/official/README.md` for source versions and the one
intentional Cilium dashboard omission.

Server-side apply is used because client-side apply stores the complete
ConfigMap in the `last-applied-configuration` annotation. The larger official
dashboard bundles would exceed Kubernetes' 256 KiB annotation limit.

## 10. Verify the installation

```bash
kubectl get pods,pvc -n observability
kubectl get httproute -n observability
kubectl logs -n observability daemonset/alloy --tail=100
```

Every node should have one Alloy pod. All PVCs should be `Bound`, and all six
HTTPRoutes should be accepted by the shared Gateway. Generate a new application
log, then confirm that a `logs-*` data stream and its fields appear in Kibana
Discover.

## 11. Remove an existing Loki deployment

For a migration, keep Loki running until new logs are visible in Kibana. The
following commands permanently remove the old Loki release and its stored log
data because the PVC uses the `Delete` reclaim policy:

```bash
helm uninstall loki -n observability
kubectl delete pvc storage-loki-0 -n observability
```
