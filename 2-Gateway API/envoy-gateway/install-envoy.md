# Install Envoy Gateway

Install Gateway API CRDs and MetalLB first.

The CRD chart is rendered and applied instead of stored as a Helm release
because its rendered CRDs can make the Helm release Secret exceed Kubernetes'
1 MiB object limit.

```bash
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.9.0 \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.0 \
  --namespace envoy-gateway-system --create-namespace \
  --values '2-Gateway API/envoy-gateway/values.yaml' \
  --wait

kubectl apply -f '2-Gateway API/envoy-gateway/shared-gateway.yaml'
kubectl apply -f '2-Gateway API/envoy-gateway/envoy-proxy.yaml'
```

If the managed proxy is scheduled on the control-plane and MetalLB does not
announce `.110`, make that node eligible as a last step:

```bash
kubectl label node homelab-control-plane-8vt27 \
  node.kubernetes.io/exclude-from-external-load-balancers-
```

That label normally tells external load-balancer implementations not to use a
node as an ingress or advertisement point. It is commonly placed on
control-plane nodes. We removed it only because this one-replica Envoy proxy
was scheduled on the control-plane and MetalLB therefore had no eligible local
endpoint from which to announce the LoadBalancer IP. Do not remove it unless
this specific condition applies.

If the observability namespace and Alloy Service already exist, enable the
cross-namespace tracing reference:

```bash
kubectl apply -f '2-Gateway API/envoy-gateway/alloy-referencegrant.yaml'
```

With application namespaces in Istio STRICT mode, enroll the managed proxy and
recreate it so the gateway-to-backend connection uses ambient mTLS:

```bash
kubectl label namespace envoy-gateway-system \
  istio.io/dataplane-mode=ambient --overwrite
kubectl rollout restart deployment -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
```

```bash
kubectl wait --for=condition=Programmed \
  gateway/shared-gateway -n envoy-gateway --timeout=5m
kubectl get gatewayclass,gateway -A
```

## Replace an existing NGINX Gateway Fabric installation

This section is needed only when converting an existing classic installation.
Run it before applying Envoy's `shared-gateway.yaml` above so the Gateway name
and MetalLB address `.110` are free:

```bash
kubectl delete gateway shared-gateway -n nginx-gateway --ignore-not-found
helm uninstall ngf -n nginx-gateway
```
