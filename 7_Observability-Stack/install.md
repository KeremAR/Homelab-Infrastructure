# Observability Stack Installation

This stack uses Prometheus for metrics, Loki for logs, Jaeger for traces,
Grafana for visualization, and Grafana Alloy as the collection agent. Run all
commands from the repository root.

## Prerequisites

- `kubectl` targets the `homelab` cluster.
- Helm 3 is installed.
- `longhorn-storageclass` exists.
- `shared-gateway` exists in `nginx-gateway` and uses `192.168.0.110`.
- Kubelet serving certificates are enabled and approved. Alloy verifies the
  kubelet HTTPS endpoint with the cluster CA.

```bash
kubectl config current-context
kubectl get storageclass longhorn-storageclass
kubectl get gateway shared-gateway -n nginx-gateway
kubectl get nodes
```

## Expose Kubernetes component metrics

The API server and CoreDNS metrics are already reachable through Kubernetes
Services. kube-scheduler, kube-controller-manager, etcd, and kube-proxy use
loopback metrics addresses by default, which normal Alloy pods cannot reach.

> These changes expose metrics ports on the node network. Use them only on a
> trusted homelab network, or restrict TCP ports `10249`, `10257`, `10259`, and
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

Edit the kube-proxy ConfigMap:

```bash
kubectl edit configmap kube-proxy -n kube-system
```

Inside `data.config.conf`, change only `metricsBindAddress`:

```yaml
data:
  config.conf: |-
    # Other existing KubeProxyConfiguration fields remain unchanged.
    metricsBindAddress: "0.0.0.0:10249"
```

Restart kube-proxy so every node uses the new value:

```bash
kubectl rollout restart daemonset/kube-proxy -n kube-system
kubectl rollout status daemonset/kube-proxy -n kube-system
```

The Alloy configuration scrapes these endpoints as follows:

| Component | Target |
|---|---|
| kube-apiserver | `https://kubernetes.default.svc:443/metrics` |
| kube-proxy | `<node-internal-ip>:10249/metrics` |
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
# Grafana and Loki community charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
# Alloy is still published from Grafana's product repository
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update
```

## 2. Create the namespace, storage, and Grafana Secret

Prometheus and Grafana use explicitly created PVCs. Loki's chart creates its
own 2 Gi PVC from `longhorn-storageclass` through `singleBinary.persistence`.

```bash
kubectl apply -f 7_Observability-Stack/namespace.yaml
kubectl apply -f 7_Observability-Stack/metrics/prometheus-pvc.yaml
kubectl apply -f 7_Observability-Stack/grafana-pvc.yaml
```

Add this variable to the repository root `.env` file:

```dotenv
GRAFANA_ADMIN_PASSWORD=replace-with-a-strong-password
```

```bash
set -a
source .env
set +a
envsubst < 7_Observability-Stack/grafana-secrets.yaml | kubectl apply -f -
```

## 3. Install Prometheus and its exporters

Alloy collects node, pod, and container metrics, so the Prometheus chart's
bundled exporters are disabled. kube-state-metrics and Blackbox Exporter are
installed separately.

```bash
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace observability \
  --values 7_Observability-Stack/metrics/prometheus-values.yaml \
  --wait

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace observability \
  --values 7_Observability-Stack/metrics/kube-state-metrics-values.yaml \
  --wait

helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
  --namespace observability \
  --values 7_Observability-Stack/metrics/blackbox-exporter-values.yaml \
  --wait
```

Expose the Prometheus web interface through the shared Gateway:

```bash
kubectl apply -f 7_Observability-Stack/metrics/prometheus-httproute.yaml
```

Prometheus: <http://prometheus.192.168.0.110.nip.io>

## 4. Install Loki

This homelab uses a persistent, single-binary Loki deployment. It is simple but
is not an HA Loki architecture.

```bash
helm upgrade --install loki grafana-community/loki \
  --namespace observability \
  --values 7_Observability-Stack/logs/loki-values.yaml \
  --wait
