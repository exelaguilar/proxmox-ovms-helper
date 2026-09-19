# OVMS Proxmox LXC helper

A personal Proxmox VE helper for installing OpenVINO Model Server (OVMS)
directly in an Ubuntu LXC. This is an independent project; it is not part of
or published through the Proxmox Community Scripts project.

The helper creates a new unprivileged Ubuntu 24.04 container, maps the Intel
GPU render node from the Proxmox host, installs OVMS as a native systemd
service, and configures tty1 root-console autologin. It does not use Docker or
alter or delete existing VMs, containers, Ollama models, or guest data during
a normal install. It creates a new CT disk and may download a template to the
selected Proxmox storage. Default resources are 8 CPU cores, 16 GiB RAM, and a
48 GiB root disk; Advanced Setup lets you choose the guest ID, resources,
network bridge, and storage. The container is unprivileged and uses the
standard Proxmox `nesting=1,keyctl=1` features for systemd compatibility.

The initial model is `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`. Its first
startup downloads about 3.1 GB from Hugging Face. The helper runs text and
synthetic-image inference checks on the Intel GPU before reporting success. It
uses OVMS's `VLM` pipeline, which was verified on this Arrow Lake system after
the `VLM_CB` pipeline crashed with `CL_OUT_OF_RESOURCES`. Health checks are
GPU-only: if inference fails, the helper reports failure and leaves the GPU
target selected; it never silently switches to CPU. The Proxmox host kernel
and Intel driver remain in use inside the LXC, so supported userspace packages
alone cannot guarantee GPU inference on every Arrow Lake system.

## Install

Run on the Proxmox VE host as root. Download the script, inspect it, then run
it:

```bash
curl -fL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/main/ovms-lxc-helper.sh -o /root/ovms-lxc-helper.sh
less /root/ovms-lxc-helper.sh
bash /root/ovms-lxc-helper.sh
```

The installer checks the Proxmox release, Intel GPU, host render node,
container bridge, and storage free space. It shows the selected configuration
for confirmation before downloading a template or creating the LXC. If it
fails after creation, the container is preserved for troubleshooting; do not
blindly rerun the install because that creates another CT.

To retry setup in an existing partial OVMS LXC, use `pct list` to find its ID
and run:

```bash
bash /root/ovms-lxc-helper.sh --repair 120
```

Repair validates the Ubuntu version, running state, hostname, render-node
mapping, and helper ownership marker before changing the CT. A legacy CT with
no ownership marker requires an explicit adoption confirmation.

## In the container

The LXC console automatically logs in as root on tty1, following the familiar
Proxmox helper-script experience. Its login banner shows the OS, hostname, IP,
API URL, service command, and update command. This does not enable SSH or root
network login.

Use the normal helper-style command to update Ubuntu packages and retest
inference:

```bash
update
```

The update checks whether Intel/OpenVINO runtime package versions changed,
restarts OVMS, and tests text and image inference on the configured GPU. A
failed GPU test is reported as a failure; the helper does not switch to CPU.
Package-version diffs are appended to `/var/log/ovms-runtime-updates.log`.
Other service commands are:

```bash
ovms-helper status
ovms-helper restart
ovms-helper logs
ovms-helper healthcheck
```

## Home Assistant

For LLM Vision, add a **Custom OpenAI** provider (not the Ollama provider).
Use the endpoint format requested by your installed LLM Vision version. For a
form whose placeholder includes `/v1/chat/completions` (like the current
configuration screen):

```text
API key:          openai
Custom endpoint:  http://<CT-IP>:8000/v1/chat/completions
Default model:    qwen3-vl-4b
```

LLM Vision 1.7 and newer asks for the base URL without `/chat/completions`; in
that version use `http://<CT-IP>:8000/v1` instead.

The API does not require authentication; `openai` is a dummy key for the
integration's required field. In LLM Vision's Settings, leave **Fallback
provider** set to **No Fallback** unless you deliberately want a different
provider to take over on failure. Keep port 8000 on a trusted LAN or restrict
it with the Proxmox firewall to the Home Assistant host. Since the LXC uses
DHCP, reserve its address in your router before relying on it in Home
Assistant. For host-side checks (replace `120` with the actual CTID):

```bash
pct exec 120 -- systemctl status ovms
pct exec 120 -- journalctl -u ovms -f
pct exec 120 -- clinfo -l
pct exec 120 -- /usr/local/sbin/ovms-healthcheck
```

The script pins the OVMS release and verifies the exact Ubuntu 24.04
Python-enabled archive's SHA-256 before installing it. Review the source
before running it as root on Proxmox.
