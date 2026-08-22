# Cluster networking

Install exactly one primary CNI immediately after Cluster API creates the
workload cluster. Nodes remain `NotReady` until this step is complete.

| Option | CNI | Kubernetes Service implementation |
|---|---|---|
| Classic | Calico | kube-proxy |
| Modern | Cilium | Cilium eBPF kube-proxy replacement |

The cluster-wide Pod address plan is `10.244.0.0/16`. It is declared in
`cluster.yaml`; it does not belong to Calico or Cilium. Both CNI options must
use that same plan.

- [Calico](./calico/README.md)
- [Cilium](./cilium/README.md)

For a fresh Cilium cluster, disable kube-proxy in the generated Cluster API
manifest before applying it. Calico/kube-proxy removal and iptables cleanup are
needed only when converting an existing classic cluster.
