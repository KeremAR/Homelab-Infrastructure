# Longhorn Disk Pressure And Replica Move Runbook

This runbook explains how to investigate Longhorn disk pressure, identify which
volumes consume space on each node, compare Longhorn usage with container image
cache, and safely move a single-replica volume to another node.

Example incident:

```text
Longhorn node disk schedulable = false
reason = DiskPressure
detached/faulted volumes still consume node disk space
a single-replica volume cannot attach, so the workload cannot start
```

A detached Longhorn volume is not deleted. It is only not attached to a workload.
Its replica data directory still exists under the Longhorn disk path and still
consumes disk space.

---

## 1. Collect Longhorn Volume Data

Collect Longhorn volumes, replicas, and PVCs:

```bash
kubectl get volumes.longhorn.io -n longhorn-system -o json > /tmp/lh-volumes.json
kubectl get replicas.longhorn.io -n longhorn-system -o json > /tmp/lh-replicas.json
kubectl get pvc -A -o json > /tmp/pvcs.json
```

---

## 2. Print A Node-Based Volume Report

Use this command when you want a readable report grouped by node:

```bash
jq -r '
  def gi2: (((. / 1024 / 1024 / 1024) * 100 | floor) / 100 | tostring + "Gi");
  ($vols[0].items
    | map({
        key: .metadata.name,
        ns: (.status.kubernetesStatus.namespace // "-"),
        pvc: (.status.kubernetesStatus.pvcName // "-"),
        workload: (.status.kubernetesStatus.workloadsStatus[0].podName // "-"),
        size: (.spec.size | tonumber),
        actual: ((.status.actualSize // "0") | tonumber),
        state: (.status.state // "-"),
        robustness: (.status.robustness // "-")
      })
    | INDEX(.key)
  ) as $vmap |
  [
    $reps[0].items[] |
    .spec.volumeName as $vol |
    ($vmap[$vol] // {}) as $v |
    {
      node: (.spec.nodeID // "-"),
      pvc: (($v.ns // "-") + "/" + ($v.pvc // "-")),
      scheduled: (($v.size // 0) | gi2),
      actual: (($v.actual // 0) | gi2),
      state: (($v.state // "-") + "/" + (.status.currentState // "-")),
      robustness: ($v.robustness // "-")
    }
  ] |
  group_by(.node)[] |
  "\(.[0].node)\nvolume/PVC\tscheduled\tactual\tstate",
  (.[] |
    [
      .pvc,
      .scheduled,
      .actual,
      (.state + "/" + .robustness)
    ] | @tsv
  ),
  ""
' \
  --slurpfile vols /tmp/lh-volumes.json \
  --slurpfile reps /tmp/lh-replicas.json \
  /tmp/lh-volumes.json | column -t -s $'\t'
```

Example shape:

```text
homelab-workers-pve2-dk699-g9fc8
volume/PVC                                  scheduled   actual    state
production/postgres-storage-user-db-0       2Gi         0.14Gi    attached/running/healthy
observability/prometheus-data               2Gi         0.33Gi    attached/running/healthy
jenkins/jenkins-docker-cache-frontend-pvc   5Gi         0.59Gi    detached/stopped/unknown
sonarqube/sonarqube-postgresql-pvc          2Gi         0.28Gi    attached/running/healthy
sonarqube/sonarqube-data-pvc                5Gi         0.86Gi    attached/running/healthy
jenkins/jenkins-venv-cache-pvc              2Gi         0.14Gi    detached/stopped/unknown
```

The workload/pod name shown in the Longhorn UI can look like a branch-specific
Jenkins pod. That does not mean the volume belongs to that branch. It usually
means "this was the last workload that used the volume." Use the PVC name to
understand what the volume really is.

---

## 3. Compare Scheduled Size, Actual Size, And Node Disk

Longhorn scheduled and actual size per node:

```bash
jq -r '
  def gi2: (((. / 1024 / 1024 / 1024) * 100 | floor) / 100 | tostring + "Gi");
  ($vols[0].items
    | map({
        key: .metadata.name,
        size: (.spec.size | tonumber),
        actual: ((.status.actualSize // "0") | tonumber)
      })
    | INDEX(.key)
  ) as $vmap |
  [
    $reps[0].items[] |
    .spec.nodeID as $node |
    .spec.volumeName as $vol |
    ($vmap[$vol] // {}) as $v |
    {
      node: $node,
      size: ($v.size // 0),
      actual: ($v.actual // 0)
    }
  ] |
  "node\tlonghorn scheduled\tlonghorn actual",
  (
    group_by(.node)[] |
    [
      .[0].node,
      (map(.size) | add | gi2),
      (map(.actual) | add | gi2)
    ] | @tsv
  )
' \
  --slurpfile vols /tmp/lh-volumes.json \
  --slurpfile reps /tmp/lh-replicas.json \
  /tmp/lh-volumes.json | column -t -s $'\t'
```

Longhorn disk schedulable status:

