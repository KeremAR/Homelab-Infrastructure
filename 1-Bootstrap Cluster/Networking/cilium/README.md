# Cilium

Cilium is the modern CNI option. `values.yaml` uses Kubernetes host-scope IPAM:
Cilium allocates Pod IPs from the per-node `Node.spec.podCIDR` ranges already
assigned from the cluster's `10.244.0.0/16` Pod CIDR.

`kubeProxyReplacement: true` makes Cilium implement ClusterIP, NodePort,
LoadBalancer, ExternalIP and hostPort forwarding with eBPF. Cilium's Ingress,
Gateway API and L7 proxy features are disabled because Istio and Envoy Gateway
own those responsibilities.

Hubble Relay and UI are enabled. Apply `hubble-ui.yaml` only after the shared
Envoy Gateway exists.

Follow [install-cilium.md](./install-cilium.md).
