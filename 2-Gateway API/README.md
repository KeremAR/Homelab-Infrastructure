# Gateway API and north-south networking

Gateway API CRDs are not built into Kubernetes. Install the standard `1.6.1`
bundle once, before either gateway controller:

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

The CRDs live here rather than under Istio because Gateway API is a shared
Kubernetes API used by NGINX Gateway Fabric, Envoy Gateway and Istio waypoints.
Istio must merely find the CRDs before a waypoint `Gateway` is created.

Install [MetalLB](./common/metallb/README.md), then choose one north-south
controller:

- [NGINX Gateway Fabric](./nginx-gateway-fabric/README.md)
- [Envoy Gateway](./envoy-gateway/README.md)

Do not run both controllers against the same GatewayClass or LoadBalancer IP.
