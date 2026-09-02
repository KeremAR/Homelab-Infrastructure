# Install Istio Ambient

Install Gateway API CRDs first; waypoints are Kubernetes Gateway resources.

```bash
curl -L https://istio.io/downloadIstio \
  | ISTIO_VERSION=1.30.3 TARGET_ARCH=x86_64 sh -
sudo install istio-1.30.3/bin/istioctl /usr/local/bin/istioctl

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

helm upgrade --install istio-base istio/base \
  --version 1.30.3 -n istio-system --create-namespace --wait
helm upgrade --install istiod istio/istiod \
  --version 1.30.3 -n istio-system \
  -f '5-Service-Mesh/istio-ambient/istiod-values.yaml' --wait
helm upgrade --install istio-cni istio/cni \
  --version 1.30.3 -n istio-system \
  -f '5-Service-Mesh/istio-ambient/istio-cni-values.yaml' --wait
helm upgrade --install ztunnel istio/ztunnel \
  --version 1.30.3 -n istio-system \
  -f '5-Service-Mesh/istio-ambient/ztunnel-values.yaml' --wait

kubectl apply -f '5-Service-Mesh/istio-ambient/istio-telemetry.yaml'
```

This installation consists of `istiod`, `istio-cni` and `ztunnel`. It does not
install an Istio ingress gateway. No sidecars are injected. The small iptables
redirect installed by Istio CNI inside each Pod network namespace is expected
and is independent of Cilium's eBPF cluster datapath.

`istioOwnedCNIConfig: true` makes Istio keep its chained CNI entry in a
separate, persistent conflist instead of modifying Cilium's own conflist. This
prevents Cilium from temporarily removing the Istio CNI entry when it rewrites
its configuration during a node reboot. Without it, restored Pods can appear
Running while their traffic bypasses ztunnel and is rejected by STRICT mTLS.
The CNI repair mode remains `repairPods`; `deletePods` is not used because it
grants cluster-wide Pod deletion and does not address a Pod that startup
reconciliation skipped before its network namespace became visible.
Node reboot without drain is an upstream Ambient issue and can still have a
separate istio-cni/ztunnel startup race; track
[istio/istio#60882](https://github.com/istio/istio/issues/60882) and verify
workload identities after upgrading or rebooting the nodes.

Enroll both namespaces and apply STRICT mTLS:

```bash
kubectl label namespace staging istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace production istio.io/dataplane-mode=ambient --overwrite
kubectl apply -f '5-Service-Mesh/istio-ambient/policies/staging-strict.yaml'
kubectl apply -f '5-Service-Mesh/istio-ambient/policies/production-strict.yaml'
```

This cluster applies STRICT mTLS to the application namespaces. If Envoy
Gateway was installed before Istio, apply its `EnvoyProxy` resource, which
labels only the managed data-plane proxy for ambient mode. Do not label the
whole `envoy-gateway-system` namespace because that also captures the
controller and can break its xDS connection to the proxy. Recreate the proxy
Pod so Istio CNI captures its traffic:

```bash
kubectl apply -f '2-Gateway-API-and-MetalLB/envoy-gateway/envoy-proxy.yaml'
kubectl rollout restart deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
kubectl rollout status deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
  --timeout=3m
```

The Argo Rollouts controller also calls the application canary Services during
analysis. Enroll its namespace in ambient mode and recreate the controller Pod
so Istio CNI can capture those calls before enabling STRICT mTLS analysis:

```bash
kubectl label namespace argo-rollouts \
  istio.io/dataplane-mode=ambient --overwrite
kubectl rollout restart deployment/argo-rollouts -n argo-rollouts
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=3m
```

These labels must also exist in the Git-managed manifests. The `kubectl label`
commands above repair the live cluster, but ArgoCD can overwrite an out-of-sync
resource during reconciliation. Keep the following declarations in the
manifests used by this deployment:

- `argo-rollouts` Namespace: `istio.io/dataplane-mode: ambient`
- Backend stable and canary Services: `istio.io/use-waypoint: <service>-waypoint`

The Helm Service templates and the Argo Rollouts namespace manifest contain
these declarations. Commit and push them before the next ArgoCD sync.

Create one waypoint per selected Service and attach all four Services:

```bash
for namespace in staging production; do
  for service in todo-service user-service; do
    istioctl waypoint apply \
      --namespace "$namespace" \
      --name "${service}-waypoint" \
      --for service
    kubectl label service "$service" \
      --namespace "$namespace" \
      istio.io/use-waypoint="${service}-waypoint" \
      --overwrite
    kubectl label service "${service}-canary" \
      --namespace "$namespace" \
      istio.io/use-waypoint="${service}-waypoint" \
      --overwrite
  done
done

kubectl get gateway -n staging
kubectl get gateway -n production
```

Install Kiali after Prometheus, Grafana and Jaeger exist:

```bash
helm repo add kiali https://kiali.org/helm-charts
helm repo update
helm upgrade --install kiali-server kiali/kiali-server \
  --version 2.30.0 -n istio-system \
  -f '5-Service-Mesh/istio-ambient/kiali-values.yaml' --wait
kubectl apply -f '5-Service-Mesh/istio-ambient/kiali-httproute.yaml'
```