```

## 5. Install Jaeger

Jaeger uses an in-memory backend, so traces are ephemeral. The unified Jaeger
v2 Service exposes both OTLP and the query UI.

```bash
helm upgrade --install jaeger jaegertracing/jaeger \
  --namespace observability \
  --values 7_Observability-Stack/traces/jaeger-values.yaml \
  --wait
```

Expose the Jaeger query UI through the shared Gateway:

```bash
kubectl apply -f 7_Observability-Stack/traces/jaeger-httproute.yaml
```

Jaeger: <http://jaeger.192.168.0.110.nip.io>

## 6. Install Grafana Alloy

Alloy runs once per node and sends metrics to Prometheus, logs to Loki, and
traces to Jaeger. Its configuration is kept in three signal-specific
ConfigMaps. Kubernetes projects them into one directory, which Alloy loads as
a single configuration.

Pod Discovery and EndpointSlice Discovery are both enabled. They do not
inherently duplicate data, but the same workload would be scraped twice if
both its Pod template and Service had `prometheus.io/scrape: "true"`. Use only
one annotation level per workload. This stack uses Pod annotations for
kube-state-metrics and a Service annotation for CoreDNS. An annotated Service
must expose its metrics port with the name `metrics`.

```bash
kubectl apply -f 7_Observability-Stack/alloy-bootstrap-config.yaml
kubectl apply -f 7_Observability-Stack/metrics/alloy-metrics-config.yaml
kubectl apply -f 7_Observability-Stack/logs/alloy-logs-config.yaml
kubectl apply -f 7_Observability-Stack/traces/alloy-traces-config.yaml

helm upgrade --install alloy grafana/alloy \
  --namespace observability \
  --values 7_Observability-Stack/alloy-values.yaml \
  --wait
```

The Helm chart's config reloader only watches its primary ConfigMap and does
not watch the projected signal ConfigMaps. After editing one of them, apply it
and restart Alloy:

```bash
kubectl apply -f 7_Observability-Stack/metrics/alloy-metrics-config.yaml
kubectl apply -f 7_Observability-Stack/logs/alloy-logs-config.yaml
kubectl apply -f 7_Observability-Stack/traces/alloy-traces-config.yaml
kubectl rollout restart daemonset/alloy -n observability
kubectl rollout status daemonset/alloy -n observability
```

Expose the Alloy UI through the shared Gateway:

```bash
kubectl apply -f 7_Observability-Stack/alloy-httproute.yaml
```

Alloy: <http://alloy.192.168.0.110.nip.io>

Applications can send OTLP data to:

```text
http://alloy.observability.svc.cluster.local:4318
alloy.observability.svc.cluster.local:4317
```

## 7. Install Grafana

Datasource UIDs are fixed as `prometheus` and `loki`, so dashboard manifests do
not need a script to discover generated UIDs.

```bash
helm upgrade --install grafana grafana-community/grafana \
  --namespace observability \
  --values 7_Observability-Stack/grafana-values.yaml \
  --wait
```

Expose the Grafana UI through the shared Gateway:

```bash
kubectl apply -f 7_Observability-Stack/grafana-httproute.yaml
```

Grafana: <http://grafana.192.168.0.110.nip.io>

## 8. Install the dashboards

```bash
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-memory-analysis.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-global-sre-overview.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-infrastructure-cluster.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-microservice-detail.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-kubernetes-components.yaml
```

The Grafana sidecar loads ConfigMaps labeled `grafana_dashboard: "1"`
automatically; Grafana does not need to be restarted.

## 9. Verify the installation

```bash
kubectl get pods,pvc -n observability
kubectl get httproute -n observability
kubectl logs -n observability daemonset/alloy --tail=100
```

Every node should have one Alloy pod. All PVCs should be `Bound`, and all four
HTTPRoutes should be accepted by the shared Gateway.
