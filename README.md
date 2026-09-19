# OVMS Proxmox LXC helper

This is a personal helper script for installing OpenVINO Model Server (OVMS)
in a new Proxmox LXC. It is an independent project, not an upload or
contribution to the Proxmox Community Scripts project.

It creates a **new** unprivileged Ubuntu 24.04 LXC, maps the host's Intel
`/dev/dri/renderD128` device into it, installs Intel's GPU userspace runtime,
and installs the native OpenVINO Model Server 2026.4.0 bundle as a systemd
service. It does not install Docker and does not alter or delete existing VMs,
containers, Ollama models, or Proxmox storage.

The helper uses the familiar Default/Advanced flow. Default mode auto-selects
the next unused guest ID and preferred active storage, then uses sensible
resource defaults. Advanced mode lets you enter a CTID and choose storage,
CPU, RAM, disk, bridge, and hostname. The initial model is
`OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`; its first launch downloads about
3.1 GB from Hugging Face.

## Run it

Run the script from the Proxmox shell as root. You can download it directly
from this repository:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/main/ovms-lxc-helper.sh)"
```

Or download first so you can inspect it:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/main/ovms-lxc-helper.sh)
```

The helper checks the Proxmox version, architecture, GPU device, and required
host commands before making changes. It asks for confirmation immediately
before creating the CT. If setup fails after creation, the CT is deliberately
preserved for troubleshooting. Do not blindly rerun after a failure: rerunning
creates another CT. Use `pct list` to find the existing `ovms` container and
inspect it with `pct config <CTID>`.

If a run stopped after the CT was created, the helper can retry installation
in that existing running CT. It verifies the CTID, running state, hostname,
and Intel render-device mapping, then asks for confirmation. Run:

```bash
# Replace 120 with the CTID shown by `pct list`.
bash -c "$(curl -fsSL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/main/ovms-lxc-helper.sh)" _ --repair 120
```

The LXC console automatically logs in as root on tty1, like Community Scripts
containers. This is only the Proxmox console; the helper does not enable SSH
or root network login. The container also includes `ovms-helper` for service
status, restart, logs, and Ubuntu package updates (`update-os`).

Alternatively, copy the file to the Proxmox host and run:

```bash
bash /root/ovms-lxc-helper.sh
```

## After installation

The Home Assistant / LLM Vision OpenAI-compatible base URL is:

```text
http://<CT-IP>:8000/v1
```

Use model name `qwen3-vl-4b`. The server currently has no API authentication;
keep it on your trusted LAN or restrict access with the Proxmox firewall.

Useful Proxmox-host commands (replace `CTID` with the ID printed by the helper):

```bash
pct exec CTID -- systemctl status ovms
pct exec CTID -- journalctl -u ovms -f
pct exec CTID -- clinfo -l
pct exec CTID -- ovms-helper status
```

The script pins the OVMS release and verifies the matching Ubuntu 24.04
Python-enabled archive's SHA-256 before installing it. Review the script
before running it as root on Proxmox.
