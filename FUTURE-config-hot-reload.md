# Kubernetes Config Hot Reload Notes

Goal: understand how ConfigMap or Secret changes can reach a running workload without manually restarting the pod.

This is useful for future app deployments where some runtime config may need to change without a full rollout.

---

## 1. Main Idea

Hot reload is not only a Kubernetes feature. Kubernetes can update mounted config files, but the application must know how to reload them.

Basic flow:

```text
ConfigMap changes
  -> Kubernetes updates mounted files
  -> sidecar or app notices the change
  -> app reloads config
```

If the app does not support reload, the pod must be restarted.

---

## 2. ConfigMap As Env vs Volume

ConfigMap as environment variables:

```yaml
env:
  - name: APP_MODE
    valueFrom:
      configMapKeyRef:
        name: app-config
        key: APP_MODE
```

This is read when the container starts. If the ConfigMap changes later, the environment variable inside the running container does not change. A pod restart is required.

ConfigMap as mounted files:

```yaml
volumes:
  - name: app-config
    configMap:
      name: app-config

containers:
  - name: app
    volumeMounts:
      - name: app-config
        mountPath: /app/config
```

Kubernetes updates the mounted files after the ConfigMap changes. This makes hot reload possible, but the app still needs to re-read the file.

---

## 3. What Is `volumes.name`?

This part:

```yaml
volumes:
  - name: app-config
```

does not create a PVC by itself. It only creates a pod-level volume name. Think of it as a local alias inside the pod spec.

The real volume type is selected by the field under it:

```yaml
volumes:
  - name: app-config
    configMap:
      name: app-config

  - name: app-secret
    secret:
      secretName: app-secret

  - name: temp-data
    emptyDir: {}

  - name: persistent-data
    persistentVolumeClaim:
      claimName: app-data-pvc
```

Meaning:

- `configMap`: reads data from an existing ConfigMap
- `secret`: reads data from an existing Secret
- `emptyDir`: temporary directory for the pod lifetime
- `persistentVolumeClaim`: mounts an existing PVC

Only the referenced source must exist. For example, `configMap.name: app-config` means a ConfigMap named `app-config` must already exist. `persistentVolumeClaim.claimName: app-data-pvc` means a PVC named `app-data-pvc` must already exist.

---

## 4. Avoid `subPath` For Hot Reload

Do not mount a ConfigMap file with `subPath` if you expect hot reload.

This is good for hot reload:

```yaml
volumeMounts:
  - name: app-config
    mountPath: /app/config
```

Kubernetes mounts the whole ConfigMap directory. When the ConfigMap changes, Kubernetes can update the files under that mounted directory.

This is not good for hot reload:

```yaml
volumeMounts:
  - name: app-config
    mountPath: /app/config/settings.yaml
    subPath: settings.yaml
```

`subPath` mounts one file using a bind mount. Kubernetes does not update that bind-mounted file when the ConfigMap changes. The pod usually needs a restart to see the new content.

Rule:

```text
Need hot reload -> mount the whole ConfigMap directory
Need single fixed file path with subPath -> expect restart
```

If the app requires a single exact file path, prefer mounting the ConfigMap as a directory and point the app to that file inside the directory:

```text
/app/config/settings.yaml
```

---

## 5. Sidecar Pattern

A sidecar can watch ConfigMaps or mounted files and trigger a reload action.

Typical pod:

```text
app-pod
├── app
└── config-reload-sidecar
```

The sidecar can:

- watch Kubernetes ConfigMaps or Secrets
- write the latest config into a mounted directory
- call an HTTP reload endpoint
- send a signal to the main process

The sidecar does not magically reload the app. It only triggers the reload mechanism.

---

## 6. Jenkins Example

The Jenkins Helm chart uses this pattern.

Jenkins pod:

```text
jenkins-0
├── jenkins
└── config-reload
```

When `jenkins-values.yaml` changes:

```text
helm upgrade
  -> Jenkins ConfigMap changes
  -> config-reload sidecar writes jenkins-config.yaml
  -> sidecar calls Jenkins JCasC reload endpoint
  -> Jenkins re-reads configuration
  -> Job DSL updates jobs
```

This is why a Job DSL change can apply without restarting the Jenkins pod.

If the DSL is invalid, reload fails and the old job config remains active. Check:

