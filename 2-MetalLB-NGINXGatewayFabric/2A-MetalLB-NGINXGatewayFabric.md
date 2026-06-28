# MetalLB + NGINX Gateway Fabric — Setup Notes

Goal: bare-metal LoadBalancer support (MetalLB) + Gateway API ingress (NGINX Gateway Fabric, "NGF") on the Proxmox/CAPI cluster from the [main setup notes](./capi-proxmox-setup-notes.md).

YAML manifests referenced below (IPAddressPool + L2Advertisement, the shared Gateway, test app) are kept as **separate files**, applied via `kubectl apply -f <file>` — not inlined here.

---

## MetalLB

Installed via the official Helm chart — not raw manifests.

### Install

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update

helm install metallb metallb/metallb \
  --create-namespace \
  --namespace metallb-system \
  --wait

kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

### Configuration: IPAddressPool + L2Advertisement

Own manifest, not pulled from a random GitHub repo — kept in its own file (e.g. `metallb-config.yaml`), applied with:
```bash
kubectl apply -f metallb-config.yaml
```

Verify:
```bash
kubectl get ipaddresspools.metallb.io -n metallb-system
kubectl get l2advertisements.metallb.io -n metallb-system
```

---

## NGINX Gateway Fabric (NGF)

<details>
<summary><strong>Issue 8 — 403 denied pulling the chart from ghcr.io (OCI registry)</strong></summary>

Symptom, on the documented install command:
```
Error: INSTALLATION FAILED: GET "https://ghcr.io/v2/nginx/charts/nginx-gateway-fabric/tags/list":
GET "https://ghcr.io/token?scope=repository%3Anginx%2Fcharts%2Fnginx-gateway-fabric%3Apull&service=ghcr.io":
response status code 403: denied: denied
```

Happens with or without `--version` pinned — not a version-specific issue. This is a **known, reported bug** in NGINX Gateway Fabric's own repo ([nginx/nginx-gateway-fabric#4282](https://github.com/nginx/nginx-gateway-fabric/issues/4282)) and has been hit independently by ArgoCD and Flux users pulling the same public chart — ghcr.io's anonymous/public pull occasionally 403s even though the repo is public and pullable directly via browser/`gh`.

**Fix — authenticate to ghcr.io with a GitHub account before pulling, even though the chart is public:**
```bash
sudo apt install gh -y
gh auth login
gh auth token | helm registry login ghcr.io --username "$(gh api user --jq .login)" --password-stdin
```
Do this **before** the `helm install` OCI command below — not after, and not only on failure. Once logged in, the OCI pull works.

**Alternative (no GitHub login needed at all):** clone the chart from source and install from the local directory instead of pulling from ghcr.io:
```bash
git clone --depth 1 --branch v2.6.5 https://github.com/nginx/nginx-gateway-fabric.git
cd nginx-gateway-fabric/charts/nginx-gateway-fabric
helm install ngf . --namespace nginx-gateway --create-namespace --wait
```
This bypasses the OCI registry entirely.

</details>

### Install

Gateway API CRDs first (NGINX's own pinned kustomize reference, not the generic `kubernetes-sigs/gateway-api` release — keeps the CRD version in lockstep with the NGF version being installed):
```bash
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.6.5" | kubectl apply -f -
```

Then the chart itself (after the `gh auth` steps above, if hitting Issue 8):
```bash

helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace nginx-gateway \
  --create-namespace \
  --wait
```

**Used all chart defaults here** — no `--set` flags:
- `gatewayClassName` defaults to `nginx` (didn't override to a custom name)
- `nginx.service.type` defaults to `LoadBalancer` already (didn't need to set it explicitly)

> If anything needs overriding later, check `charts/nginx-gateway-fabric/values.yaml` in the [nginx/nginx-gateway-fabric GitHub repo](https://github.com/nginx/nginx-gateway-fabric) for the full list of available values and their current defaults — defaults can change between versions, don't assume the values used here stay accurate forever.

Wait for the control plane:
```bash
kubectl wait --timeout=5m -n nginx-gateway deployment/ngf-nginx-gateway-fabric --for=condition=Available
```

### Shared Gateway

Own file (e.g. `shared-gateway.yaml`), applied separately:
```bash
kubectl apply -f shared-gateway.yaml
```

Get the assigned LoadBalancer IP (should come from the MetalLB pool above):
```bash
kubectl get gateway shared-gateway -n nginx-gateway -o jsonpath='{.status.addresses[0].value}'
```
or:
```bash
kubectl get svc -n nginx-gateway
```

---

## End-to-end test (MetalLB + NGF + Gateway API, all in one)

Own file (e.g. `test-app.yaml`) containing a Deployment + Service + HTTPRoute, applied with:
```bash
kubectl apply -f test-app.yaml
```

Then:
```bash
kubectl get httproute -n nginx-gateway
kubectl describe httproute test-nginx-route -n nginx-gateway   # look for Accepted: True, ResolvedRefs: True

GATEWAY_IP=$(kubectl get gateway shared-gateway -n nginx-gateway -o jsonpath='{.status.addresses[0].value}')
echo $GATEWAY_IP
curl -v http://$GATEWAY_IP/
```

Expected: nginx's default welcome page. Confirms the full chain works end to end — MetalLB IP assignment → NGF Gateway → HTTPRoute → Service → Pod.

Tear down the test app once confirmed:
```bash
kubectl delete -f test-app.yaml
```