```bash
kubectl get nodes.longhorn.io -n longhorn-system -o json | jq -r '
  def gi2: (((. / 1024 / 1024 / 1024) * 100 | floor) / 100 | tostring + "Gi");
  "node\tdisk path\tscheduled\tavailable\tmaximum\tschedulable\treason",
  (
    .items[] |
    .metadata.name as $node |
    .status.diskStatus |
    to_entries[]? |
    .value as $d |
    [
      $node,
      ($d.diskPath // "-"),
      (($d.storageScheduled // 0) | gi2),
      (($d.storageAvailable // 0) | gi2),
      (($d.storageMaximum // 0) | gi2),
      (($d.conditions[]? | select(.type == "Schedulable") | .status) // "-"),
      (($d.conditions[]? | select(.type == "Schedulable") | .reason) // "-")
    ] | @tsv
  )
' | column -t -s $'\t'
```

Important distinction:

```text
Kubernetes node DiskPressure != Longhorn disk schedulable state
```

Longhorn uses its own `storage-minimal-available-percentage` setting to decide
whether it can schedule new replicas on a disk.

Check the setting:

```bash
kubectl get settings.longhorn.io -n longhorn-system \
  storage-minimal-available-percentage -o yaml
```

---

## 4. Compare Longhorn Usage With Container Image Cache

Kubelet node filesystem and image filesystem usage:

```bash
{
  printf "node\tnode fs used\tnode fs capacity\timage fs used\timage fs capacity\n"
  for node in $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    kubectl get --raw /api/v1/nodes/${node}/proxy/stats/summary | jq -r --arg node "$node" '
      def gi2: (((. / 1024 / 1024 / 1024) * 100 | floor) / 100 | tostring + "Gi");
      [
        $node,
        (.node.fs.usedBytes | gi2),
        (.node.fs.capacityBytes | gi2),
        (.node.runtime.imageFs.usedBytes | gi2),
        (.node.runtime.imageFs.capacityBytes | gi2)
      ] | @tsv
    '
  done
} | column -t -s $'\t'
```

Large images per node:

```bash
kubectl get nodes -o json | jq -r '
  [
    .items[] |
    .metadata.name as $node |
    .status.images[]? |
    {
      node: $node,
      sizeMi: (.sizeBytes / 1024 / 1024 | floor),
      names: (.names | join(","))
    }
  ] |
  group_by(.node)[] |
  sort_by(.sizeMi) | reverse |
  "\(.[0].node)\nsize\timage",
  (.[:30][] | [(.sizeMi | tostring + "Mi"), .names] | @tsv),
  ""
' | column -t -s $'\t'
```

Large images that exist on only one node:

```bash
kubectl get nodes -o json | jq -r '
  .items as $nodes |
  [
    $nodes[] |
    {
      node: .metadata.name,
      images: (.status.images // [])
    }
  ] as $rows |
  [
    $rows[] as $r |
    $r.images[]? |
    {
      name: (.names[0] // "<none>"),
      size: .sizeBytes,
      node: $r.node
    }
  ] |
  [
    group_by(.name)[] |
    {
      name: .[0].name,
      sizeMi: ((map(.size) | max) / 1024 / 1024 | floor),
      nodes: (map(.node) | unique)
    } |
    select((.nodes | length) == 1 and .sizeMi >= 100) |
    {
      node: (.nodes[0]),
      sizeMi: .sizeMi,
      name: .name
    }
  ] |
  group_by(.node)[] |
  sort_by(.sizeMi) | reverse |
  "\(.[0].node)\nsize\timage",
  (.[] | [(.sizeMi | tostring + "Mi"), .name] | @tsv),
  ""
' | column -t -s $'\t'
```

Comparison rule of thumb:

```text
Longhorn actual size + image cache ~= part of node filesystem usage
```

Do not expect an exact match. Node filesystem usage also includes the OS,
kubelet logs, container writable layers, containerd metadata, Longhorn engine
metadata, and other runtime files.

---

## 5. Move A Faulted/Detached Single-Replica Volume

Use this procedure only for a single-replica volume whose data must be kept.

Example variables:

```bash
VOLUME="pvc-1fa6cfa6-2e21-4d44-ad1d-8748ef0a544e"
NAMESPACE="dependency-track"
STATEFULSET="dtrack-dependency-track-api-server"
SOURCE_NODE="homelab-workers-pve1-85hh8-br9hw"
TARGET_NODE="homelab-workers-pve2-dk699-g9fc8"
ORIGINAL_REPLICAS="1"
```

### 5.1 Stop The Workload

Stop the workload that writes to the volume:

```bash
kubectl scale sts -n "$NAMESPACE" "$STATEFULSET" --replicas=0
```

Confirm the pod stopped:

```bash
kubectl get pods -n "$NAMESPACE" -o wide
```

### 5.2 Make The Longhorn Disk Schedulable

Salvage or rebuild may fail with:

```text
disk ... is unschedulable for replica ...
```

Check the current minimal available percentage:

