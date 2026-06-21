# CAPI + Proxmox + Image Builder — Setup Notes

Based on [this video](https://www.youtube.com/watch?v=G72ylsRmspY). Goal: build a CAPI-compatible Proxmox VM template, then use Cluster API to provision K8s clusters on a homelab Proxmox cluster (4x Lenovo M710q thinkcentre).

## Architecture decision: where things run

| Task | Machine | Why |
|---|---|---|
| Image Builder (Packer + Ansible template build) | Native Ubuntu box | WSL2 NAT breaks inbound connections from the build VM back to the HTTP server (see Issue 3) |
| clusterctl / kind / kubectl (CAPI provisioning) | Windows + WSL2 | This direction is outbound-only (WSL → Proxmox API), no NAT issue applies |

Management cluster (kind) is kept temporary/disposable — it's only needed to bootstrap CAPI, then `clusterctl move` migrates CAPI itself into the real cluster, and kind is deleted. No need to keep it running 24/7 unless using GitOps (which we're explicitly not doing — overkill for 2 small clusters).

---

## Step 1: Proxmox API user + token

`Datacenter → Permissions → Users → Add`
- Username: `capi`, Realm: `pve`

`Datacenter → Permissions → Add → User Permission`
- User: `capi@pve`, Role: `PVEAdmin`, Path: `/`

`Datacenter → Permissions → API Tokens → Add`
- User: `capi@pve`, Token ID: `capitoken`
- **Uncheck "Privilege Separation"**
- Secret is shown only once — save it immediately.

Result:
```
Username (for env var): capi@pve!capitoken
Token secret:           9d4f1434-3d92-40bd-9284-746ea7ade180
```

This is used both by Image Builder (to upload ISO / create the template VM) and by clusterctl's Proxmox provider (to create workload cluster VMs).

---

## Step 2: Install tooling (Ubuntu / WSL Ubuntu)

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.32.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# Packer
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer

# clusterctl
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.13.2/clusterctl-linux-amd64 -o clusterctl
chmod +x clusterctl && sudo mv clusterctl /usr/local/bin/

# misc deps used throughout
sudo apt install -y make git unzip ansible
```

---

## Step 3: Image Builder — build the Proxmox template

Official docs: https://image-builder.sigs.k8s.io/capi/providers/proxmox

```bash
git clone https://github.com/kubernetes-sigs/image-builder.git
cd image-builder/images/capi
```

The build prerequisites for using image-builder for building Proxmox VM templates are managed by running the following command:

```bash
make deps-proxmox
```

From the `images/capi` directory, run `make build-proxmox-<OS>` where `<OS>` is the desired operating system. The available choices are listed via:

```bash
make help | grep proxmox
```

The full list of available environment vars can be found in the variables section of `images/capi/packer/proxmox/packer.json`.

Each variable in this section can also be overridden via the `PACKER_FLAGS` environment var.

<details>
<summary><strong>Issue 1 — Ansible version too old via apt</strong></summary>

`make deps-proxmox` requires Ansible ≥ 2.18 core. Ubuntu's apt package is too old (2.16.x), and Ubuntu 24.04's PEP 668 blocks system-wide `pip install` (`externally-managed-environment` error).

**Fix:** use a venv.
```bash
sudo apt install python3.12-venv
python3 -m venv ~/image-builder-venv
source ~/image-builder-venv/bin/activate
pip install --upgrade pip
pip install "ansible>=13.0.0"
```
> Note: "Ansible" package version ≠ "ansible-core" version — check the [release table](https://docs.ansible.com/projects/ansible/latest/reference_appendices/release_and_maintenance.html#ansible-community-changelogs) if unsure which Ansible version maps to which core version.

**Remember:** this venv must be re-activated (`source ~/image-builder-venv/bin/activate`) every new terminal session — it's not a system-wide install.

</details>

<details>
<summary><strong>Issue 2 — incompatible Packer version</strong></summary>

Packer's own version-pinning logic downloads a compatible Packer binary into `.local/bin` (the apt-installed Packer is usually too new/incompatible and gets ignored). This step needs `unzip`. No need to do anything, it's just ignored — not a real issue actually, but might become one in the future.

</details>

<details>
<summary><strong>Issue 3 — Build VM stuck on "Network Stage" / language-selection screen (the big one)</strong></summary>

Symptom: VM boots, autoinstall is supposed to kick in automatically, but instead it lands on the **interactive Ubuntu installer language-selection screen**.

**Root cause chain:**
1. Ubuntu's autoinstall uses `nocloud-net` datasource — the boot VM fetches its install config over HTTP from `http://{{ .HTTPIP }}:{{ .HTTPPort }}/...`, where `HTTPIP` is auto-detected by Packer as **the IP of the machine running Packer** (because Packer's own temporary HTTP server hosts the config).
2. On WSL2 (default NAT mode), `ip addr show` reports multiple interfaces (loopback alias, `eth0`, link-local `eth2`, etc). Packer picked a useless one (`10.255.255.254`, a loopback alias) — completely unreachable from the Proxmox VM.
3. Switched WSL2 to **mirrored networking mode** (`%USERPROFILE%\.wslconfig`: `[wsl2]` `networkingMode=mirrored`, then `wsl --shutdown`) so WSL shares the host's real LAN IP (`192.168.0.26`).
   - Gotcha: `wsl --shutdown` doesn't actually stop WSL if Docker Desktop or any terminal/VS Code window still holds a session open. Must close everything (incl. Docker Desktop) first, **then** shutdown.
