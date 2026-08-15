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

## 1. Add the Helm repositories

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
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

## 4. Install Loki

This homelab uses a persistent, single-binary Loki deployment. It is simple but
is not an HA Loki architecture.

```bash
helm upgrade --install loki grafana/loki \
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

## 6. Install Grafana Alloy

Alloy runs once per node and sends metrics to Prometheus, logs to Loki, and
traces to Jaeger.

```bash
kubectl apply -f 7_Observability-Stack/alloy-config.yaml

helm upgrade --install alloy grafana/alloy \
  --namespace observability \
  --values 7_Observability-Stack/alloy-values.yaml \
  --wait
```

Applications can send OTLP data to:

```text
http://alloy.observability.svc.cluster.local:4318
alloy.observability.svc.cluster.local:4317
```

## 7. Install Grafana

Datasource UIDs are fixed as `prometheus` and `loki`, so dashboard manifests do
not need a script to discover generated UIDs.

```bash
helm upgrade --install grafana grafana/grafana \
  --namespace observability \
  --values 7_Observability-Stack/grafana-values.yaml \
  --wait
```

## 8. Install the dashboards

```bash
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-memory-analysis.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-global-sre-overview.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-infrastructure-cluster.yaml
kubectl apply -f 7_Observability-Stack/dashboards/dashboard-microservice-detail.yaml
```

The Grafana sidecar loads ConfigMaps labeled `grafana_dashboard: "1"`
automatically; Grafana does not need to be restarted.

## 9. Expose the web interfaces

```bash
kubectl apply -f 7_Observability-Stack/metrics/prometheus-httproute.yaml
kubectl apply -f 7_Observability-Stack/grafana-httproute.yaml
kubectl apply -f 7_Observability-Stack/alloy-httproute.yaml
kubectl apply -f 7_Observability-Stack/traces/jaeger-httproute.yaml
```

- Grafana: <http://grafana.192.168.0.110.nip.io>
- Prometheus: <http://prometheus.192.168.0.110.nip.io>
- Alloy: <http://alloy.192.168.0.110.nip.io>
- Jaeger: <http://jaeger.192.168.0.110.nip.io>

## 10. Verify the installation

```bash
kubectl get pods,pvc -n observability
kubectl get httproute -n observability
kubectl logs -n observability daemonset/alloy --tail=100
```

Every node should have one Alloy pod. All PVCs should be `Bound`, and all four
HTTPRoutes should be accepted by the shared Gateway.
