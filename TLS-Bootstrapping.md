# Kubernetes TLS Bootstrapping & Secure Kubelet Serving Certificates

This documentation details the root causes, architecture, security implications, and step-by-step resolution for the Kubelet certificate validation issues typically encountered when deploying services like metrics-server on a cluster provisioned via Kubeadm and Cluster API (CAPI).

## 1. Problem Statement: The Missing IP SANs Error

When deploying metrics-server, it attempts to securely scrape resource usage metrics from the Kubelet endpoint on each node via port 10250. By default, Kubelet generates its own self-signed serving certificates. These local certificates lack valid Subject Alternative Names (SANs) for the node's internal IP addresses.

Consequently, secure clients like metrics-server reject the connection with strict TLS verification errors. While adding bypass flags like `--kubelet-insecure-tls` to the deployment mitigates the issue, it compromises cluster transit security. The production-grade fix requires enabling Kubelet Server TLS Bootstrapping, forcing Kubelets to request valid, officially signed certificates from the cluster’s central Certificate Authority (CA).

## 2. Security Context & Threat Mitigation (Attacker Model)

Kubernetes purposefully blocks automatic approval of Kubelet serving certificates by default due to a specific attack vector: Man-in-the-Middle (MitM) attacks.

### The Vulnerability

If the cluster blindly auto-approved every serving certificate request (`kubernetes.io/kubelet-serving`), an attacker compromising an unprivileged pod or gaining access to the local network could craft a malicious Certificate Signing Request (CSR). They could spoof a legitimate node's identity or target internal cluster domains (e.g., `control-plane.k8s.local`).

### The Exploitation

If signed, the attacker could deploy a rogue process imitating a Kubelet on that IP/hostname. When a cluster administrator triggers sensitive operational commands such as:

```bash
kubectl exec -it <pod-name> -- bash
```

```bash
kubectl logs <pod-name>
```

The kube-apiserver acts as a client and opens an encrypted tunnel to port 10250 on the destination node. If it connects to the attacker’s machine presenting the signed forged certificate, the API server trusts it implicitly. The attacker can then intercept administrative sessions, harvest database credentials, steal environment variables, and alter pod log outputs.

Implementing strict TLS bootstrapping ensures that Kubelet identities are cryptographically validated before serving certificates are approved.

## 3. Manual Intervention: Immediate Fix & Long-Term Strategy

Resolving this on a running Cluster API topology involves a dual approach: an immediate remediation on existing nodes to restore functionality, followed by a persistent configuration update to ensure future nodes inherit the correct settings.

### Phase A: Live Node Modification (Day 1 Fix)

Instead of immediately replacing active VMs, modify the active Kubelet runtime configuration on existing nodes.

SSH directly into the targeted Control Plane and Worker nodes.

Edit the local Kubelet configuration file:

```bash
sudo nano /var/lib/kubelet/config.yaml
```

Locate the `kind: KubeletConfiguration` section and add the `serverTLSBootstrap` parameter directly underneath it:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
```

Save the file and restart the Kubelet service:

```bash
sudo systemctl restart kubelet
```

### Phase B: Future-Proofing via Central ConfigMap (Day 2 Fix)

Modifying individual nodes restores the current cluster state, but the change is not persistent. When Cluster API recreates a machine due to autoscaling, remediation, or node replacement events, those local modifications are lost. To ensure newly provisioned nodes automatically inherit the configuration, the cluster-wide Kubelet configuration must also be updated.

On your management machine, edit the active Kubelet ConfigMap (adjust the version suffix to match your cluster version, e.g., `v1.36.1`):

```bash
kubectl edit cm kubelet-config -n kube-system
```

Under the `data.kubelet` multiline configuration block, add the same parameter:

```yaml
apiVersion: v1
data:
  kubelet: |
    apiVersion: kubelet.config.k8s.io/v1beta1
    kind: KubeletConfiguration
    serverTLSBootstrap: true
```

Save and exit. Any future VM created by Cluster API will automatically consume this configuration during the kubeadm join process.

### Phase C: Mass Manual Approval

Once Kubelets restart with TLS bootstrapping enabled, they generate serving certificate CSRs that remain in a `Pending` state until approved.

To approve all pending requests:

```bash
kubectl get csr | grep Pending | awk '{print $1}' | xargs -r kubectl certificate approve
```

## 4. Automating Approvals via kubelet-csr-approver

To eliminate manual certificate approvals during scaling events, deploy the `kubelet-csr-approver` controller. This controller evaluates incoming CSRs and automatically approves requests that match predefined policies.

### Helm Installation

Deploy the controller from the management cluster context:

```bash
helm repo add kubelet-csr-approver https://postfinance.github.io/kubelet-csr-approver
helm repo update

helm install kubelet-csr-approver kubelet-csr-approver/kubelet-csr-approver -n kube-system \
  --set providerRegex='^proxmox-quickstart-.*$' \
  --set providerIpPrefixes='192.168.0.0/24' \
  --set maxExpirationSeconds='31536000' \
  --set bypassDnsResolution='true'
```

### Parameter Explanations

#### providerRegex

A regular expression restricting which node hostnames are eligible for automatic approval.

```text
^proxmox-quickstart-.*$
```

Only nodes matching this naming convention can receive automatic approvals.

#### providerIpPrefixes

A comma-separated list of CIDR ranges allowed for certificate requests.

```text
192.168.0.0/24
```

Any CSR requesting SAN IPs outside these ranges is rejected.

#### maxExpirationSeconds

Maximum certificate validity period.

```text
31536000
```

Equivalent to one year.

#### bypassDnsResolution

When enabled, the controller skips reverse DNS lookups.

```text
true
```

This setting is useful in homelab or private cloud environments where reliable internal DNS infrastructure is unavailable.

## 5. Testing & Scaling Under Resource Constraints

To validate that the certificate approval workflow operates correctly, perform a node scaling operation.

### Immutable Infrastructure Template Constraint

Cluster API infrastructure templates are immutable. Hardware properties such as CPU and memory allocations cannot be modified in-place once a template is referenced by active resources.

To apply infrastructure changes, create a new versioned template and update the MachineDeployment to reference it.

### Create a V2 Infrastructure Template

Duplicate the existing template and reduce memory allocation:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ProxmoxMachineTemplate
metadata:
  name: proxmox-quickstart-worker-v2
  namespace: default
spec:
  template:
    spec:
      memory: 3072
      cores: 2
```

### Update the MachineDeployment

Increase the replica count and reference the new template:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachineDeployment
metadata:
  name: proxmox-quickstart-workers
spec:
  replicas: 2
  template:
    spec:
      bootstrap:
        configRef:
          kind: KubeadmConfigTemplate
          name: proxmox-quickstart-worker
      infrastructureRef:
        kind: ProxmoxMachineTemplate
        name: proxmox-quickstart-worker-v2
```

### Apply the Changes

```bash
kubectl apply -f cluster.yaml
```
