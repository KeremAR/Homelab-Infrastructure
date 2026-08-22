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
  -f '3-Service Mesh/istio-ambient/istiod-values.yaml' --wait
helm upgrade --install istio-cni istio/cni \
  --version 1.30.3 -n istio-system \
  -f '3-Service Mesh/istio-ambient/istio-cni-values.yaml' --wait
helm upgrade --install ztunnel istio/ztunnel \
  --version 1.30.3 -n istio-system \
  -f '3-Service Mesh/istio-ambient/ztunnel-values.yaml' --wait

kubectl apply -f '3-Service Mesh/istio-ambient/istio-telemetry.yaml'
```

This installation consists of `istiod`, `istio-cni` and `ztunnel`. It does not
install an Istio ingress gateway. No sidecars are injected. The small iptables
redirect installed by Istio CNI inside each Pod network namespace is expected
and is independent of Cilium's eBPF cluster datapath.

Enroll both namespaces and apply STRICT mTLS:

```bash
kubectl label namespace staging istio.io/dataplane-mode=ambient --overwrite
kubectl label namespace production istio.io/dataplane-mode=ambient --overwrite
kubectl apply -f '3-Service Mesh/istio-ambient/policies/staging-strict.yaml'
kubectl apply -f '3-Service Mesh/istio-ambient/policies/production-strict.yaml'
```

This cluster applies STRICT mTLS to the application namespaces. If Envoy
Gateway was installed before Istio, enroll the managed Envoy proxy namespace
in ambient mode so the gateway-to-backend leg also uses mTLS, then recreate the
proxy Pod so Istio CNI captures its traffic:

```bash
kubectl label namespace envoy-gateway-system \
  istio.io/dataplane-mode=ambient --overwrite
kubectl rollout restart deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
kubectl rollout status deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
  --timeout=3m
```

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
  -f '3-Service Mesh/istio-ambient/kiali-values.yaml' --wait
kubectl apply -f '3-Service Mesh/istio-ambient/kiali-httproute.yaml'
```
