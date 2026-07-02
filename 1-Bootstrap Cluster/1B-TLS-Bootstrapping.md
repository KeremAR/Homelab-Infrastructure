
## TLS Bootstrapping (kubelet serving certificates)
 
Anything that talks to the kubelet directly (`metrics-server`, `kubectl logs`, `kubectl exec`) hits it over HTTPS on port `10250`. This section is about why that breaks by default, the manual fix, and the proper automated fix — relevant for **any** future cluster, not just this one.
 
<details>
<summary><strong>Issue 7 — metrics-server (or anything hitting kubelet:10250) fails with "doesn't contain any IP SANs"</strong></summary>
Symptom:
```
Failed to scrape node" err="Get \"https://192.168.0.150:10250/metrics/resource\": tls: failed to verify
certificate: x509: cannot validate certificate for 192.168.0.150 because it doesn't contain any IP SANs"
```
 
**What's actually missing:** the kubelet's *serving* certificate (the one it presents to clients connecting to it, as opposed to the *client* certificate it uses to talk to the API server) is, by default, only signed for the node's **hostname** — not its IP. Anything connecting by IP (like `metrics-server`) gets rejected.
 
This is **not** a CAPI/CAPMOX bug. Kubernetes deliberately does **not** auto-approve kubelet serving-certificate requests, for security reasons (an attacker-controlled CSR impersonating a DNS name/IP could otherwise get a valid cert signed). Client certificates (kubelet → API server, used to join the cluster) *are* auto-approved out of the box via the `system:certificates.k8s.io:certificatesigningrequests:nodeclient` ClusterRole bound to the `system:bootstrappers` group — verify with:
```bash
kubectl get clusterrolebindings | grep -i bootstrap
```
But there's no equivalent auto-approval ClusterRole for the *serving* cert path — confirmed nothing shows up for:
```bash
kubectl get clusterrolebindings | grep -i "selfnodeserver\|serving"
```
Production clusters hit this too — it's always solved either by manually approving, or by running a dedicated auto-approver controller (see fix below). Reference: [Kubernetes docs — TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/), [kubeadm certs docs](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/).
 
**Manual fix (done first, to confirm the diagnosis, on an already-running cluster):**
 
On every node (control-plane and worker):
```bash
sudo nano /var/lib/kubelet/config.yaml
# add `serverTLSBootstrap: true` right under `kind: KubeletConfiguration`
sudo systemctl restart kubelet
```
Also edit the cluster-wide ConfigMap (so future nodes pick this up without manual editing):
```bash
kubectl edit cm kubelet-config -n kube-system
# same addition: `serverTLSBootstrap: true` under `kind: KubeletConfiguration`
```
Then approve the resulting CSRs by hand:
```bash
kubectl get csr | grep Pending | awk '{print $1}' | xargs -r kubectl certificate approve
```
 
**Why edit nodes directly instead of just the ConfigMap:** the ConfigMap only affects *new* nodes bootstrapping from it. Already-running nodes had already read the old config at boot — to apply the change to them, either edit `/var/lib/kubelet/config.yaml` directly + restart kubelet (what we did), or delete/recreate the machine so it re-reads the now-patched ConfigMap from scratch.
 
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
 
</details>
### The proper fix: automate the CSR approval with `kubelet-csr-approver`
 
Manually approving CSRs doesn't scale — every new node (autoscaling, remediation after a VM failure, manually adding workers) needs someone to run `kubectl certificate approve` by hand, or it sits `Pending` forever. [`kubelet-csr-approver`](https://github.com/postfinance/kubelet-csr-approver) is a controller that does this automatically, subject to configurable checks.
 
```bash
helm repo add kubelet-csr-approver https://postfinance.github.io/kubelet-csr-approver
helm repo update
 
helm install kubelet-csr-approver kubelet-csr-approver/kubelet-csr-approver -n kube-system \
  --set providerRegex='^proxmox-quickstart.*$' \
  --set providerIpPrefixes='192.168.0.0/24' \
  --set bypassDnsResolution='true'
```
 
**Parameters, what each one does and why it's set this way here:**
 
| Parameter | What it controls | Value used here, and why |
|---|---|---|
| `providerRegex` | Which node **hostnames** are allowed to get a CSR approved | `^proxmox-quickstart.*$` — matches this cluster's node naming (`proxmox-quickstart-control-plane-xxxxx`, `proxmox-quickstart-workers-xxxxx`) |
| `providerIpPrefixes` | Which **IP ranges** a CSR's IP SAN must fall within | `192.168.0.0/24` — the homelab LAN; rejects anything outside it |
| `bypassDnsResolution` | Skips checking that the node hostname actually resolves via DNS to the claimed IP | `true` — no internal DNS server for per-node hostnames here, only static IPs; the check would always fail otherwise |
| `bypassHostnameCheck` | Allows the cert's DNS name to *not* be prefixed by the node's own hostname | left default (`false`) — node names already match their own hostnames, no need to loosen this |
| `maxExpirationSec` | Upper bound on how long a requested cert can be valid for | left default (367 days) — fine for a homelab, no need to shorten |
| `ignoreNonSystemNode` | Whether to ignore CSRs whose username *isn't* `system:node:...` | left default (`false`) — this check matters, don't disable it |
| `skipDenyStep` | If `true`, approver only ever approves matching CSRs and leaves non-matching ones `Pending` instead of actively denying them | left default (`false`) |
| `allowedDnsNames` | Max number of DNS SANs allowed in one CSR | left default (`1`) — fine for this simple setup |
 
### What this actually protects against
 
The kubelet's serving certificate is what answers *all* requests to port `10250` — not just `metrics-server` reading metrics, but also the endpoints behind `kubectl exec`, `kubectl logs`, `kubectl attach`. If an attacker could get a forged certificate approved for, say, the control-plane endpoint's IP (`192.168.0.150`), they'd hold a **valid** certificate claiming to be that node's kubelet — a prerequisite for a man-in-the-middle attack (still requires also redirecting traffic, e.g. via ARP/DNS spoofing — the cert alone isn't sufficient, but it's the part that's supposed to be hard to get).
 
`system:node:<name>` is the identity format the API server assigns to a kubelet once it has joined the cluster via its (auto-approved) client certificate — not something a random pod or user can claim; it's tied to having a legitimate per-node client cert in the first place. `kubelet-csr-approver`'s checks (from its own docs) only approve a CSR if, among other things: the requesting username is prefixed `system:node:`, the cert's CommonName matches that username, the SAN DNS name (if any) is prefixed by the node's own hostname, and any SAN IPs fall inside `providerIpPrefixes`. This makes it hard for an outside/unprivileged actor to get a forged identity signed — but it's not a defense against an attacker who already has API access or node access; at that point they could just approve the CSR themselves. It mainly closes the gap of "no automated approval at all" without reopening it to arbitrary forged requests from outside.
 
### Testing it — add a node and watch the CSR get auto-approved
 
> ⚠️ Check available RAM before scaling up — see "MachineDeployment scaling and `maxSurge`" below first if resources are tight.
 
```bash
kubectl scale machinedeployment proxmox-quickstart-workers --replicas=2
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
The ProxmoxMachineTemplate "proxmox-quickstart-worker" is invalid: spec: Forbidden: ProxmoxMachineTemplate is immutable
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
  name: proxmox-quickstart-worker-v2
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
infrastructureRef:
  apiGroup: infrastructure.cluster.x-k8s.io
  kind: ProxmoxMachineTemplate
  name: proxmox-quickstart-worker-v2   # was proxmox-quickstart-worker
```
3. Apply — triggers the same create-new-then-delete-old rolling replacement described above.
---