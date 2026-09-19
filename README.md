# OVMS Proxmox LXC helper

This is a personal helper script for installing OpenVINO Model Server (OVMS)
in a new Proxmox LXC. It is an independent project, not an upload or
contribution to the Proxmox Community Scripts project.

It creates a **new** unprivileged Ubuntu 24.04 LXC, maps the host's Intel
`/dev/dri/renderD128` device into it, installs Intel's GPU userspace runtime,
and installs the native OpenVINO Model Server 2026.4.0 bundle as a systemd
service. It does not install Docker and does not alter or delete existing VMs,
containers, Ollama models, or Proxmox storage.

Default mode auto-selects the next unused guest ID. Advanced mode lets you
enter a CTID and adjust storage, CPU, RAM, disk, bridge, and hostname. The
initial model is `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`; its first launch
downloads about 3.1 GB from Hugging Face.

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

The helper asks for confirmation immediately before creating the CT. If setup
fails after creation, the CT is deliberately preserved for troubleshooting.

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
```

The script pins the OVMS release and verifies its published SHA-256 before
installing it. Review the script before running it as root on Proxmox.