```bash
kubectl logs -n jenkins jenkins-0 -c config-reload --tail=120
kubectl logs -n jenkins jenkins-0 -c jenkins --since=20m
```

---

## 7. Ready-Made Tools

`kiwigrid/k8s-sidecar`

- runs as a sidecar inside the pod
- watches ConfigMaps or Secrets
- writes them as files
- can call a reload URL after changes
- useful when the app has a reload endpoint

`stakater/reloader`

- runs as a cluster controller, not a pod sidecar
- watches ConfigMaps or Secrets
- restarts Deployments or StatefulSets when config changes
- useful when the app cannot hot reload

Difference:

```text
kiwigrid/k8s-sidecar -> hot reload helper
stakater/reloader    -> automatic rollout restart
```

---

## 8. App Requirements

For real hot reload, the application needs one of these:

- watches config files itself
- exposes a reload endpoint, for example `POST /admin/reload-config`
- handles a signal like `SIGHUP`
- reads config dynamically on every use

If the app only reads config at startup, ConfigMap volume updates are not enough.

---

## 9. When Restart Is Still Needed

Hot reload is usually not enough for:

- container image changes
- environment variable changes
- command or args changes
- resource limit changes
- volume mount changes
- service account or RBAC changes
- plugin or dependency installation
- config that the app only reads at startup
- ConfigMap files mounted with `subPath`

In these cases, use a normal rollout restart.

---

## 10. How `kiwigrid/k8s-sidecar` Actually Works

There are two different patterns that should not be mixed up:

```text
Native ConfigMap volume
  -> kubelet updates the mounted directory
  -> the app or a file-watcher notices the file change

kiwigrid/k8s-sidecar
  -> sidecar watches labeled ConfigMaps through the Kubernetes API
  -> sidecar writes their data keys into a shared directory
  -> sidecar calls REQ_URL
  -> the app validates the file and replaces its in-memory config
```

The second pattern is used in this project. The shared directory is an
`emptyDir`, not a direct ConfigMap volume. Therefore, the sidecar needs
`get`, `list`, and `watch` access to ConfigMaps in the `staging` namespace.

### How The Sidecar Detects The ConfigMap

The application does not detect or read the ConfigMap directly. The sidecar
connects to the Kubernetes API using the pod's ServiceAccount and watches
ConfigMaps with this label:

```yaml
metadata:
  labels:
    todo-service-hot-reload: "true"
```

The sidecar is configured with matching values:

```yaml
- name: LABEL
  value: todo-service-hot-reload
- name: LABEL_VALUE
  value: "true"
```

The namespace-scoped Role grants the sidecar `get`, `list`, and `watch`
permissions. When the ConfigMap is first listed or a later watch event arrives,
the sidecar takes each key under `data` and writes it as a file. In this case,
the `runtime-config.json` key becomes a file with the same name.

### Why An `emptyDir` Is Used

The `emptyDir` is a pod-local, temporary shared directory. It is not the
ConfigMap and it is not persistent storage. Both containers mount the same
`emptyDir` at `/etc/todo-service/runtime-config`:

```text
todo-service pod
  -> config-reloader sidecar mounts emptyDir as writable
  -> todo-service mounts the same emptyDir as read-only
```

The complete data path is:

```text
Kubernetes API ConfigMap
  -> sidecar reads the labeled ConfigMap
  -> sidecar writes runtime-config.json into the pod's emptyDir
  -> sidecar calls POST /admin/reload-config
  -> todo-service reads runtime-config.json from the emptyDir
  -> todo-service validates it and replaces its in-memory config
```

This also applies during initial pod startup. The application never reads the
ConfigMap object. If the sidecar completes its initial sync first, the
application can read the file from the `emptyDir` during startup. If the
application starts first, it temporarily keeps its built-in default; the
sidecar then writes the file and calls the reload endpoint. The configured HTTP
retry handles this startup race.

Every replica has a separate `emptyDir` and a separate sidecar. When a pod is
deleted, its `emptyDir` disappears. A newly created pod gets a new `emptyDir`,
and its sidecar repopulates it from the current ConfigMap before triggering the
application reload.

Official reference: <https://github.com/kiwigrid/k8s-sidecar>

---

## 11. Todo Service Implementation

The experiment is intentionally limited to `todo-service`.

Files:

- `App/todo-service/app.py`: runtime config model, `GET /config`, and
  `POST /admin/reload-config`