4. Even with the correct IP, the JSON config (`packer/proxmox/ubuntu-2404.json`) had no exposed `http_bind_address`/`http_ip` variable (confirmed via `grep -r "http_bind_address\|http_ip\|HTTPIP" packer/`) — unlike the OVA/vSphere provider, the Proxmox builder doesn't expose this as an overridable var. Manually edited `boot_command_prefix` in that file, replacing `{{ .HTTPIP }}` with the literal LAN IP.
5. **Still failed** even after the IP fix. Verified with `curl` that the HTTP server (`meta-data`, `user-data`) was reachable *from WSL itself* — fine. But `curl` from the **Proxmox host** to the WSL IP timed out completely (`Trying... ^C`).
   - **Conclusion: WSL2 mirrored mode allows outbound connections from WSL to the LAN, but does not reliably accept inbound connections from the LAN back into WSL** (Windows Firewall / mirrored-mode limitation). This only breaks scenarios where something *external* needs to reach WSL (like the build VM fetching cloud-init data) — not the other way around.

**Final fix:** abandoned WSL for this step entirely. Ran Image Builder on a **separate native Ubuntu machine** instead. Build completed cleanly, no IP edits needed — Packer auto-detected the correct IP because there's no NAT/firewall layer to fight.

**Takeaway for future provisioning steps (clusterctl/kind):** this WSL limitation should *not* resurface for clusterctl/kind/CAPI usage, because those flows are WSL-initiated (outbound: WSL → Proxmox API, WSL → VM SSH). The inbound-connection problem is specific to Image Builder's "VM calls back into Packer's HTTP server" pattern. Mirrored mode is not known to be required for CAPI itself — it just happened to be tried as a (partial, ultimately insufficient) fix for the Image Builder issue.

</details>

### Final working build command (run on native Ubuntu)

```bash
source ~/image-builder-venv/bin/activate
cd ~/image-builder/images/capi

export PROXMOX_URL="https://192.168.0.100:8006/api2/json"
export PROXMOX_USERNAME='capi@pve!capitoken'
export PROXMOX_TOKEN="9d4f1434-3d92-40bd-9284-746ea7ade180"
export PROXMOX_NODE="pve"
export PROXMOX_ISO_POOL="local"
export PROXMOX_BRIDGE="vmbr0"
export PROXMOX_STORAGE_POOL="local-lvm"
export PACKER_FLAGS="--var 'disk_format=raw'"

make build-proxmox-ubuntu-2404
```
This process may take 15-60 minutes — Packer downloads the ISO, uploads it to Proxmox, creates the VM, installs the necessary packages (containerd, kubeadm, kubelet, kubectl) into it, and then converts the VM to a template.

### raw vs qcow2 — why the format matters

The end result is a VM template, not an image file you download (no `.qcow2`/`.raw` file lands in your hands — it just lives in Proxmox's storage). But the format still matters because it determines how the template's underlying disk is stored in Proxmox:

**Format must be compatible with the storage type.** Each Proxmox storage type (LVM-thin, ZFS, Directory, Ceph RBD, etc.) supports specific disk formats:

| Storage type | Supported format |
|---|---|
| `local-lvm` (LVM-thin) | `raw` only (no `qcow2`) |
| `local` (directory-based) | `qcow2`, `raw`, `vmdk` |
| ZFS (`local-zfs`) | `raw` only (no `qcow2`) |
| Ceph RBD | `raw` only |

If your storage is `local-lvm` (Proxmox's default in most setups), choosing `qcow2` will make the build fail — LVM-thin doesn't support the file-based disk structure `qcow2` needs; it only supports block-level `raw` disks.