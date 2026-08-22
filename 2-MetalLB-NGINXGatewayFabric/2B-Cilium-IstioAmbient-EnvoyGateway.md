# Direct install: Cilium + Istio Ambient + Envoy Gateway

The cluster in this repository is initially bootstrapped with **Calico**,
**kube-proxy** and **NGINX Gateway Fabric**. That remains the simpler baseline
installation described in [2A-MetalLB-NGINXGatewayFabric.md](./2A-MetalLB-NGINXGatewayFabric.md).

This document is the optional, recommended replacement when the goal is to
learn and use Cilium eBPF networking, Istio Ambient mTLS/L7 features and Envoy
Gateway. It is a destructive direct install, not a live migration:

- a full cluster network outage is expected;
- every ordinary pod is restarted;
- Longhorn/application data loss is accepted for this homelab;
- there is no secondary CNI, temporary Pod CIDR, gradual node takeover,
  PERMISSIVE mTLS stage, gateway canary IP or rollback procedure.

Versions used: Cilium `1.20.1`, Istio `1.30.3`, Kiali `2.30.0`, Envoy Gateway
`1.9.0` and Gateway API CRDs `1.6.1`.

## Fresh cluster or replacement?

The `10.244.0.0/16` range is the Kubernetes cluster's Pod address plan, not a
Calico-owned range. Cluster API places it in `Cluster.spec.clusterNetwork`, and
kubeadm configures the controller manager to divide it into per-node PodCIDRs.
Calico previously allocated Pod addresses from that plan; Cilium now does so.

For a fresh cluster, `ipam.mode: kubernetes` is a sensible choice when every
Node receives `spec.podCIDR` from Kubernetes. Verify that before installing the
CNI:

```bash
kubectl get nodes \
  -o 'custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR'
```

Use Cilium `cluster-pool` IPAM only when Kubernetes is not assigning PodCIDRs or
when Cilium should own their allocation. In that mode, the Cilium operator
writes per-node ranges to `CiliumNode.spec.ipam.podCIDRs`. Do not configure a
second, unrelated `10.245.0.0/16` pool while the cluster declares
`10.244.0.0/16` merely because Cilium is replacing Calico.

## 1. Confirm the existing Pod CIDRs

```bash
kubectl get nodes \
  -o 'custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR'
```

The current nodes already have non-overlapping `10.244.x.0/24` ranges assigned
in `Node.spec.podCIDR`. Therefore Cilium uses `ipam.mode: kubernetes` and reuses
the cluster's existing `10.244.0.0/16` Pod CIDR. No transition CIDR is needed.

## 2. Remove the previous CNI and kube-proxy, if present

Skip this entire section on a fresh cluster where Calico and kube-proxy were
never installed. It exists only for converting an already running classic
cluster.

```bash
kubectl delete -f '1-Bootstrap Cluster/calico.yaml'
kubectl delete daemonset kube-proxy -n kube-system
kubectl delete configmap kube-proxy -n kube-system
```

Remove the old Calico CNI files on every node. Cilium uses
`cni.exclusive: false` so it can later coexist with Istio CNI; therefore the
obsolete Calico files are removed explicitly.

```bash
for ip in 192.168.0.150 192.168.0.152 192.168.0.153 192.168.0.154; do
  ssh -i ~/.ssh/id_ed25519 "root@$ip" \
    'rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig'
done
```

Pod networking is expected to be unavailable at this point.

## 3. Install Cilium directly with kube-proxy replacement

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  --version 1.20.1 \
  --namespace kube-system \
  --values 2-MetalLB-NGINXGatewayFabric/cilium-values.yaml \
  --wait \
  --timeout 15m
```

The final values enable kube-proxy replacement immediately and explicitly
disable Cilium's Ingress controller, Gateway API controller, standalone Envoy
and L7 proxy. Istio and Envoy Gateway own those responsibilities.

`kubeProxyReplacement: true` means Cilium watches Kubernetes Services and
Endpoints and implements ClusterIP, NodePort, LoadBalancer, ExternalIP and
hostPort forwarding with eBPF instead of kube-proxy's iptables/IPVS rules. It
does not mean that Cilium replaces the API server, CoreDNS, MetalLB or the
north-south Gateway controller.

Wait for Cilium and restart all non-host-network pods so they receive Cilium
networking:

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=10m

kubectl get pods -A -o json \
  | jq -r '.items[]
      | select((.spec.hostNetwork // false) == false)
      | [.metadata.namespace, .metadata.name]
      | @tsv' \
  | while IFS=$'\t' read -r namespace pod; do
      kubectl delete pod "$pod" -n "$namespace" --wait=false
    done
```

