# Service mesh

Istio Ambient is installed after Cilium and Gateway API CRDs. ztunnel provides
namespace-level L4 mTLS without sidecars; service-scoped waypoints add L7
policy, routing and HTTP telemetry only where requested.

See [istio-ambient/README.md](./istio-ambient/README.md).
