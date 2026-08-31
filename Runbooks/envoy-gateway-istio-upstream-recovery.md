# Envoy Gateway and Istio Ambient Upstream Recovery

This runbook covers the following failure:

```text
upstream connect error or disconnect/reset before headers
reset reason: connection termination
```

It is intended for a route that returns `503` even though the application Pods
and Service endpoints appear healthy.

## Incident Signature

The failure is likely related to a stale or missing Istio Ambient redirect when
most of these observations are true:

- The public Gateway URL returns `503`.
- The Envoy access log contains response flags such as `UC`.
- The application Pods are `Ready` and the Service has ready endpoints.
- A request made directly to the application Service returns `200`.
- `ztunnel` reports a policy rejection or a connection without a source identity.
- Istio CNI reports a failed in-pod rule reconciliation or a missing Pod netns.

This can happen after an Istio CNI, node, or cluster restart. The existing
Envoy Gateway proxy Pod may keep stale Ambient networking state even though the
application itself is healthy.

## Architecture Context

The relevant path is:

```text
Client
  -> Gateway IP / HTTPRoute
  -> Envoy Gateway proxy Pod
  -> Istio Ambient redirect and ztunnel
  -> application Service
  -> application Pod
```

The `staging` and `production` namespaces use Istio Ambient mode and strict
mTLS. The Envoy Gateway namespace is also enrolled in Ambient mode. Istio CNI
installs the traffic redirection rules when the proxy Pod is created. If those
rules are not reconciled after a node or CNI event, Envoy can reach the Service
but the connection is rejected by the Ambient policy path.

## Quick Diagnosis

Set the public Gateway address and hostname for the affected route:

```bash
GATEWAY_IP=192.168.0.110
STAGING_HOST=todo-app-staging.192.168.0.110.nip.io

curl -sS -i --max-time 10 \
  -H "Host: ${STAGING_HOST}" \
  "http://${GATEWAY_IP}/"
```

Check the application, endpoints, and Rollout:

```bash
kubectl get pods -n staging -l app=frontend -o wide
kubectl get endpointslice -n staging \
  -l kubernetes.io/service-name=frontend -o wide
kubectl get rollout frontend -n staging -o wide
kubectl get svc frontend -n staging
```

Check the Envoy Gateway proxy logs:

```bash
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
  -c envoy --since=15m | \
  grep -Ei '503|reset|connection|frontend|staging'
```

Check the Ambient data plane:

```bash
kubectl logs -n istio-system -l app=ztunnel --since=15m | \
  grep -Ei 'policy rejection|connection termination|frontend|staging'

kubectl logs -n istio-system -l k8s-app=istio-cni-node --since=30m | \
  grep -Ei 'failed to reconcile|envoy-gateway|netns|redirect'
```

Test the application without the external Gateway. This separates an
application failure from a Gateway or mesh failure:

```bash
kubectl run frontend-curl --rm -i --restart=Never -n staging \
  --image=curlimages/curl:8.10.1 -- \
  curl -sS -i --max-time 10 http://frontend:3000/
```

Use this decision order:

| Observation | Likely problem | Next action |
| --- | --- | --- |
| No ready endpoints or Pods are not `Ready` | Application or Rollout | Inspect the application Pod and Rollout first. |
| Direct Service request fails | Application, Service, or container port | Fix the application path before restarting Envoy. |
| Direct Service request succeeds, external route returns `503` | Gateway, Istio, or HTTPRoute path | Continue with Envoy and Ambient checks. |
| Envoy shows `UC` and ztunnel/CNI shows policy or netns errors | Stale Ambient redirect on Envoy proxy | Restart only the managed Gateway proxy Deployment. |

## Recovery

Find the proxy Deployment owned by the shared Gateway:

```bash
GATEWAY_PROXY_DEPLOYMENT="$({
  kubectl get deployment -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
    -o jsonpath='{.items[0].metadata.name}'
} 2>/dev/null)"

test -n "${GATEWAY_PROXY_DEPLOYMENT}"
echo "Restarting ${GATEWAY_PROXY_DEPLOYMENT}"
```

