# Installation and operation

This guide covers the personal Proxmox helper at the repository root. A normal run creates a **new** Ubuntu LXC and does not modify existing guests. The `--check`, `--update`, and `--repair` modes act only on the container ID you give them.

## Requirements and defaults

- Proxmox VE 8.4+ (8.x) or Proxmox VE 9.x on amd64.
- An Intel GPU with a host render node (`/dev/dri/renderD*`). The helper picks the render node whose PCI vendor is Intel, so it also works on hosts with more than one GPU.
- Active Proxmox bridge and storage with room for an Ubuntu template and a 48 GiB default root disk.
- The installer is interactive and must be run as root from a terminal. `--check` also works non-interactively.

The created guest is an unprivileged Ubuntu 24.04 LXC with `nesting=1,keyctl=1` and tty1 root-console autologin. Default sizing is 8 CPU cores, 16 GiB RAM, 4 GiB swap, a 48 GiB root disk, and DHCP on `vmbr0`. Advanced Setup lets you change the container ID, resources, storage, bridge, static IPv4 address and gateway, VLAN tag, and allowed image-URL domains.

**SSH:** the helper does not enable or disable SSH. The Proxmox Ubuntu template already runs `sshd`, with root login limited to SSH keys. If you do not use SSH, disable it inside the container with `systemctl disable --now ssh.socket ssh.service`.

OVMS 2026.4.0 is installed as a native service under `/opt/ovms`. The installer verifies the pinned OVMS archive checksum before installing it. The model, `OpenVINO/Qwen3-VL-4B-Instruct-int4-ov`, is downloaded from Hugging Face on first startup and uses about 3.1 GB. The Intel GPU runtime comes from the `ppa:kobuk-team/intel-graphics` PPA, which is not version-pinned. The installed versions are recorded in `/etc/ovms/runtime-versions.txt`.

## Install

Review the script, then run it on the Proxmox VE host. Use a release tag so the script you reviewed is the one you run:

```bash
curl -fL https://raw.githubusercontent.com/exelaguilar/proxmox-ovms-helper/v1.4.0/ovms-lxc-helper.sh -o /root/ovms-lxc-helper.sh
less /root/ovms-lxc-helper.sh
bash /root/ovms-lxc-helper.sh
```

The script checks the host GPU, render node, Proxmox version, storage, and network, then shows an install plan for confirmation. It waits for the container's network and DNS before installing packages. It then runs text and synthetic-image inference checks on the GPU before reporting success. A failed check stops setup; the helper never switches the service to CPU. If failure occurs after creating the LXC, the guest is preserved for diagnosis. Do not blindly rerun the normal installer, as that could create another container. Use `--repair` instead.

The root console password is generated randomly, set over stdin (it never appears in the host process list), and printed once at the end.

## Check, update, and repair

All three run on the Proxmox host and act only on the container ID you give them.

```bash
bash /root/ovms-lxc-helper.sh --check <CTID>     # read-only report; changes nothing
bash /root/ovms-lxc-helper.sh --update <CTID>    # snapshot, then update + GPU health check
bash /root/ovms-lxc-helper.sh --repair <CTID>    # snapshot, then reinstall OVMS and helper scripts
```

- **`--check`** reports the helper version inside the container and whether old CPU-fallback logic is present. It also shows the configured device and the device the running OVMS process was started with, and whether that process holds the GPU render node. It covers the render-group GID mapping, `clinfo` as the `ovms` user, service state and restart count, the `/v1/models` endpoint, free disk space, extra OVMS arguments, snapshots, and whether `sshd` is listening.
- **`--update`** refuses to run if the container still has CPU-fallback scripts from an old helper version. Otherwise it takes a snapshot named `ovms-update-<timestamp>` and runs the container's `update`. If the GPU health check fails afterwards, roll back with `pct rollback <CTID> <snapshot>`.
- **`--repair`** takes a snapshot named `ovms-repair-<timestamp>`, backs up each file it replaces to `/var/backups/ovms-helper/<timestamp>/` inside the container, and reinstalls OVMS and the helper scripts. It keeps any extra OVMS arguments it finds (see below). The container is restarted only if its GPU mapping or features need to change. OVMS is unavailable while it reinstalls and reloads the model.

