# Publish the application with a Cloudflare Tunnel

This directory publishes the application through Cloudflare Tunnel. The
`cloudflared` Pod creates an outbound connection to Cloudflare, so the cluster
does not need an inbound port-forward or a public IP. Cloudflare forwards the
published hostname to the internal Envoy Gateway Service, and Envoy routes the
request to the Kubernetes `HTTPRoute`.

The steps below use `keremar.com` and `todo-app.keremar.com` as the example
domain and hostname. Replace them if you are publishing a different domain.

## Prerequisites

Complete these steps first:

- Envoy Gateway and the `shared-gateway` Gateway are installed.
- The staging frontend `HTTPRoute` exists in the `staging` namespace.
- `kubectl` uses the application cluster context.

Check the Gateway and its managed proxy Service:

```bash
kubectl get gateway shared-gateway -n envoy-gateway
kubectl get svc -A \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway
```

The current cluster returns a Service similar to:

```text
envoy-gateway-system/envoy-envoy-gateway-shared-gateway-53cb189f
```

The generated suffix can change when the Gateway is recreated. Always use the
name and namespace returned by `kubectl get svc`, rather than copying an old
suffix.

## 1. Add the domain to Cloudflare

1. Sign in to the [Cloudflare dashboard](https://dash.cloudflare.com/) and
   choose **Add a site**.
2. Enter `keremar.com`, select the **Free** plan and continue to activation.
3. Cloudflare displays two authoritative nameservers. Copy the values shown in
   your account; for this setup they were `logan.ns.cloudflare.com` and
   `raquel.ns.cloudflare.com`.
4. Open the domain in [Squarespace Domains](https://account.squarespace.com/domains),
   open **DNS / Domain nameservers**, select **Use custom nameservers**, remove
   the existing nameservers and add the two Cloudflare nameservers.
5. Wait until Cloudflare reports the domain as **Active**. Nameserver changes
   can take time to propagate.

Cloudflare must be authoritative for the domain before a published tunnel
hostname can resolve.

## 2. Create the tunnel and its Kubernetes Secret

In the Cloudflare dashboard, open **Zero Trust → Networks → Tunnels**, create a
tunnel, and give it a descriptive name. In **Run tunnel with...**, choose the
Docker/container command and copy the token from the command Cloudflare shows.
Do not commit the token to Git.

Create or update the Secret in `kube-system`:

```bash
kubectl -n kube-system create secret generic cloudflared-token \
  --from-literal=TUNNEL_TOKEN='<TUNNEL_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

`cloudflared.yaml` reads the `TUNNEL_TOKEN` key from this Secret. The Secret
must exist before applying the Deployment.

## 3. Run `cloudflared` in the cluster

Apply the connector Deployment:

```bash
kubectl apply -f cloudflared.yaml
kubectl rollout status deployment/cloudflared -n kube-system --timeout=3m
kubectl logs -n kube-system deployment/cloudflared --tail=100
```

The logs should show that the tunnel connected successfully. In the Cloudflare
tunnel page, the connector should also appear as **Healthy/Connected**.

## 4. Publish the Envoy Gateway Service in Cloudflare

Open the tunnel in Cloudflare and choose **Add route → Published application**.
Configure the route as follows:

- **Subdomain:** `todo-app`
- **Domain:** `keremar.com`
- **Type:** `HTTP`
- **Service:** the internal Envoy proxy Service URL

For the current cluster, the Service URL is:

```text
http://envoy-envoy-gateway-shared-gateway-53cb189f.envoy-gateway-system.svc.cluster.local:80
```

If the Service name or namespace changed, build the URL from the output of the
Service lookup in the prerequisites section:

```text
http://<service-name>.<service-namespace>.svc.cluster.local:80
```

This is an in-cluster URL. Do not use the MetalLB address for the tunnel origin;
Cloudflared already runs inside the cluster and can reach the Service directly.

## 5. Set the hostname on the HTTPRoute

The Envoy Gateway listener selects routes by hostname. Edit the staging route:

```bash
kubectl edit httproute -n staging staging-frontend-route
```

Under `spec`, set `hostnames` with the same hostname configured in Cloudflare:

```yaml
spec:
  parentRefs:
    - name: shared-gateway
      namespace: envoy-gateway
  hostnames:
    - todo-app.keremar.com
```

Keep the existing `rules` and backend references unchanged. If an old
`nip.io` hostname is present, replace it with the Cloudflare hostname or keep
both entries temporarily while testing.

Confirm that the route is accepted and programmed:

```bash
kubectl get httproute staging-frontend-route -n staging
kubectl describe httproute staging-frontend-route -n staging
```

Then open [https://todo-app.keremar.com](https://todo-app.keremar.com) and test
the frontend and its `/api/v1/...` requests. The browser sends the hostname in
the `Host` header, which lets Envoy match this `HTTPRoute`.

## Updating the tunnel token

If Cloudflare rotates or replaces the token, update the Secret and restart the
Deployment so the connector reads the new value:

```bash
kubectl -n kube-system create secret generic cloudflared-token \
  --from-literal=TUNNEL_TOKEN='<NEW_TUNNEL_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/cloudflared -n kube-system
kubectl rollout status deployment/cloudflared -n kube-system --timeout=3m
```