Restart and wait for the replacement proxy Pod:

```bash
kubectl rollout restart deployment "${GATEWAY_PROXY_DEPLOYMENT}" \
  -n envoy-gateway-system

kubectl rollout status deployment "${GATEWAY_PROXY_DEPLOYMENT}" \
  -n envoy-gateway-system --timeout=3m
```

Then repeat the public request and inspect the new proxy Pod:

```bash
curl -sS -i --max-time 10 \
  -H "Host: ${STAGING_HOST}" \
  "http://${GATEWAY_IP}/"

kubectl get pods -n envoy-gateway-system -o wide
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway \
  -c envoy --since=5m | grep -Ei '503|reset|connection'
```

Do not restart application Pods as the first response when their endpoints and
direct Service request are healthy. Do not restart the Envoy Gateway controller
unless its own health or reconciliation logs show a controller problem.

## Argo CD Checks

An Argo CD Application with this annotation is intentionally excluded from
reconciliation:

```text
argocd.argoproj.io/skip-reconcile: "true"
```

If a manual sync remains at `waiting to start`, check the annotation:

```bash
kubectl get application helm-staging-frontend -n argocd \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}{"\n"}'
```

Remove it only when reconciliation is not intentionally paused, and remove the
same setting from the GitOps source so it does not return:

```bash
kubectl annotate application helm-staging-frontend -n argocd \
  argocd.argoproj.io/skip-reconcile- --overwrite
```

`Synced` describes the Git revision. `Progressing` describes the workload
health. A successful Argo CD sync does not prove that the external Gateway
request can pass through Istio Ambient networking.

## Alerting Plan

The current observability stack already has Prometheus, Blackbox Exporter, and
Envoy proxy metrics. Alertmanager is currently disabled in
`8_Observability-Stack/metrics/prometheus-values.yaml`, so alerts are not yet
sent to a notification receiver.

### 1. Blackbox Availability Alert

The current Alloy Blackbox discovery uses Service annotations and produces
`probe_success`. For a service discovered by the current configuration, add a
rule such as:

```promql
probe_success{
  job="blackbox-staging",
  namespace="staging",
  service="frontend"
} == 0
```

Use `for: 2m` to avoid alerting on one failed probe. The `frontend` Service
must have the Blackbox annotations used by the Alloy configuration:

```yaml
service:
  annotations:
    blackbox.prometheus.io/scrape: "true"
    blackbox.prometheus.io/path: "/"
    blackbox.prometheus.io/port: "3000"
    blackbox.prometheus.io/module: "http_2xx"
```

This existing discovery checks the Service from inside the cluster. It does
not test the public Gateway hostname. Add a separate external or synthetic
Blackbox target later if the alert must represent the exact user-facing URL.

### 2. Envoy Upstream 5xx Alert

This catches HTTP failures observed by the Gateway. It requires request traffic
to exist, which is why it should be used together with the Blackbox alert:

```promql
sum by (envoy_cluster_name) (
  rate(envoy_cluster_external_upstream_rq{
    envoy_cluster_name=~"httproute/staging/.*",
    envoy_response_code=~"5.."
  }[5m])
) > 0
```

### 3. Envoy Upstream Connection Failure Alert

This is the closest metric signal to the reported connection reset:

```promql
sum by (envoy_cluster_name) (
  increase(envoy_cluster_upstream_cx_connect_fail{
    envoy_cluster_name=~"httproute/staging/.*"
  }[5m])
) > 0
```

Use a short `for`, such as `1m`, and label it `severity: warning` or
`severity: critical` according to the production policy.

The exact ztunnel and Istio CNI messages are currently log signals. Prometheus
cannot evaluate raw Kubernetes logs by itself. The alerts above detect the
user-visible impact; the ztunnel and CNI log checks in this runbook identify
the stale Ambient redirect as the likely cause.