```bash
kubectl get setting.longhorn.io -n longhorn-system \
  storage-minimal-available-percentage -o jsonpath='{.value}{"\n"}'
```

Temporarily lower it, for example from `25` to `20`:

```bash
kubectl patch setting.longhorn.io -n longhorn-system \
  storage-minimal-available-percentage \
  --type=merge \
  -p '{"value":"20"}'
```

Restore the old value after the move.

### 5.3 Salvage The Volume

Longhorn UI:

```text
Volume -> <VOLUME> -> Salvage
```

Check the result:

```bash
kubectl get volumes.longhorn.io -n longhorn-system "$VOLUME" -o json | jq -r '
  [
    .metadata.name,
    .status.state,
    .status.robustness,
    .status.currentNodeID,
    (.spec.numberOfReplicas | tostring)
  ] | @tsv
'

kubectl get replicas.longhorn.io -n longhorn-system \
  -l longhornvolume="$VOLUME" -o wide
```

### 5.4 Manually Attach The Volume

Longhorn UI:

```text
Volume -> <VOLUME> -> Attach
Node -> TARGET_NODE
```

Why attach first?

```text
attach -> starts the Longhorn engine
       -> opens the existing replica
       -> allows Longhorn to rebuild/sync a new replica
```

A detached volume is passive. The Longhorn engine must run before Longhorn can
rebuild a new replica from the existing data.

### 5.5 Force The New Replica To The Target Node

Temporarily disable scheduling on nodes that should not receive the new replica:

```text
Node -> SOURCE_NODE -> Edit Disk -> Allow Scheduling = false
Node -> any other unwanted node -> Edit Disk -> Allow Scheduling = false
Node -> TARGET_NODE -> Allow Scheduling = true
```

This does not delete existing data. It only controls where Longhorn can schedule
new replicas.

### 5.6 Temporarily Increase Replica Count To 2

Longhorn UI:

```text
Volume -> <VOLUME> -> Edit -> Number Of Replicas = 2
```

Alternative kubectl command:

```bash
kubectl patch volumes.longhorn.io -n longhorn-system "$VOLUME" \
  --type=merge \
  -p '{"spec":{"numberOfReplicas":2}}'
```

Watch the rebuild:

```bash
watch -n 2 "kubectl get replicas.longhorn.io -n longhorn-system -l longhornvolume=$VOLUME -o wide"
```

Watch volume health:

```bash
watch -n 2 "kubectl get volumes.longhorn.io -n longhorn-system $VOLUME"
```

Target state:

```text
SOURCE_NODE replica running
TARGET_NODE replica running
volume robustness healthy
```

### 5.7 Remove The Old Replica

Do not remove the old replica until the target-node replica is healthy.

Longhorn UI:

```text
Volume -> <VOLUME> -> Replicas
SOURCE_NODE replica -> Delete/Evict
```

After this step only the target-node replica should remain.

### 5.8 Restore Replica Count

Restore the original replica count. In this setup it is usually `1`:

```bash
kubectl patch volumes.longhorn.io -n longhorn-system "$VOLUME" \
  --type=merge \
  -p "{\"spec\":{\"numberOfReplicas\":${ORIGINAL_REPLICAS}}}"
```

Do not set the replica count to `0`. The goal is to leave one healthy replica on
the new node.

### 5.9 Detach The Manual Attachment

Longhorn UI:

```text
Volume -> <VOLUME> -> Detach
```

Why detach after the move?

```text
detach -> releases the manual attachment
       -> lets Kubernetes/CSI attach the volume normally when the workload starts
```

### 5.10 Start The Workload

```bash
kubectl scale sts -n "$NAMESPACE" "$STATEFULSET" --replicas=1
```

Check the workload and volume:

```bash
kubectl get pods -n "$NAMESPACE" -o wide
kubectl get pvc -n "$NAMESPACE"
kubectl get volumes.longhorn.io -n longhorn-system "$VOLUME"
kubectl get replicas.longhorn.io -n longhorn-system -l longhornvolume="$VOLUME" -o wide
```

### 5.11 Restore Temporary Settings

Longhorn UI:

```text
Node -> SOURCE_NODE -> Edit Disk -> Allow Scheduling = true
Node -> other nodes -> Edit Disk -> Allow Scheduling = true
```

Restore the minimal available percentage:

```bash
kubectl patch setting.longhorn.io -n longhorn-system \
  storage-minimal-available-percentage \
  --type=merge \
  -p '{"value":"25"}'
```

---

## 6. Quick Decision Tree

```text
Volume detached but healthy:
  Attach -> replica count 2 -> rebuild -> delete old replica -> restore replica count

Volume detached/faulted and single-replica:
  scale workload to 0 -> make disk schedulable -> salvage -> attach -> rebuild -> delete old replica

Salvage says disk is unschedulable:
  free disk space or temporarily lower storage-minimal-available-percentage

Longhorn UI workload name looks like a Jenkins branch:
  treat it as last-used workload information; identify the volume by PVC name
```
