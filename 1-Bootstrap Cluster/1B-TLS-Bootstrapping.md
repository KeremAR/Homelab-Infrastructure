
## TLS Bootstrapping (kubelet serving certificates)
 
Anything that talks to the kubelet directly (`metrics-server`, `kubectl logs`, `kubectl exec`) hits it over HTTPS on port `10250`. This section is about why that breaks by default, the manual fix, and the proper automated fix — relevant for **any** future cluster, not just this one.

### How the two kubelet TLS directions differ

There are two independent TLS directions and certificate purposes:

```text
kubelet  ──client certificate──> API server
API server / Metrics Server ──HTTPS──> kubelet:10250
                                      └─ kubelet serving certificate
```

The kubelet client CSR uses the `kubernetes.io/kube-apiserver-client-kubelet` signer. It proves the node's identity when the kubelet joins and talks to the API server, so the standard bootstrap flow automatically approves it. The kubelet serving CSR uses the `kubernetes.io/kubelet-serving` signer. It proves the kubelet's identity to clients connecting to port `10250`; Kubernetes deliberately leaves this CSR `Pending` until it is separately approved.

Most `kubectl` commands only talk to the API server:

| Command | Request path | Reaches kubelet `:10250`? |
|---|---|---|
| `kubectl get`, `apply`, `delete`, `describe` | `kubectl → API server` | No |
| `kubectl logs`, `exec`, `attach`, `port-forward` | `kubectl → API server → kubelet:10250` | Yes |
| `kubectl top` | `kubectl → API server → Metrics Server → kubelet:10250` | Yes |

There is an important verification difference between the last two paths:

- For `kubectl logs`/`exec`, the API server is the TLS client connecting to the kubelet. By default, the API server does **not** verify the kubelet's serving certificate unless it is configured with `--kubelet-certificate-authority`. This is why these commands can work even while the kubelet serving CSR is still `Pending`. This behavior is described in the official Kubernetes documentation under [API server to kubelet communication](https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/#api-server-to-kubelet).
- Metrics Server makes its own connection to the kubelet and verifies the presented serving certificate. It selects an address from the Node object using `--kubelet-preferred-address-types`. In this cluster it connects to an `InternalIP`, so that exact IP must be present in the certificate's SANs and the certificate must chain to a trusted CA. Otherwise it reports `doesn't contain any IP SANs`.

Therefore, working `kubectl logs`/`exec` is not proof that the kubelet serving certificate is correct. It can mean that the API server is accepting the connection without verifying that certificate, while Metrics Server correctly rejects the same certificate.

### Install Metrics Server

Install Metrics Server on the workload cluster:

```bash
kubectl --kubeconfig=homelab.kubeconfig apply -f \
  https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Wait for the deployment and test the Metrics API:

```bash
kubectl --kubeconfig=homelab.kubeconfig rollout status deployment/metrics-server -n kube-system
kubectl --kubeconfig=homelab.kubeconfig top nodes
kubectl --kubeconfig=homelab.kubeconfig top pods -A
```

If Metrics Server starts but cannot scrape the nodes because their certificates do not contain IP SANs, continue with the issue and proper fix below. Do not add `--kubelet-insecure-tls`; that only disables certificate verification and hides the underlying kubelet serving-certificate problem.
 
<details>
<summary><strong>Issue 7 — metrics-server (or anything hitting kubelet:10250) fails with "doesn't contain any IP SANs"</strong></summary>

Symptom:
```
Failed to scrape node" err="Get \"https://192.168.0.150:10250/metrics/resource\": tls: failed to verify
certificate: x509: cannot validate certificate for 192.168.0.150 because it doesn't contain any IP SANs"
```
 
**What's actually missing:** the kubelet's *serving* certificate (the one it presents to clients connecting to it, as opposed to the *client* certificate it uses to talk to the API server) is not a cluster-CA-signed certificate with the node's required DNS/IP SANs. A client that verifies this certificate and connects using the node IP (like Metrics Server in this case) rejects it because that IP is not present in the certificate SANs.

