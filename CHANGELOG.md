# Changelog

## 1.4.0

Fixes from a repository audit and a read-only check of a live v1.2.0 container.

### GPU-only enforcement
- The service runs `ovms-validate-device` before starting. It refuses anything other than `GPU` or `GPU.<n>`, so an empty, `CPU`, or `AUTO` value can no longer start OVMS on CPU.
- The health check fails if `clinfo` cannot see the Intel GPU as the `ovms` user. It also confirms that the running OVMS process was started with `--target_device GPU` and holds a `/dev/dri/renderD*` node.
- The model name is read from `/etc/ovms/ovms.env`, and `/v1/models` is parsed as JSON instead of matched with `grep`.

### Existing containers
- New `--check <CTID>`: a read-only report of the helper version, CPU-fallback leftovers, device, GPU mapping, service state, endpoint, disk, snapshots, and SSH.
- New `--update <CTID>`: takes a snapshot, then runs the in-container update. It refuses to run on containers that still have v1.2.x CPU-fallback scripts.
- `--repair` now takes a snapshot first and backs up each replaced file to `/var/backups/ovms-helper/<timestamp>/`. It detects extra OVMS arguments (such as `--allowed_media_domains`), including those in hand-edited `ExecStart` lines from older versions, and shows them in an editable prompt. The confirmed value is stored in `OVMS_EXTRA_ARGS`. The repair dialog also says that the Intel runtime is upgraded.
- `--repair` reuses the container's existing `devN` render mapping instead of always writing `dev0`. It restarts the container only when the mapping or features change.
- OVMS is extracted to a staging directory and swapped into `/opt/ovms`, so files from two versions never mix. The previous tree is kept as `/opt/ovms.prev`.
- Proxmox notes written by the helper are updated to the new version. Notes you wrote yourself are left alone.

### Fresh installs
- **Fixes a fresh-install failure.** OVMS 2026.4.0 aborted with `free(): invalid next size (fast)` in a restart loop when the service had to download the missing model itself. The model is now downloaded by a separate `ovms --pull` step (`/usr/local/sbin/ovms-pull-model`, also available as `ovms-helper pull`) before the service first starts. That step retries, and interrupted downloads resume.
- Detects the Intel render node by PCI vendor instead of assuming `renderD128`.
- Waits for container DNS/network before running `apt-get`.
- Advanced Setup adds a static IPv4 address and gateway, a VLAN tag, and allowed image-URL domains.
- The root password is set over stdin rather than on the `pct create` command line.
- Errors no longer claim a container was "left in place" when none was created. Failures inside the container now report the failing line and command.
- `numpy` is pinned. Intel runtime package versions are recorded in `/etc/ovms/runtime-versions.txt`.

### Service and update
- `--check` exits 1 when any item needs attention. Host commands run with `LC_ALL=C.UTF-8`, which avoids setlocale warnings inside the guest.
- `RestartSec=30` with a start limit (10 starts in 15 minutes) replaces an endless 5-second restart loop.
- `update` checks for 2 GiB free, keeps existing config files on package upgrades (`--force-confold`), stops OVMS only after `apt-get update` succeeds, and reminds you that OVMS itself is not updated.

### Documentation
- Covers the new modes and the migration path from v1.2.x, and corrects the SSH wording (the Ubuntu template runs `sshd`).
- Explains that `update` does not update OVMS, describes `OVMS_EXTRA_ARGS` and `--allowed_media_domains`, and recommends downloading the script from a release tag.
- The GPU is now described as "Intel Arrow Lake" rather than "Arrow Lake-P".

## 1.3.0
- Switched to the `VLM` pipeline on GPU and removed the CPU fallback.

## 1.2.0
- Added repair mode, an ownership marker, the in-container `update`, and a health-tested CPU fallback (removed in 1.3.0).