- `3-Kubectl-Deploy/staging/todo-service/templates/configmap.yaml`: visible
  `message` and `version` settings
- `3-Kubectl-Deploy/staging/todo-service/templates/hot-reload-rbac.yaml`:
  namespace-scoped ServiceAccount, Role, and RoleBinding
- `3-Kubectl-Deploy/staging/todo-service/templates/deployment.yaml`: shared
  `emptyDir` and `ghcr.io/kiwigrid/k8s-sidecar:2.7.3`
- `3-Kubectl-Deploy/staging/frontend/templates/httproute.yaml`: sends the exact
  `/config` path to `todo-service`

Runtime flow:

```text
todo-service-runtime-config ConfigMap changes
  -> each todo-service pod's sidecar receives the watch event
  -> sidecar writes runtime-config.json into the pod's emptyDir
  -> sidecar POSTs to http://127.0.0.1:8002/admin/reload-config
  -> todo-service validates message and version
  -> valid: new config atomically replaces the in-memory config
  -> invalid: HTTP 422, log error, old in-memory config remains active
```

`POST /admin/reload-config` accepts only a loopback client, so the HTTPRoute's
existing `/admin` path does not expose this todo-service operation. The
`GET /config` endpoint is public on purpose because it is the visible result of
this test.

The frontend already had a `frontend-config` ConfigMap before this experiment.
It is mounted with `subPath`, so changing that Caddyfile does not demonstrate
hot reload and still requires a pod rollout.

---

## 12. First Deployment

The new `todo-service` application code must first be built and pushed as the
image used by the staging Rollout. The initial manifest change also adds a
container, ServiceAccount, and volume, so one rollout is expected:

```bash
kubectl apply -R -f 3-Kubectl-Deploy/staging
kubectl argo rollouts get rollout todo-service -n staging
kubectl argo rollouts promote todo-service -n staging --full
```

Confirm that every pod has both containers and read the initial value:

```bash
kubectl get pods -n staging -l app=todo-service \
  -o custom-columns='NAME:.metadata.name,CONTAINERS:.spec.containers[*].name,RESTARTS:.status.containerStatuses[*].restartCount,AGE:.metadata.creationTimestamp'

curl -s http://todo-app-staging.192.168.0.110.nip.io/config
```

Expected response:

```json
{"message":"Staging config version 1 is active","version":1}
```

---

## 13. Prove Hot Reload Without A Rollout

First record the pod names, UIDs, and creation times:

```bash
kubectl get pods -n staging -l app=todo-service \
  -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,CREATED:.metadata.creationTimestamp,RESTARTS:.status.containerStatuses[*].restartCount'
```

Edit only `runtime-config.json` in
`3-Kubectl-Deploy/staging/todo-service/templates/configmap.yaml`:

```json
{
  "message": "Hot reload worked without restarting a pod",
  "version": 2
}
```

Apply only the ConfigMap. Do not apply the Rollout again:

```bash
kubectl apply -f 3-Kubectl-Deploy/staging/todo-service/templates/configmap.yaml
```

Watch the result and sidecar logs:

```bash
watch -n 1 curl -s http://todo-app-staging.192.168.0.110.nip.io/config

kubectl logs -n staging -l app=todo-service \
  -c config-reloader --prefix --tail=100
```

The response should change to version 2. Run the pod identity command again.
The names, UIDs, creation times, and restart counts should be unchanged. That
is the proof that the config changed in memory without a rollout or restart.

There are three replicas, and each replica has its own sidecar and in-memory
config. During the short propagation window, repeated requests may briefly hit
different versions. All replicas should converge after their watch events are
processed.

---

## 14. Invalid Config Test

Set an invalid value such as an empty message or version `0`, then apply only
the ConfigMap again. The reload endpoint will return HTTP 422 to the sidecar,
and the previous valid value will remain active:

```bash
kubectl logs -n staging -l app=todo-service \
  -c todo-service --prefix --tail=100

kubectl logs -n staging -l app=todo-service \
  -c config-reloader --prefix --tail=100
```

Correct the ConfigMap and apply it again to recover. No pod restart is needed.

Important rules for production use:

- validate new config before applying it
- keep old config if reload fails
- protect reload endpoints with auth or loopback-only access
- log every reload attempt
- expose a metric for the current config version if this pattern becomes permanent

If true hot reload is not needed, prefer a normal Kubernetes rollout. It is
simpler and safer.
