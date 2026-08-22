# Install MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --wait

kubectl apply -f '2-Gateway-API-and-MetalLB/metallb/metallb-config.yaml'
kubectl get ipaddresspool,l2advertisement -n metallb-system
```
