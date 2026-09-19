# Installation and operation

This guide covers the personal Proxmox helper at the repository root. The script is designed to create a **new** Ubuntu LXC; it does not replace Ollama or modify existing guests during a normal install.

## Requirements and defaults

- Proxmox VE 8.4+ (8.x) or Proxmox VE 9.x on amd64.
- An Intel GPU and host render node at `/dev/dri/renderD128`.
- Active Proxmox bridge and storage with room for an Ubuntu template and a 48 GiB default root disk.
- The installer is interactive and must be run as root from a terminal.

The created guest is an unprivileged Ubuntu 24.04 LXC with `nesting=1,keyctl=1`, tty1 root-console autologin, and no SSH/root network login enabled by this helper. Default sizing is 8 CPU cores, 16 GiB RAM, and a 48 GiB root disk. Advanced Setup lets you change the container ID, resources, bridge, and storage.

OVMS 2026.4.0 is installed as a native service. The initial model, `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`, is downloaded from Hugging Face on first startup and uses about 3.1 GB. The installer verifies the pinned OVMS archive checksum before installing it.

## Install

Review the script, then run it on the Proxmox VE host:

```bash
curl -fL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/main/ovms-lxc-helper.sh -o /root/ovms-lxc-helper.sh
less /root/ovms-lxc-helper.sh
bash /root/ovms-lxc-helper.sh
```

The script checks the host GPU, render node, Proxmox version, storage, and network, then shows an install plan for confirmation. It runs text and synthetic-image inference checks on the configured GPU before reporting success. A failed check stops setup; the helper does not switch the service to CPU. If failure occurs after creating the LXC, the guest is preserved for diagnosis. Do not blindly rerun the normal installer, as that could create another container.

To repair a partial container owned by this helper, identify its CTID with `pct list`, then run the current script from the Proxmox host:

```bash
bash /root/ovms-lxc-helper.sh --repair <CTID>
```

Repair validates the guest and ownership marker before applying setup. A legacy guest without that marker requires explicit adoption confirmation. Read the script's plan carefully before approving any changes.

## Home Assistant / LLM Vision

Add a **Custom OpenAI** provider; keep the existing Ollama provider if you want a rollback option. Use the model name `qwen3-vl-4b`.

- If the endpoint field's placeholder shows `/v1/chat/completions`, enter `http://<CT-IP>:8000/v1/chat/completions`.
- If the integration asks for a base URL without `/chat/completions`, enter `http://<CT-IP>:8000/v1`.
- If an API key is required, `openai` is a dummy value; this OVMS setup does not require a key.

Choose the new provider in the LLM Vision action or camera-event blueprint. Reserve the LXC's DHCP address so the endpoint stays stable. This service does not configure authentication or TLS; see [OVMS security guidance](https://docs.openvino.ai/2026/model-server/ovms_docs_security.html). Keep it on a trusted LAN and preferably restrict port 8000 to Home Assistant using the Proxmox firewall.

## Console and commands

The tty1 console automatically logs in as root and shows the guest's OS, hostname, IP, API endpoint, and service commands. This is console-only; the helper does not enable SSH.

Inside the LXC:

```bash
update                       # Update OS/runtime packages, restart OVMS, GPU health-check
ovms-helper status
ovms-helper restart
ovms-helper logs
ovms-helper healthcheck      # Test configured device; no CPU fallback
```

`update` updates packages and retests inference; it does not download a newer copy of the Proxmox installer script. To use a newer installer for a future install or repair, fetch the latest script from this repository on the Proxmox host and review it first.

## Host-side diagnostics

Replace `<CTID>` with the OVMS container ID:

```bash
pct exec <CTID> -- systemctl status ovms
pct exec <CTID> -- journalctl -u ovms -f
pct exec <CTID> -- clinfo -l
pct exec <CTID> -- /usr/local/sbin/ovms-healthcheck
```