If the container's storage cannot take snapshots, the helper asks before continuing without one. Snapshots are not removed automatically; delete them with `pct delsnapshot <CTID> <snapshot>` once you are satisfied.

A legacy container without the helper's ownership marker can be adopted by `--repair` only if its hostname is `ovms` and it has an `ovms.service`. You are asked to confirm the adoption.

### Upgrading an existing container

Containers installed with helper v1.2.x or earlier have CPU-fallback logic in `ovms-helper` and `ovms-healthcheck`. Running `update` inside them can switch OVMS to CPU when a GPU check fails. To migrate:

1. Run `--check <CTID>` and note the "Extra OVMS arguments that --repair will keep" line.
2. Run `--repair <CTID>`. Confirm that the dialog lists the same extra arguments.
3. Run `--check <CTID>` again. It should report the current helper version and no CPU-fallback logic.

## Extra OVMS arguments

OVMS flags that the helper does not manage live in `OVMS_EXTRA_ARGS` in `/etc/ovms/ovms.env`, for example:

```bash
OVMS_EXTRA_ARGS="--allowed_media_domains 192.168.1.33"
```

`--allowed_media_domains` is needed when a client sends an image URL instead of inline base64 data. After editing the file, run `systemctl restart ovms`. `--repair` keeps this value. When it upgrades a container whose unit file was edited by hand, it moves any unmanaged flags from `ExecStart` into this variable.

`OVMS_TARGET_DEVICE` in the same file must stay `GPU` (or `GPU.<n>`). The service's start check refuses anything else, including `CPU` and `AUTO`.

## Home Assistant / LLM Vision

Add a **Custom OpenAI** provider. Use the model name `qwen3-vl-4b`.

- If the endpoint field's placeholder shows `/v1/chat/completions`, enter `http://<CT-IP>:8000/v1/chat/completions`.
- If the integration asks for a base URL without `/chat/completions`, enter `http://<CT-IP>:8000/v1`.
- If an API key is required, `openai` is a dummy value; this OVMS setup does not require a key.

Choose the new provider in the LLM Vision action or camera-event blueprint. Give the LXC a static IP (Advanced Setup) or a DHCP reservation so the endpoint stays stable. This service does not configure authentication or TLS; see [OVMS security guidance](https://docs.openvino.ai/2026/model-server/ovms_docs_security.html). Keep it on a trusted LAN and preferably restrict port 8000 to Home Assistant using the Proxmox firewall.

## Console and commands

The tty1 console automatically logs in as root and shows the guest's OS, hostname, IP, API endpoint, and service commands.

Inside the LXC:

```bash
update                       # Update Ubuntu + Intel GPU runtime, restart OVMS, GPU health check
ovms-helper status
ovms-helper restart
ovms-helper logs
ovms-helper healthcheck      # GPU-only text + image inference check; no CPU fallback
```

`update` upgrades Ubuntu packages and the Intel GPU runtime. **It does not update OVMS itself**, which stays at the version the helper installed. To move to a newer OVMS, fetch a newer helper release and run `--repair`. Prefer running `--update <CTID>` from the host, which takes a snapshot first. Intel runtime version changes are logged to `/var/log/ovms-runtime-updates.log`.

The service restarts on failure every 30 seconds. After 10 failed starts within 15 minutes it stays failed, and the health check reports it. After fixing the cause, run `systemctl reset-failed ovms && systemctl restart ovms`.

## Host-side diagnostics

Replace `<CTID>` with the OVMS container ID:

```bash
bash /root/ovms-lxc-helper.sh --check <CTID>
pct exec <CTID> -- systemctl status ovms
pct exec <CTID> -- journalctl -u ovms -f
pct exec <CTID> -- runuser -u ovms -- clinfo -l
pct exec <CTID> -- /usr/local/sbin/ovms-healthcheck
```
