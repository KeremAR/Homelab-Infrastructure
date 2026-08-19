# Future AIOps Improvements

This document describes possible future improvements for the observability system.

The goal is to use AIOps ideas without depending on a large AI model. Most of these steps can be done with metrics, logs, traces, rules, statistics, and automation.

## 1. Connect Telemetry Data

Before using AIOps methods, metrics, logs, and traces should be connected to each other.

All telemetry should use common labels when possible.

Example:

```text
service.name = payment-service
namespace = production
cluster = homelab
pod = payment-service-abc123
```

Logs should also contain useful fields such as `trace_id`.

Example:

```json
{
  "service": "payment-service",
  "trace_id": "06f8a123",
  "level": "error",
  "message": "database timeout"
}
```

This makes it possible to move between metrics, logs, and traces for the same request or service.

Example flow:

```text
Metric
Payment latency is high
        |
        v
Trace
One request took 4.2 seconds
        |
        v
Log
The same trace_id has a database timeout
```

This should be the first step because all later correlation depends on good telemetry.

---

## 2. Alert Grouping

The next step is to reduce alert noise.

Many alerts can be caused by the same problem.

Example:

```text
NodeDown
PodDown
ExporterDown
ContainerUnreachable
```

If all of them are caused by one failed node, the engineer should not receive many separate notifications.

Alertmanager grouping can combine related alerts into one notification.

Example:

```text
worker-3 is down

Affected:
- payment-service pod
- checkout-service pod
- node-exporter
```

This makes alerts easier to understand.

Alert inhibition can also hide lower-level alerts when a higher-level alert already explains the problem.

Example:

```text
NodeDown
   |
   +--> PodDown
   +--> ExporterDown
   +--> ContainerUnreachable
```

When `NodeDown` is active, the other alerts may not need separate notifications.

---

## 3. Alert Correlation

After grouping alerts, the system can try to understand which alerts belong to the same incident.

Example:

```text
Payment memory high
Payment latency high
Database connection timeout
Checkout 5xx errors
Load balancer errors
```

Instead of treating them as five different incidents, the system can create one situation.

Example:

```text
Incident: Payment service degradation

Possible root cause:
Payment service memory problem

Affected services:
- payment-service
- checkout-service
- user-dashboard
```

Correlation can use information such as:

- Time of the alerts
- Service name
- Namespace
- Node
- Kubernetes relationships
- Service dependencies
- Recent deployments
- Similar past incidents

The goal is to change many low-level alerts into one useful incident.

---

## 4. Anomaly Detection

Static thresholds are useful, but they are not always enough.

Example:

```text
Alert when CPU > 80%
```

A service may normally use only 20% CPU. If it suddenly uses 55%, this can already be unusual even if it is still below 80%.

The system can compare the current value with its normal historical behavior.

Example:

```text
Normal CPU:
20% to 30%

Current CPU:
55%
```

This can be treated as an anomaly.

Simple statistical methods can be used for this.

For example:

- Historical average
- Standard deviation
- Moving average
- Rate of change

This does not require a large AI model.

The goal is to detect unusual behavior before a normal threshold is reached.

---

## 5. Predictive Alerting

Normal alerts are usually reactive.

Example:

```text
Disk free space < 10%
```

The problem is already close when this alert fires.

Predictive alerting tries to detect a future problem before it happens.

Example:

```text
Current disk free space: 25 GB

Recent trend:
25 GB
20 GB
15 GB
10 GB
```

The system can calculate that the disk may become full in a few hours.

Then it can send an alert such as:

```text
Warning: Disk is predicted to become full in 4 hours.
```

Prometheus can already do simple prediction with functions such as `predict_linear()`.

Example:

```promql
predict_linear(
  node_filesystem_avail_bytes{mountpoint="/"}[6h],
  4 * 3600
) < 0
```

This means:

- Look at the last 6 hours.
- Find the current trend.
- Predict the value 4 hours into the future.
- Alert if the predicted free space is below zero.

---

## 6. Time-Series Forecasting

Predictive alerting can be extended with time-series forecasting.

The idea is to use historical data to estimate future resource usage.

Possible examples:

- Disk usage
- Memory usage
- Database size
- Request rate
- CPU usage
- Network traffic
- Storage growth

Example:

```text
Database size:

Monday    300 GB
Tuesday   310 GB
Wednesday 322 GB
Thursday  335 GB
```

The system can estimate when the database may reach a capacity limit.

Example result:

```text
Predicted capacity limit:
12 days

Recommended action:
Increase storage before the limit is reached.
```

In the beginning, simple methods such as linear regression are enough.

More complex machine learning is not required.

---

## 7. Service Topology and Dependency Correlation

