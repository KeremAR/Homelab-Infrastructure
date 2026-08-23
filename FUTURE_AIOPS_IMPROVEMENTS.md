# Future AIOps Improvements

This document describes possible future improvements for the observability system.

The goal is to use AIOps ideas without depending on a large AI model at the beginning. Most of the first steps can be done with metrics, logs, traces, rules, statistics, and automation.

AI can be added later as an optional incident triage and root-cause analysis layer.

---

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

Possible sources:

- ArgoCD application history
- Git commit history
- Kubernetes events
- ConfigMap changes
- Secret changes
- Helm changes
- Terraform changes

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

The system should not directly say that the deployment is the root cause.

It can mark it as a suspicious recent change.

This can reduce investigation time because engineers can quickly see if a recent change may be related to the incident.

---

## 9. Create an Incident Context

Before using an AI model, the system should prepare a useful incident context.

The system should collect only the important information.

Possible incident context:

```text
Service:
payment-service

Alert:
HTTP 5xx > 20%

Metrics:
- Memory usage is increasing
- p95 latency increased from 120 ms to 2.8 s
- Pod restarted 4 times

Logs:
- connection pool exhausted
- database timeout

Traces:
checkout -> payment -> postgresql
PostgreSQL span latency: 4.1 s

Recent changes:
payment-service v2.7 deployed 8 minutes ago

Affected services:
- checkout-service
- frontend
```

This is more useful than sending all raw metrics, logs, and traces to an AI model.

It also reduces noise and makes root-cause analysis easier.

---

## 10. Search Similar Past Incidents

Past incidents can help with new incidents.

Each completed incident can be stored with information such as:

- Service
- Alerts
- Important log messages
- Root cause
- Fix
- Deployment information
- Runbook
- Final incident report

Example:

```text
Incident #182

Service:
payment-service

Error:
connection pool exhausted

Root cause:
max_connections was configured incorrectly

Resolution:
rollback ConfigMap
```

Later, if a similar incident happens, the system can search old incidents.

Example:

```text
Current incident:
payment-service
connection pool exhausted

Similar incident:
Incident #182
```

In the future, this can use a vector database and RAG.

Possible tools:

- pgvector
- Qdrant
- Weaviate

The goal is not to let AI guess from nothing.

The goal is to give AI useful information from real past incidents.

---

## 11. Automated Remediation

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
- Change a temporary log level
- Run a known recovery script

High-risk actions should still require an engineer.

Examples:

- Database restart
- Delete PersistentVolume data
- Change IAM permissions
- Change network routes
- Production scale-down
- Delete important resources

The goal is not to automate everything.

The goal is to automate only known, repeatable, low-risk, and reversible recovery actions.

---

## 12. Add Guardrails

An agent or automation should never have unlimited access.

Each automated action should pass through a guardrail layer.

Example allow-list:

```text
Allowed:
- restart stateless pod
- restart selected deployment
- scale replicas up
- clear approved cache
- run approved script

Not allowed:
- delete database
- delete PersistentVolume
- change IAM policy
- change production network route
```

The automation should not be able to run actions outside this list.

For critical actions, use human approval.

Example:

```text
Agent suggests action
        |
        v
System checks policy
        |
        v
Engineer approves
        |
        v
Action runs
```

Policy-as-code tools such as OPA or Kyverno can also be used as part of this validation layer.

---

## 13. Add Audit Trail and Dry-Run Mode

Every automated decision should be visible and recorded.

The system should log:

- What incident started the action
- What data was used
- What action was suggested
- Why the action was suggested
- Whether a human approved it
- What command or API call was executed
- What happened after the action

New automation should first run in dry-run or recommendation-only mode.

Example:

```text
Week 1-2:
Detect and recommend only

Week 3-4:
Compare recommendations with engineer decisions

Later:
Enable automation for safe cases
```

This helps build confidence before giving the system more control.

---

## 14. AI Agent for Incident Triage

AI should be added after the basic observability and correlation layers are working.

The AI agent should not replace Prometheus, Loki, Tempo, or Alertmanager.

It should work above them.

Example architecture:

```text
                   Alert
                     |
                     v
                 AI Agent
                     |
       +-------------+-------------+
       |             |             |
       v             v             v
  Prometheus        Loki          Tempo
       |
       +------ Kubernetes API
       |
       +------ ArgoCD history
       |
       +------ Git history
       |
       +------ Incident database
       |
       v
              Incident Context
                     |
                     v
                    LLM
                     |
                     v
            Possible Root Cause
            Suggested Actions
                     |
              +------+------+
              |             |
              v             v
           Engineer      Runbook
```

The agent can collect the information that an engineer normally collects manually.

For example:

- Related metrics
- Important logs
- Related traces
- Kubernetes events
- Recent deployments
- Recent Git changes
- Similar old incidents