After Cilium is healthy, clear obsolete kube-proxy chains on every node:

```bash
for ip in 192.168.0.150 192.168.0.152 192.168.0.153 192.168.0.154; do
  ssh -i ~/.ssh/id_ed25519 "root@$ip" \
    'iptables-save | grep -v KUBE | iptables-restore; ip6tables-save | grep -v KUBE | ip6tables-restore'
done
```

```bash
kubectl -n kube-system exec daemonset/cilium -- cilium-dbg status --verbose
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl get pods -n kube-system
kubectl get daemonset kube-proxy -n kube-system
```

The last command must return `NotFound`.

Disable the `kube_proxy` discovery and scrape components in
`7_Observability-Stack/metrics/alloy-metrics-config.yaml`, then reload Alloy.
Keep the block commented as an optional example for classic clusters that
still run kube-proxy:

```bash
kubectl apply -f 7_Observability-Stack/metrics/alloy-metrics-config.yaml
kubectl rollout restart daemonset alloy -n observability
```

### Fresh Cluster API installation

For a newly generated Cluster API manifest, prevent kubeadm from creating
kube-proxy in the first place:

```yaml
spec:
  kubeadmConfigSpec:
    clusterConfiguration:
      proxy:
        disabled: true
```

Keep the declared Cluster API Pod CIDR and Cilium IPAM consistent. With this
cluster's Kubernetes IPAM configuration it remains `10.244.0.0/16`.

## 4. Install Istio Ambient

```bash
curl -L https://istio.io/downloadIstio \
  | ISTIO_VERSION=1.30.3 TARGET_ARCH=x86_64 sh -
sudo install istio-1.30.3/bin/istioctl /usr/local/bin/istioctl

kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm upgrade --install istio-base istio/base \
  --version 1.30.3 --namespace istio-system --create-namespace --wait

helm upgrade --install istiod istio/istiod \
  --version 1.30.3 --namespace istio-system \
  --values 2-MetalLB-NGINXGatewayFabric/istiod-values.yaml --wait

helm upgrade --install istio-cni istio/cni \
  --version 1.30.3 --namespace istio-system \
  --values 2-MetalLB-NGINXGatewayFabric/istio-cni-values.yaml --wait

helm upgrade --install ztunnel istio/ztunnel \
  --version 1.30.3 --namespace istio-system \
  --values 2-MetalLB-NGINXGatewayFabric/ztunnel-values.yaml --wait

kubectl apply -f 2-MetalLB-NGINXGatewayFabric/istio-telemetry.yaml
```

Gateway API CRDs are not built into Kubernetes. The command above installs the
Gateway API `1.6.1` standard bundle, which is enough for the GatewayClass,
Gateway, HTTPRoute and ReferenceGrant resources used here. Install the
experimental channel only if a selected feature actually requires its alpha
resource types.

Later, the Envoy CRD chart is configured with
`crds.gatewayAPI.enabled=false`; it adds only Envoy-specific CRDs because this
step already owns the shared Gateway API CRDs.

If an older Gateway API installation blocks the CRD upgrade through its
`safe-upgrades.gateway.networking.k8s.io` admission policy, remove that old
upgrade guard and repeat the server-side apply with field ownership forced:

```bash
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io

kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

Enroll both application namespaces directly with STRICT mTLS:

```bash
kubectl label namespace staging istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace production istio.io/dataplane-mode=ambient --overwrite

kubectl apply -f 2-MetalLB-NGINXGatewayFabric/ambient-staging-strict.yaml
kubectl apply -f 2-MetalLB-NGINXGatewayFabric/ambient-production-strict.yaml