Traces can be used to understand service dependencies.

Example:

```text
frontend
   |
   v
gateway
   |
   v
checkout
   |
   v
payment
   |
   v
postgresql
```

If errors start in several services at the same time, the dependency graph can help find the possible source.

Example:

```text
frontend errors
checkout errors
payment errors
```

If `payment` is below the other services in the dependency chain, it can be a better root-cause candidate.

This can help separate:

```text
Root cause
```

from:

```text
Affected service
```

---

## 8. Correlate Incidents with Deployments and Changes

System problems often start after a change.

Deployment and configuration events should be connected with observability data.

Example:

```text
14:00 payment-service v2.7 deployed
14:03 error rate increased
14:04 latency increased
14:05 pods started restarting
14:07 checkout errors increased
```

The incident could then show:

```text
Service:
payment-service

Error rate:
2% -> 31%

Latency:
120 ms -> 2.8 s

Recent change:
payment-service v2.6 -> v2.7
7 minutes ago
```

This can reduce investigation time because engineers can quickly see if a recent change may be related to the incident.

---

## 9. Automated Remediation

After detection and correlation are reliable, some incidents can be connected to automated actions.

The first option should be human-controlled.

Example:

```text
Incident detected
        |
        v
Known runbook?
   |         |
   No       Yes
   |         |
   v         v
Engineer   Suggest action
```

For known and safe problems, the system can later run the action automatically.

Example:

```text
Incident detected
        |
        v
Known runbook?
   |         |
   No       Yes
   |         |
   v         v
Engineer   Check confidence
               |
          +----+----+
          |         |
        Low        High
          |         |
          v         v
      Engineer   Auto-remediate
```

Possible safe actions:

- Restart one stateless pod
- Restart a deployment
- Increase replicas
- Clear a safe cache
- Run a known recovery script

High-risk actions should still require an engineer.

Examples:

- Database restart
- Delete PersistentVolume data
- Change network routes
- Delete important resources

The goal is not to automate everything. The goal is to automate only known, repeatable, and safe recovery actions.

---

## 10. AI-Assisted Root Cause Analysis

AI can be added as the last step.

This is optional.

The observability system should first collect and correlate the important data.

Example incident context:

```text
Service: payment-service

Signals:
- Memory usage is increasing
- HTTP 5xx errors are increasing
- Pod restarted 4 times
- PostgreSQL connection usage is high
- New deployment happened 12 minutes ago

Related logs:
- OutOfMemory warning
- Database timeout

Affected services:
- checkout-service
- frontend
```

This context can be sent to an AI model.

The question can be:

```text
What is the most likely root cause?
What should the engineer check first?
```

The AI can return something like:

```text
Possible root cause:
The new payment-service deployment may have introduced a memory problem.

Recommended checks:
1. Compare the new version with the previous version.
2. Check heap and memory usage.
3. Check recent application errors.
4. Consider rollback if the problem started after deployment.
```

The AI should not receive raw, unfiltered monitoring data if it is not needed.

It is better to first prepare a small incident summary with:

- Important metrics
- Important logs
- Important traces
- Recent deployments
- Dependency information
- Related alerts

Then the AI can help with root-cause analysis.

The AI should be treated as an assistant, not as the final source of truth.

---

## Suggested Implementation Order

A practical order for this project is:

1. Connect metrics, logs, and traces.
2. Add common service labels and `trace_id`.
3. Improve Alertmanager grouping.
4. Add alert inhibition rules.
5. Add alert correlation.
6. Add anomaly detection.
7. Add predictive alerts.
8. Add time-series forecasting.
9. Use traces for service topology.
10. Correlate incidents with deployments and configuration changes.
11. Add runbook-based remediation.
12. Allow automatic remediation only for known cases with high confidence.
13. Add AI-assisted root-cause analysis as the final optional layer.

## Final Goal

The final system should move from this:

```text
Alert
  |
  v
Engineer investigates
  |
  v
Engineer finds the problem
  |
  v
Engineer fixes the problem
```

to this:

```text
Metrics + Logs + Traces
          |
          v
   Anomaly Detection
          |
          v
   Alert Correlation
          |
          v
    Prediction
          |
          v
   Incident Summary
          |
          v
Possible Root Cause
          |
          v
 Runbook / Engineer / AI
          |
          v
     Remediation
```

The main idea is to make the observability system more proactive.

It should not only say:

```text
Something is broken.
```

It should try to say:

```text
These alerts are related.

This service may be the root cause.

This problem may become critical soon.

This runbook may fix it.
```

A large AI model is not required for most of this design. AI can be added later as an optional layer for root-cause analysis and incident explanation.