This is **not** a CAPI/CAPMOX bug. Kubernetes deliberately does **not** auto-approve kubelet serving-certificate requests, for security reasons (an attacker-controlled CSR impersonating a DNS name/IP could otherwise get a valid cert signed). Client certificates (kubelet → API server, used to join the cluster) *are* auto-approved out of the box via the `system:certificates.k8s.io:certificatesigningrequests:nodeclient` ClusterRole bound to the `system:bootstrappers` group — verify with:
```bash
kubectl get clusterrolebindings | grep -i bootstrap
```
But there's no equivalent auto-approval ClusterRole for the *serving* cert path — confirmed nothing shows up for:
```bash
kubectl get clusterrolebindings | grep -i "selfnodeserver\|serving"
```
Production clusters hit this too — it's always solved either by manually approving, or by running a dedicated auto-approver controller (see fix below). Reference: [Kubernetes docs — TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/), [kubeadm certs docs](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/).
 
**Why this couldn't just be set at first cluster creation via CAPI YAML:** tried adding `kubeletConfiguration.serverTLSBootstrap: true` directly under `KubeadmControlPlane.spec.kubeadmConfigSpec` and under `KubeadmConfigTemplate.spec.template.spec` — both rejected:
```
strict decoding error: unknown field "spec.kubeadmConfigSpec.kubeletConfiguration"
strict decoding error: unknown field "spec.template.spec.kubeletConfiguration"
```
This CAPI/CAPMOX version's API schema (`v1beta2`) doesn't expose a `kubeletConfiguration` field at that path. Checked the real schema directly instead of guessing further:
```bash
kubectl explain kubeadmcontrolplane.spec.kubeadmConfigSpec --recursive | grep -i "kubelet\|tls"
```
— only turned up `kubeletExtraArgs` (CLI flags, not config-file fields) and unrelated `tlsBootstrapSeconds`/`insecureSkipTLSVerify` (those govern the kubelet's *client*-side bootstrap, not the serving cert). No usable path found for this CAPI version — hence doing it post-creation, directly on the nodes/ConfigMap.

**Resolution:** apply the complete **The proper fix** procedure immediately below. It enables kubelet serving-certificate bootstrapping, installs automatic serving-CSR approval, and makes the API server verify the resulting CA-signed kubelet certificates. Do not treat manual CSR approval or Metrics Server's `--kubelet-insecure-tls` as the permanent solution.
 
</details>

### The proper fix

The complete fix has three parts: enable kubelet serving-certificate bootstrapping, automate approval of the serving CSRs, and make the API server verify those certificates.

#### 1. Enable `serverTLSBootstrap`

First update the cluster-wide kubelet ConfigMap so newly created nodes inherit the setting:

```bash
kubectl --kubeconfig=homelab.kubeconfig edit configmap kubelet-config -n kube-system
```

Inside the ConfigMap, add `serverTLSBootstrap: true` to the YAML stored under `data.kubelet`. It belongs at the same indentation level as `apiVersion` and `kind` inside the `|` block:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubelet-config
  namespace: kube-system
data:
  kubelet: |
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    serverTLSBootstrap: true
    # ...the existing KubeletConfiguration fields remain here
```

For every already-running control-plane and worker node, edit the local kubelet configuration:

```bash
sudo nano /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
```

In `/var/lib/kubelet/config.yaml`, the field is a top-level field. It has no leading spaces and is aligned with `apiVersion` and `kind`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
# ...the existing fields remain here
```

The ConfigMap affects nodes that bootstrap after the change. Existing nodes have already loaded their local configuration, so they require the local file change and kubelet restart shown above. Alternatively, recreate an existing CAPI Machine after updating the ConfigMap.

Restarting kubelet creates serving-certificate CSRs. They remain `Pending` until approved:

```bash
kubectl --kubeconfig=homelab.kubeconfig get csr
```

For a one-time diagnostic confirmation, a CSR can be approved manually by name:

```bash
kubectl --kubeconfig=homelab.kubeconfig certificate approve <csr-name>
```

Manual approval is only a test; use the automated approver below for the permanent setup.

#### 2. Automate CSR approval with `kubelet-csr-approver`
 
Manually approving CSRs doesn't scale — every new node (autoscaling, remediation after a VM failure, manually adding workers) needs someone to run `kubectl certificate approve` by hand, or it sits `Pending` forever. [`kubelet-csr-approver`](https://github.com/postfinance/kubelet-csr-approver) is a controller that does this automatically, subject to configurable checks.
 
```bash
helm repo add kubelet-csr-approver https://postfinance.github.io/kubelet-csr-approver
helm repo update
 
helm install kubelet-csr-approver kubelet-csr-approver/kubelet-csr-approver \
  --kubeconfig=homelab.kubeconfig \
  --namespace kube-system \
  --set providerRegex='^homelab.*$' \
  --set providerIpPrefixes='192.168.0.0/24' \
  --set bypassDnsResolution='true'
```
 
**Parameters, what each one does and why it's set this way here:**
 
| Parameter | What it controls | Value used here, and why |
|---|---|---|
| `providerRegex` | Which node **hostnames** are allowed to get a CSR approved | `^homelab.*$` — matches this cluster's node names (`homelab-control-plane-xxxxx`, `homelab-workers-xxxxx`) |
| `providerIpPrefixes` | Which **IP ranges** a CSR's IP SAN must fall within | `192.168.0.0/24` — the homelab LAN; rejects anything outside it |
| `bypassDnsResolution` | Skips checking that the node hostname actually resolves via DNS to the claimed IP | `true` — no internal DNS server for per-node hostnames here, only static IPs; the check would always fail otherwise |
| `bypassHostnameCheck` | Allows the cert's DNS name to *not* be prefixed by the node's own hostname | left default (`false`) — node names already match their own hostnames, no need to loosen this |
| `maxExpirationSec` | Upper bound on how long a requested cert can be valid for | left default (367 days) — fine for a homelab, no need to shorten |
| `ignoreNonSystemNode` | Whether to ignore CSRs whose username *isn't* `system:node:...` | left default (`false`) — this check matters, don't disable it |
| `skipDenyStep` | If `true`, approver only ever approves matching CSRs and leaves non-matching ones `Pending` instead of actively denying them | left default (`false`) |
| `allowedDnsNames` | Max number of DNS SANs allowed in one CSR | left default (`1`) — fine for this simple setup |

#### 3. Make the API server verify kubelet serving certificates

The serving certificate and approver fix Metrics Server, but the API server still does not verify kubelet serving certificates by default. Apply this hardening only after step 2 and after every kubelet serving CSR is `Approved,Issued`:

```bash
kubectl --kubeconfig=homelab.kubeconfig get csr
```

First update kubeadm's cluster-wide configuration:

```bash
kubectl --kubeconfig=homelab.kubeconfig edit configmap kubeadm-config -n kube-system
```

Inside the ConfigMap, add `kubelet-certificate-authority` to the `apiServer.extraArgs` list in the YAML stored under `data.ClusterConfiguration`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubeadm-config
  namespace: kube-system
data:
  ClusterConfiguration: |
    apiServer:
      extraArgs:
      - name: kubelet-certificate-authority
        value: /etc/kubernetes/pki/ca.crt
      # ...keep the existing API server arguments here
    # ...keep the rest of the existing ClusterConfiguration here
```

The indentation is important: `apiServer` is inside the `ClusterConfiguration: |` block; `extraArgs` is a child of `apiServer`; and the flag is one item in the existing `name`/`value` list. Do not replace the other arguments or the rest of `ClusterConfiguration`.

The ConfigMap records the desired kubeadm configuration, but editing it does not rewrite an API server that is already running. On every control-plane node, edit the static Pod manifest:

```bash
sudo nano /etc/kubernetes/manifests/kube-apiserver.yaml
```

Add the flag to the existing `spec.containers[0].command` list, aligned with the other `- --...` arguments:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
    # ...the other existing kube-apiserver arguments remain here
    name: kube-apiserver
```

Saving this manifest makes kubelet restart the local API server static Pod. A single-control-plane cluster can have a short API interruption. With multiple control-plane nodes, update them one at a time and wait for each API server to become healthy before continuing.

This flag does not generate or approve any CSR. It only tells the API server which CA to trust when checking the certificate presented by kubelet. The same `kubelet-csr-approver` installed in step 2 approves the serving CSRs; no second approver is required.

After the API server returns, verify a kubelet-proxied request:

```bash
kubectl --kubeconfig=homelab.kubeconfig logs -n kube-system deployment/metrics-server --tail=20
```
 
### What this actually protects against
 
The kubelet's serving certificate is what answers *all* requests to port `10250` — not just `metrics-server` reading metrics, but also the endpoints behind `kubectl exec`, `kubectl logs`, `kubectl attach`. If an attacker could get a forged certificate approved for, say, the control-plane endpoint's IP (`192.168.0.150`), they'd hold a **valid** certificate claiming to be that node's kubelet — a prerequisite for a man-in-the-middle attack (still requires also redirecting traffic, e.g. via ARP/DNS spoofing — the cert alone isn't sufficient, but it's the part that's supposed to be hard to get).
 
`system:node:<name>` is the identity format the API server assigns to a kubelet once it has joined the cluster via its (auto-approved) client certificate — not something a random pod or user can claim; it's tied to having a legitimate per-node client cert in the first place. `kubelet-csr-approver`'s checks (from its own docs) only approve a CSR if, among other things: the requesting username is prefixed `system:node:`, the cert's CommonName matches that username, the SAN DNS name (if any) is prefixed by the node's own hostname, and any SAN IPs fall inside `providerIpPrefixes`. This makes it hard for an outside/unprivileged actor to get a forged identity signed — but it's not a defense against an attacker who already has API access or node access; at that point they could just approve the CSR themselves. It mainly closes the gap of "no automated approval at all" without reopening it to arbitrary forged requests from outside.
 
### Testing it — add a node and watch the CSR get auto-approved
 
> ⚠️ Check available RAM before scaling up — see "MachineDeployment scaling and `maxSurge`" below first if resources are tight.
 
```bash
kubectl scale machinedeployment homelab-workers-pve1 --replicas=2
```
 
Watch the CSR go from nothing → `Pending` → `Approved`, without running `kubectl certificate approve` manually:
```bash
watch -n 2 'kubectl get csr'
```
 
In a second terminal, watch the approver reason about it live:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=kubelet-csr-approver -f
```
 
### MachineDeployment scaling and `maxSurge` — why it needs spare resources
 
`KubeadmControlPlane`/`MachineDeployment` rolling updates default to `maxSurge: 1`: when replacing a machine (e.g. resizing RAM, which requires a new immutable `ProxmoxMachineTemplate` — see below), CAPI **creates the new one first, then deletes the old one** — meaning momentarily N+1 machines exist, not N. This needs spare CPU/RAM capacity on the Proxmox side during the transition.
 
Tried setting `maxSurge: 0` (delete-old-then-create-new, no extra resource needed momentarily) on the control plane and got:
```
spec.rollout.strategy.rollingUpdate: Required value: when KubeadmControlPlane is configured to
scale-in, replica count needs to be at least 3
```
This is a deliberate guard: dropping a control-plane replica count by 1 *before* the replacement exists could break etcd quorum on anything with fewer than 3 control-plane nodes (going from 1→0, even momentarily, kills the cluster outright; going from 3→2 still leaves quorum intact). With a single control-plane node, `maxSurge: 0` is simply not allowed — and the default (`maxSurge: 1`, create-then-delete) is already the correct, safer behavior here. No change needed; the "use spare capacity instead of risking quorum" trade-off is the right one for a 1 (or even 3) node control plane and isn't something to fight against.
 
### `ProxmoxMachineTemplate` is immutable — how to actually resize a MachineDeployment's VMs
 
Discovered while trying to shrink worker RAM from 4GB → 3GB to make room for a new node:
```
The ProxmoxMachineTemplate "homelab-worker-pve1" is invalid: spec: Forbidden: ProxmoxMachineTemplate is immutable
```
CAPI's design: don't mutate a template in place — create a new one, point the `MachineDeployment` at it, let the rolling update replace machines using the old one.
 
1. Create a new `ProxmoxMachineTemplate` (copy of the old one, new name, only the changed field — e.g. `memoryMiB` — different):
```bash
kubectl get proxmoxmachinetemplate   # confirm the new one doesn't already exist
```
```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha2
kind: ProxmoxMachineTemplate
metadata:
  name: homelab-worker-pve1-v2
  namespace: default
spec:
  template:
    spec:
      numSockets: 1
      numCores: 2
      memoryMiB: 3072
      # ...copy every other field from the original template, unchanged
```
2. Point the `MachineDeployment`'s `infrastructureRef` (not `bootstrap.configRef` — that one's unrelated to VM sizing, leave it as-is) at the new template:
```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineDeployment
metadata:
  name: homelab-workers-pve1
  namespace: default
spec:
  template:
    spec:
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: ProxmoxMachineTemplate
        name: homelab-worker-pve1-v2 # was homelab-worker-pve1
```
3. Apply — triggers the same create-new-then-delete-old rolling replacement described above.
---
