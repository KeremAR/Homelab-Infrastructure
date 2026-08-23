# Official component dashboards

These dashboards are vendored from the component releases installed by this
repository, rather than from their moving `main` branches:

- Istio `1.30.3`: `istio/istio`, `manifests/addons/dashboards`
- Cilium `v1.20.1`: `cilium/cilium`, `install/kubernetes/cilium/files/*/dashboards`
- Envoy Gateway `v1.9.0`: `envoyproxy/gateway`,
  `charts/gateway-addons-helm/dashboards`

Each directory uses a Kustomize `configMapGenerator`. The generated ConfigMap
has the `grafana_dashboard: "1"` label consumed by the existing Grafana
dashboard sidecar and a `grafana_folder` annotation that keeps the dashboards
grouped by component.

Apply these directories with `kubectl apply --server-side -k`. Ordinary
client-side apply copies the full generated ConfigMap into a
`last-applied-configuration` annotation, which exceeds the 256 KiB annotation
limit for the larger dashboard bundles.

The Envoy Gateway JSON contains a few upstream references to the dashboard
author's Prometheus UID. They are changed to this repository's fixed
`prometheus` datasource UID. No Prometheus or Grafana backend is installed by
these manifests.

Cilium's upstream dashboards use the `${DS_PROMETHEUS}` import placeholder.
Grafana resolves that placeholder during an interactive UI import, but not
when the dashboard sidecar provisions raw JSON from ConfigMaps. The vendored
Cilium dashboards therefore use this repository's fixed `prometheus` UID
directly.

Istio's upstream JSON uses the equivalent `$datasource` import placeholder and
ships service/workload variables preselected for the Bookinfo sample. Those
references are changed to the fixed `prometheus` UID, the sample selections are
cleared, and `waypoint` is added as the default reporter so the dashboards can
query this cluster's ambient-mode L7 telemetry. `source` and `destination`
remain available for classic/TCP views.

The Cilium L7 HTTP dashboard is intentionally omitted. This cluster disables
Cilium's L7 proxy and gives L7 ownership to Istio waypoints, so the dashboard's
`hubble_http_*` queries would have no data. Hubble DNS and network namespace
dashboards are included because the Cilium values enable their required
`source_namespace` and `destination_namespace` metric labels.
