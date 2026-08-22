# Istio Ambient

The application namespaces use Ambient mode and STRICT mTLS. There is no
one-waypoint-per-namespace restriction: a namespace can contain multiple
waypoint Gateways, and Services select one with the `istio.io/use-waypoint`
label.

This homelab intentionally uses four service-scoped waypoint deployments:

| Namespace | Service | Waypoint |
|---|---|---|
| staging | todo-service | todo-service-waypoint |
| staging | user-service | user-service-waypoint |
| production | todo-service | todo-service-waypoint |
| production | user-service | user-service-waypoint |

The `--for service` argument means that a waypoint accepts Service-addressed
traffic. The Service label determines which specific workload uses it.

Istio and generated waypoint pods include `prometheus.io/scrape: "true"`
annotations, so Alloy's generic Pod Discovery finds them without a dedicated
Istio scrape block.

Follow [install-istio.md](./install-istio.md).