istioctl ztunnel-config workloads
kubectl get peerauthentication -A
```

No sidecars are injected. The small iptables redirect installed by Istio CNI
inside pod network namespaces is expected and independent of Cilium's eBPF
cluster datapath.

## 5. Add only service-scoped waypoints

Create a waypoint only for a service that needs HTTP metrics/traces, retries,
timeouts, weighted routing, JWT-aware authorization or another L7 feature:

```bash
istioctl waypoint apply \
  --namespace production \
  --name todo-service-waypoint \
  --for service

kubectl label service todo-service \
  --namespace production \
  istio.io/use-waypoint=todo-service-waypoint \
  --overwrite
```

Use a distinct waypoint and Service label for each additional selected service.
Do not set `istio.io/use-waypoint` on the namespace and do not route PostgreSQL
through a waypoint merely to obtain mTLS; ztunnel already provides L4 mTLS.
Only the production `todo-service` received a waypoint in this installation
because it was the selected L7 example. Staging still receives ambient ztunnel
mTLS, but it has no waypoint and therefore no waypoint-generated HTTP RED
telemetry. Add a separate staging waypoint only when those L7 features are
actually required there.

## 6. Verify Istio metrics in the existing stack

Istiod, istio-cni and ztunnel are rendered with Prometheus scrape annotations.
Generated waypoint pods also expose Prometheus metrics. Verify the live objects:

```bash
kubectl get pods -n istio-system -o yaml | grep -A3 -B2 prometheus.io
kubectl get pods -n production -o yaml | grep -A3 -B2 prometheus.io
```

The existing Alloy generic Pod Discovery reads `prometheus.io/scrape`,
`prometheus.io/port` and `prometheus.io/path`, so no dedicated `istio-system`
scrape component is necessary. The live verification showed that the Istio
charts add these annotations to ztunnel and generated waypoint pods without
extra Alloy configuration. Generate waypoint traffic:

```bash
kubectl run istio-metric-test \
  --namespace production \
  --image=curlimages/curl:8.16.0 \
  --restart=Never \
  --command -- sh -c \
  'for i in $(seq 1 20); do curl -sS -o /dev/null http://todo-service:8002/health || true; done'

kubectl wait pod/istio-metric-test \
  --namespace production \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=3m
```

Confirm `istio_requests_total` actually reached the existing Prometheus:

```bash
kubectl exec -n observability deployment/prometheus-server -- \
  wget -qO- \
  'http://localhost:9090/api/v1/query?query=istio_requests_total'
```

Only treat observability integration as complete when this returns a non-empty
result. In this cluster it returned both `response_code="200"` and
`connection_security_policy="mutual_tls"` for waypoint traffic. ztunnel-only
paths provide TCP/L4 metrics; HTTP
`istio_requests_total` is produced on waypoint/Envoy L7 paths.

`istio-telemetry.yaml` also sends spans to the existing Alloy OTLP receiver at
`alloy.observability.svc.cluster.local:4317` and enables Envoy stdout access
logs, which Alloy already collects into Elasticsearch.

On a fresh cluster, `prometheus.io/scrape` annotations are harmless before
Alloy exists; they are only metadata and nothing attempts a scrape yet. Defer
the tracing portion of `istiod-values.yaml`, `istio-telemetry.yaml`, the Envoy
Gateway tracing `backendRefs`, and `alloy-referencegrant.yaml` until Alloy's
Service exists. Otherwise networking still works, but trace exporters log
connection failures and discard spans until the collector becomes available.

## 7. Install Kiali

```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update

helm upgrade --install kiali-server kiali/kiali-server \
  --version 2.30.0 --namespace istio-system \
  --values 2-MetalLB-NGINXGatewayFabric/kiali-values.yaml --wait
```

Kiali uses the existing Prometheus, Grafana and Jaeger services. ztunnel-only
edges contain L4 telemetry; waypoint edges contain HTTP RED telemetry.

## 8. Replace NGINX Gateway Fabric with Envoy Gateway

HTTPRoute does not contain `gatewayClassName`; that field belongs to the
Gateway. HTTPRoutes move controllers by changing `spec.parentRefs`.

Release MetalLB IP `.110` and remove NGF:

```bash
kubectl delete gateway shared-gateway -n nginx-gateway
helm uninstall ngf -n nginx-gateway
```

Install only Envoy Gateway's extension CRDs. Gateway API CRDs are already
managed separately for Istio and Envoy:

```bash
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.0 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