## Future Prometheus and Alertmanager Configuration

When notification delivery is ready, enable the Alertmanager subchart and keep
its state on a dedicated PVC. Merge the following into the existing
`8_Observability-Stack/metrics/prometheus-values.yaml`:

```yaml
alertmanager:
  enabled: true
  persistence:
    enabled: true
    storageClass: longhorn-storageclass
    size: 2Gi
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: homelab-default
      group_by:
        - alertname
        - namespace
        - service
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
    receivers:
      - name: homelab-default
        # Configure one real receiver here, for example webhook_configs or
        # email_configs. Keep tokens and passwords in a Kubernetes Secret.
        webhook_configs:
          - url: https://alert-receiver.example.invalid/hooks/homelab
```

Add the rules to the existing Prometheus server values. The chart renders
`serverFiles.alerting_rules.yml` as the Prometheus alerting rules file:

```yaml
serverFiles:
  alerting_rules.yml:
    groups:
      - name: homelab-gateway
        rules:
          - alert: HomelabStagingFrontendUnavailable
            expr: |
              probe_success{
                job="blackbox-staging",
                namespace="staging",
                service="frontend"
              } == 0
            for: 2m
            labels:
              severity: critical
              environment: staging
              service: frontend
            annotations:
              summary: "Staging frontend is unavailable"
              description: >-
                Blackbox checks have failed for the staging frontend for more
                than two minutes.

          - alert: HomelabStagingEnvoyUpstream5xx
            expr: |
              sum by (envoy_cluster_name) (
                rate(envoy_cluster_external_upstream_rq{
                  envoy_cluster_name=~"httproute/staging/.*",
                  envoy_response_code=~"5.."
                }[5m])
              ) > 0
            for: 2m
            labels:
              severity: warning
              environment: staging
            annotations:
              summary: "Envoy is returning upstream 5xx responses"
              description: >-
                The staging Gateway has observed upstream 5xx responses for
                the affected Envoy cluster.

          - alert: HomelabStagingEnvoyConnectFailure
            expr: |
              sum by (envoy_cluster_name) (
                increase(envoy_cluster_upstream_cx_connect_fail{
                  envoy_cluster_name=~"httproute/staging/.*"
                }[5m])
              ) > 0
            for: 1m
            labels:
              severity: critical
              environment: staging
            annotations:
              summary: "Envoy cannot connect to a staging upstream"
              description: >-
                Envoy upstream connection failures were observed. Check
                application endpoints, ztunnel policy rejection, and Istio CNI
                Ambient redirect reconciliation.
```

Apply and verify the future configuration:

```bash
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace observability \
  --values 8_Observability-Stack/metrics/prometheus-values.yaml \
  --timeout 10m \
  --wait

kubectl get pods -n observability | grep -Ei 'prometheus|alertmanager'
kubectl get svc -n observability | grep -i alertmanager
```

Validate the rendered Prometheus rules before relying on notifications:

```bash
helm template prometheus prometheus-community/prometheus \
  --namespace observability \
  --values 8_Observability-Stack/metrics/prometheus-values.yaml \
  > /tmp/prometheus-rendered.yaml

kubectl apply --dry-run=client -f /tmp/prometheus-rendered.yaml
```

Then check the Prometheus **Alerts** page and the Alertmanager **Alerts** page.
Create one controlled test failure, confirm that the alert becomes `firing`,
and restore the endpoint to verify the resolved notification as well.

## Prevention

- Keep Istio CNI and ztunnel healthy after node maintenance.
- After a node or CNI restart, check existing Gateway proxy Pods for CNI netns
  reconciliation errors.
- Treat Envoy `503` and upstream connection failures as alertable conditions,
  not only log-search events.
- Keep public-route probing separate from internal Service probing when the
  external Gateway path is part of the availability objective.
- Keep the Gateway proxy restart scoped to the affected managed Deployment.
