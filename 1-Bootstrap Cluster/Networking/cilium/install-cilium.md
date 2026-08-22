# Install Cilium

For a fresh Cluster API manifest, prevent kubeadm from installing kube-proxy:

```yaml
spec:
  kubeadmConfigSpec:
    clusterConfiguration:
      proxy:
        disabled: true
```

For a fresh cluster, first confirm Kubernetes assigned a PodCIDR to every node:

```bash
kubectl get nodes \
  -o 'custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR'
```

Install Cilium:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
  --version 1.20.1 \
  --namespace kube-system \
  --values '1-Bootstrap Cluster/Networking/cilium/values.yaml' \
  --wait --timeout 15m

kubectl rollout status daemonset/cilium -n kube-system --timeout=10m
kubectl exec -n kube-system daemonset/cilium -- cilium-dbg status --verbose
```

## Existing Calico/kube-proxy cluster only

Skip this section when neither component was installed. A direct conversion is
destructive and temporarily breaks Pod networking.

```bash
kubectl delete -f '1-Bootstrap Cluster/Networking/calico/calico.yaml'
kubectl delete daemonset kube-proxy -n kube-system
kubectl delete configmap kube-proxy -n kube-system
```

Remove stale Calico CNI files from every node. Replace the IP list if the node
addresses differ:

```bash
for ip in 192.168.0.150 192.168.0.152 192.168.0.153 192.168.0.154; do
  ssh -i ~/.ssh/id_ed25519 "root@$ip" \
    'rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig'
done
```

After Cilium is healthy, remove obsolete kube-proxy chains and recreate
ordinary pods so they receive Cilium networking:

```bash
for ip in 192.168.0.150 192.168.0.152 192.168.0.153 192.168.0.154; do
  ssh -i ~/.ssh/id_ed25519 "root@$ip" \
    'iptables-save | grep -v KUBE | iptables-restore; ip6tables-save | grep -v KUBE | ip6tables-restore'
done

kubectl get pods -A -o json \
  | jq -r '.items[]
      | select((.spec.hostNetwork // false) == false)
      | [.metadata.namespace, .metadata.name]
      | @tsv' \
  | while IFS=$'\t' read -r namespace pod; do
      kubectl delete pod "$pod" -n "$namespace" --wait=false
    done
```

Do not perform any of these removal commands on a fresh kube-proxy-free
cluster.