The agent then creates one clear incident summary.

At this stage, the agent should mainly help with triage.

It should collect context and make suggestions.

The final decision should still be made by an engineer for risky cases.

---

## 15. AI-Assisted Root Cause Analysis

After the incident context is ready, it can be sent to an AI model.

Example input:

```text
Service:
payment-service

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

Similar old incident:
ConfigMap changed database pool settings incorrectly
```

Possible questions:

```text
What is the most likely root cause?
What should the engineer check first?
Which recent change is suspicious?
Is there a similar past incident?
```

The AI can return something like:

```text
Possible root cause:
The new payment-service deployment may have introduced an incorrect database connection pool configuration.

Recommended checks:
1. Compare the new configuration with the previous version.
2. Check the database connection pool settings.
3. Check memory usage after the deployment.
4. Consider rollback if the incident started after this change.
```

The AI should be treated as an assistant, not as the final source of truth.

---

## 16. RAG for Better RCA

RAG can improve AI-assisted RCA.

The AI should not only use the current incident.

It can also receive useful information from:

- Previous incidents
- Runbooks
- Post-mortems
- Architecture documents
- Known problems
- Service documentation

Example:

```text
Current incident
       +
Similar old incident
       +
Relevant runbook
       +
Service documentation
       |
       v
      LLM
       |
       v
Better RCA suggestion
```

A vector database can be used to search this information.

This should be added later because it requires an embedding model and more AI infrastructure.

---

## 17. MCP as a Future Integration Layer

In the future, MCP can be used to give AI agents standard access to tools.

Without a standard layer:

```text
Agent
 |- custom Prometheus integration
 |- custom Kubernetes integration
 |- custom Git integration
 |- custom ArgoCD integration
```

With MCP:

```text
               Agent
                 |
                 v
                MCP
       +---------+---------+
       |         |         |
       v         v         v
  Prometheus   Kubernetes  Git
```

Possible tools that could later be exposed through MCP:

- Kubernetes API
- Prometheus
- Loki
- Tempo
- ArgoCD
- Git repositories
- Terraform information

This is not required for the first version.

It is a possible future standard integration layer for AI agents.

---

## 18. Suggested Implementation Order

A practical order for this project is:

1. Connect metrics, logs, and traces.
2. Add common service labels and `trace_id`.
3. Improve Alertmanager grouping.
4. Add Alertmanager inhibition rules.
5. Add alert correlation.
6. Add anomaly detection.
7. Add predictive alerts.
8. Add time-series forecasting.
9. Use traces for service topology.
10. Correlate incidents with deployments and configuration changes.
11. Create one structured incident context.
12. Store completed incidents and their root causes.
13. Add runbook-based remediation.
14. Add guardrails and an allowed-action list.
15. Add audit logs for every automated action.
16. Run new automation in dry-run mode first.
17. Allow automatic remediation only for known, low-risk cases with high confidence.
18. Add an AI agent for incident triage.
19. Add AI-assisted root-cause analysis.
20. Add RAG with old incidents and runbooks.
21. Consider MCP for standard agent-to-tool integrations.

---

## Final Architecture

The long-term architecture can look like this:

```text
                         Applications
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
         Prometheus          Loki            Tempo
           Metrics           Logs            Traces
              |               |               |
              +-------+-------+-------+-------+
                      |               |
                      v               v
                 Detection        Topology
                      |
          +-----------+-----------+
          |           |           |
          v           v           v
      Alerts      Anomalies   Predictions
          |
          v
     Alertmanager
          |
     Group / Inhibit
          |
          v
       Incident
          |
          v
    Incident Context
          |
   +------+------+----------------+
   |             |                |
   v             v                v
Metrics/Logs   Changes       Past Incidents
/Traces       ArgoCD/Git       RAG/Search
   |             |                |
   +-------------+----------------+
                 |
                 v
              AI Agent
                 |
                 v
        Possible Root Cause
        + Suggested Actions
                 |
          +------+------+
          |             |
          v             v
       Engineer      Runbook
                        |
                   Guardrails
                        |
                 High confidence?
                        |
                   +----+----+
                   |         |
                  No        Yes
                   |         |
                   v         v
                Engineer   Execute
```

---

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
 Deployment / Change Correlation
          |
          v
   Incident Context
          |
          v
 Similar Past Incidents
          |
          v
 AI-Assisted RCA
          |
          v
 Runbook / Engineer
          |
          v
 Guardrails
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

This recent deployment may be related.

A similar incident happened before.

This problem may become critical soon.

This runbook may fix it.
```

A large AI model is not required for most of this design.

The first parts can be built with Prometheus, Alertmanager, Loki, Tempo, rules, statistics, and normal automation.

AI can be added later as an optional incident triage and root-cause analysis layer.
