# Grafana Pyroscope

Pyroscope stores continuous CPU profiles and renders flame graphs. The two
Python backend services send profiles to the existing Alloy Service on port
`4040`; Alloy forwards them to the Pyroscope backend. Grafana queries the same
backend through its provisioned Pyroscope datasource.

This homelab uses one Pyroscope replica with v2 storage on an explicitly
created 2 Gi Longhorn PVC. It is persistent but not highly available. Profile
retention must be monitored because 2 Gi is intentionally small.

The Pyroscope chart normally deploys its own Alloy collector. It is disabled
in `pyroscope-values.yaml` because the cluster already has an Alloy DaemonSet.

## Install

The `observability` namespace and `longhorn-storageclass` must already exist.
Run these commands from the repository root:

```bash
kubectl apply -f 8_Observability-Stack/profiling/pyroscope-pvc.yaml

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

helm upgrade --install pyroscope grafana/pyroscope \
  --version 2.2.1 \
  --namespace observability \
  --values 8_Observability-Stack/profiling/pyroscope-values.yaml \
  --wait

kubectl apply -f 8_Observability-Stack/profiling/pyroscope-httproute.yaml
```

Apply the profile receiver and upgrade the existing Alloy release so its
Service exposes port `4040` and the projected profile configuration is mounted:

```bash
kubectl apply -f 8_Observability-Stack/profiling/alloy-profiles-config.yaml

helm upgrade --install alloy grafana/alloy \
  --namespace observability \
  --values 8_Observability-Stack/alloy-values.yaml \
  --wait
```

Upgrade Grafana after adding the Pyroscope datasource to `grafana-values.yaml`:

```bash
helm upgrade --install grafana grafana-community/grafana \
  --namespace observability \
  --values 8_Observability-Stack/grafana-values.yaml \
  --wait
```

Pyroscope UI: <http://pyroscope.192.168.0.110.nip.io>

## Verify

```bash
kubectl get pod,pvc,service,httproute -n observability
kubectl logs -n observability daemonset/alloy --tail=100
kubectl logs -n observability statefulset/pyroscope --tail=100
```

After deploying an instrumented service, open **Grafana → Explore**, select the
`Pyroscope` datasource and choose an application such as `todo-service`.

The `pyroscope-otel` span processor attaches profile correlation attributes to
OpenTelemetry spans. Those attributes are retained in Jaeger, but Grafana's
native **Profiles for span** navigation is built around a compatible trace
datasource such as Tempo. With the current Jaeger UI, use the shared service,
pod, trace attributes and time range for correlation; installing Pyroscope does
not by itself add a one-click Jaeger-to-profile link.

If the Uvicorn command is later replaced by a pre-fork server such as Gunicorn,
initialize the Pyroscope SDK after the final worker fork. The current container
runs one Uvicorn process, so module-level initialization is appropriate.

## References

- [Deploy Pyroscope with Helm](https://grafana.com/docs/pyroscope/latest/deploy-kubernetes/helm/)
- [Python SDK](https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/python/)
- [Python span profiles](https://grafana.com/docs/pyroscope/latest/configure-client/trace-span-profiles/python-span-profiles/)
- [Alloy `pyroscope.receive_http`](https://grafana.com/docs/alloy/latest/reference/components/pyroscope/pyroscope.receive_http/)
