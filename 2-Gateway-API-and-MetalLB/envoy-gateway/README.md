# Envoy Gateway

Envoy Gateway is the modern north-south Gateway API implementation. The
GatewayClass is `eg`; the controller creates a managed Envoy proxy and requests
MetalLB IP `192.168.0.110`.

`alloy-referencegrant.yaml` authorizes the `EnvoyProxy` in namespace
`envoy-gateway` to reference the Alloy Service in namespace `observability` as
its OTLP tracing backend. ReferenceGrant authorizes a cross-namespace API
reference; it does not open a firewall or create network connectivity.

The single proxy replica is allowed to run on the control-plane node. The node
label `node.kubernetes.io/exclude-from-external-load-balancers` normally keeps
external load balancers away from control-plane nodes. Remove it only when the
Envoy proxy is actually scheduled there and MetalLB cannot announce the
`externalTrafficPolicy: Local` Service; otherwise keep the exclusion label.

Follow [install-envoy.md](./install-envoy.md).
