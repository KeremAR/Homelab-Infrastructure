# Install Calico

Use this option only when the cluster keeps kube-proxy.

The homelab LAN uses `192.168.0.0/24`, which overlaps with Calico's default
`192.168.0.0/16` Pod CIDR. Download the official manifest and change its Pod
CIDR to the same non-overlapping `10.244.0.0/16` range configured in
`cluster.yaml` before applying it:

```bash
export KUBECONFIG="$PWD/homelab.kubeconfig"

curl -L \
  -o '1-Bootstrap-Cluster-and-Networking/Networking/calico/calico.yaml' \
  https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml

# Uncomment CALICO_IPV4POOL_CIDR.
sed -i 's|.*- name: CALICO_IPV4POOL_CIDR.*|            - name: CALICO_IPV4POOL_CIDR|' \
  '1-Bootstrap-Cluster-and-Networking/Networking/calico/calico.yaml'

# Use the same Pod CIDR declared in cluster.yaml.
sed -i 's|.*value: "192.168.0.0/16".*|              value: "10.244.0.0/16"|' \
  '1-Bootstrap-Cluster-and-Networking/Networking/calico/calico.yaml'
```

Before CAPI clones any VMs, the Proxmox VM template must use CPU type `host`.
Calico `v3.32.0` requires x86-64-v2 instructions; the old `kvm64` model exposes
only x86-64-v1 and causes the `upgrade-ipam` init container to fail.

```text
Proxmox template → Hardware → Processors → Edit → CPU type: host
```

Apply and verify:

```bash
kubectl get nodes
kubectl apply -f '1-Bootstrap-Cluster-and-Networking/Networking/calico/calico.yaml'

kubectl rollout status deployment/calico-kube-controllers \
  -n kube-system --timeout=5m
kubectl rollout status daemonset/calico-node \
  -n kube-system --timeout=5m
kubectl get nodes
```

Every node should become `Ready`.

<details>
<summary>Why an overlapping Pod CIDR breaks LAN access</summary>

With Calico's original `192.168.0.0/16` pool, a LAN destination such as
`192.168.0.100` looks like another Pod destination. Calico skips outgoing NAT,
the packet leaves with its internal Pod source IP, and the LAN has no return
route. The result is a silent timeout rather than a clear configuration error.

</details>

<details>
<summary>CPU microarchitecture failure</summary>

If `calico-node` remains in `Init:Error`, check:

```bash
kubectl logs -n kube-system \
  "$(kubectl get pod -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.name}')" \
  -c upgrade-ipam
```

An x86-64-v2 error means the VM or template still uses `kvm64`. Fix the
template permanently rather than editing every cloned node separately.

</details>