helm upgrade --install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.0 --namespace envoy-gateway-system --create-namespace \
  --values 2-MetalLB-NGINXGatewayFabric/envoy-gateway-values.yaml --wait

kubectl apply -f 2-MetalLB-NGINXGatewayFabric/alloy-referencegrant.yaml
kubectl apply -f 2-MetalLB-NGINXGatewayFabric/envoy-gateway-resources.yaml
```

The CRD chart is rendered and applied instead of stored as a Helm release
because its rendered CRDs can make the Helm release Secret exceed Kubernetes'
1 MiB object limit.

This cluster applies STRICT mTLS to the application namespaces. Enroll the
managed Envoy proxy namespace in ambient mode so the gateway-to-backend leg
also uses mTLS, then recreate the proxy pod so Istio CNI captures its traffic:

```bash
kubectl label namespace envoy-gateway-system \
  istio.io/dataplane-mode=ambient --overwrite

kubectl rollout restart deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
kubectl rollout status deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
  --timeout=3m
```

The Envoy proxy may run on the control-plane node in this small cluster. Remove
MetalLB's exclusion label there; otherwise a Service with
`externalTrafficPolicy: Local` cannot advertise `.110` from that node:

```bash
kubectl label node homelab-control-plane-8vt27 \
  node.kubernetes.io/exclude-from-external-load-balancers-
```

That label normally tells external load-balancer implementations not to use a
node as an ingress/advertisement point. It is commonly placed on control-plane
nodes. We removed it only because this one-replica Envoy proxy was scheduled on
the control-plane and MetalLB therefore had no eligible local endpoint from
which to announce the LoadBalancer IP.

The EnvoyProxy requests the freed MetalLB IP `192.168.0.110`. First update and
push every checked-in HTTPRoute parent to `envoy-gateway`. Argo CD applications
with `selfHeal: true` will otherwise immediately restore `nginx-gateway` after
the following live patch. Then move every live HTTPRoute parent:

```bash
kubectl get httproute -A -o json \
  | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' \
  | while IFS=$'\t' read -r namespace route; do
      kubectl patch httproute "$route" -n "$namespace" --type=json \
        -p='[{"op":"replace","path":"/spec/parentRefs/0/namespace","value":"envoy-gateway"}]'
    done
```

If reconciliation was temporarily paused while testing the unpushed route
change, resume it only after the commit is available to Argo CD:

```bash
kubectl annotate application helm-production-frontend -n argocd \
  argocd.argoproj.io/skip-reconcile-
kubectl annotate application helm-staging-frontend -n argocd \
  argocd.argoproj.io/skip-reconcile-
```

This is a temporary annotation on the two Argo CD `Application` objects, not on
frontend pods. It prevents Argo CD self-heal from restoring the old
`nginx-gateway` parent before the Git change is pushed.

Update checked-in HTTPRoutes in the same way, using
`gateway.networking.k8s.io/v1`, then expose Hubble and Kiali:

```bash
kubectl apply -f 2-MetalLB-NGINXGatewayFabric/hubble-ui-httproute.yaml
kubectl apply -f 2-MetalLB-NGINXGatewayFabric/kiali-httproute.yaml

kubectl wait --for=condition=Programmed \
  gateway/shared-gateway --namespace envoy-gateway --timeout=5m

kubectl get gatewayclass,gateway,httproute -A
curl -v http://todo-app.192.168.0.110.nip.io/
```

## References

- [Cilium Kubernetes host-scope IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/)
- [Cilium cluster-pool IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/)
- [Cilium kube-proxy-free installation](https://docs.cilium.io/en/latest/network/kubernetes/kubeproxy-free/)
- [Gateway API CRD installation](https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/)
- [Cilium with Istio](https://docs.cilium.io/en/latest/network/servicemesh/istio/)
- [Istio Ambient Helm installation](https://istio.io/latest/docs/ambient/install/helm/)
- [Istio waypoint usage](https://istio.io/latest/docs/ambient/usage/waypoint/)
- [Istio OpenTelemetry tracing](https://istio.io/latest/docs/tasks/observability/distributed-tracing/opentelemetry/)
- [Envoy Gateway compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/)
- [MetalLB service advertisement troubleshooting](https://metallb.io/troubleshooting/)
