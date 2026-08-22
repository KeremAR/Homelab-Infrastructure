# Calico

Calico is the classic CNI option in this repository. It gives every Pod a
routable cluster IP, configures Pod networking on each node, manages Pod IP
allocation and enforces Kubernetes NetworkPolicy. kube-proxy remains
responsible for Kubernetes Service virtual IPs and load balancing.

The `calico-node` DaemonSet runs on every Kubernetes node and programs that
node's Pod routes, packet handling and policy rules. The
`calico-kube-controllers` Deployment watches Kubernetes resources and keeps
Calico's IPAM and cluster state synchronized. Together they provide the
east-west Pod network; they do not expose applications to the homelab LAN.
MetalLB and a Gateway API controller perform that separate north-south role.

In this homelab, Calico uses the cluster-wide `10.244.0.0/16` Pod network
declared in `cluster.yaml`. It is an alternative to Cilium, not something that
should be installed alongside it as a second primary CNI.

Follow [install-calico.md](./install-calico.md) for the installation commands.
