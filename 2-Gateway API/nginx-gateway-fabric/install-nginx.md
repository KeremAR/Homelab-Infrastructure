# Install NGINX Gateway Fabric

Install the shared Gateway API CRDs from `2-Gateway API/README.md` first.

The NGF Helm chart is pulled from the GHCR OCI registry. Authenticate before
installation, even though the chart is public, to avoid GHCR's intermittent
anonymous-pull `403 denied` response:

```bash
gh auth login
gh auth token | helm registry login ghcr.io \
  --username "$(gh api user --jq .login)" \
  --password-stdin
```

This installation uses all chart defaults and therefore needs no local values
file or `--set` flags:

- `gatewayClassName` defaults to `nginx`.
- `nginx.service.type` defaults to `LoadBalancer`.

```bash
helm upgrade --install ngf \
  oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.6.5 \
  --namespace nginx-gateway --create-namespace \
  --wait

kubectl apply -f '2-Gateway API/nginx-gateway-fabric/shared-gateway.yaml'
kubectl get gateway,httproute -A
```

If an override is needed later, consult the upstream
[`charts/nginx-gateway-fabric/values.yaml`](https://github.com/nginx/nginx-gateway-fabric/blob/main/charts/nginx-gateway-fabric/values.yaml)
for the full list of current values. Chart defaults can change between
versions.

## End-to-end test: MetalLB, NGF and Gateway API

`test-app.yaml` contains its own Deployment, Service and HTTPRoute:

```bash
kubectl apply -f '2-Gateway API/nginx-gateway-fabric/test-app.yaml'
kubectl get gateway,httproute -A

GATEWAY_IP=$(kubectl get gateway shared-gateway -n nginx-gateway \
  -o jsonpath='{.status.addresses[0].value}')
curl --resolve test.example.com:80:"$GATEWAY_IP" \
  http://test.example.com/
```

Tear down the test application once it has been confirmed:

```bash
kubectl delete -f '2-Gateway API/nginx-gateway-fabric/test-app.yaml'
```
