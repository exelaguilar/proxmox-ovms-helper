#!/usr/bin/env bash
# Personal Proxmox VE helper: creates an Ubuntu LXC and installs native OVMS.
# No Docker. This script only creates a new CT; it does not modify existing guests.
set -Eeuo pipefail

readonly OVMS_VERSION="2026.4.0"
readonly OVMS_ARCHIVE="ovms_ubuntu24_${OVMS_VERSION}_python_on.tar.gz"
readonly OVMS_SHA256="bb14ef8987bf4e3796905b89cba01ac92acd9599dc42e5d8a46fdbfafd660e12"
readonly OVMS_MODEL_ID="OpenVINO/Qwen3-VL-4B-Instruct-int4-ov"
readonly OVMS_MODEL_NAME="qwen3-vl-4b"
readonly OVMS_RELEASE_URL="https://github.com/openvinotoolkit/model_server/releases/download/v${OVMS_VERSION}/${OVMS_ARCHIVE}"

say() { printf '\n[OVMS LXC] %s\n' "$*"; }
die() { printf '\n[OVMS LXC] ERROR: %s\n' "$*" >&2; exit 1; }
ask_default() {
  local prompt="$1" default="$2" answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

[[ "${EUID}" -eq 0 ]] || die "Run this on the Proxmox VE host as root."
command -v pct >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pct not found)."
command -v pvesh >/dev/null 2>&1 || die "pvesh is required to allocate a free container ID."
[[ -c /dev/dri/renderD128 ]] || die "Host GPU render node /dev/dri/renderD128 is missing. No changes made."

if ! pct help set 2>&1 | grep -Eq -- '--dev|dev\[n\]'; then
  die "This Proxmox version does not advertise pct --dev[n] device mapping. Upgrade Proxmox VE before using this installer."
fi

available_id() {
  local candidate
  candidate="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]')"
  [[ "$candidate" =~ ^[0-9]+$ ]] || die "Could not get the next free guest ID from Proxmox."
  while [[ -e "/etc/pve/lxc/${candidate}.conf" || -e "/etc/pve/qemu-server/${candidate}.conf" ]]; do
    candidate=$((candidate + 1))
  done
  printf '%s' "$candidate"
}

validate_id() {
  local candidate="$1"
  [[ "$candidate" =~ ^[1-9][0-9]{2,5}$ ]] || die "CTID must be between 100 and 999999, with no leading zero."
  [[ ! -e "/etc/pve/lxc/${candidate}.conf" && ! -e "/etc/pve/qemu-server/${candidate}.conf" ]] || die "Guest ID ${candidate} is already in use. Nothing was changed."
}

active_storages() {
  local content="$1"
  pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'
}

choose_storage() {
  local label="$1" content="$2" preferred="$3" choices selected
  choices="$(active_storages "$content")"
  [[ -n "$choices" ]] || die "No active Proxmox storage supports content type '$content'."
  if grep -Fxq "$preferred" <<<"$choices"; then
    selected="$preferred"
  else
    selected="$(head -n1 <<<"$choices")"
  fi
  printf '%s\n' "$label supports: $(tr '\n' ' ' <<<"$choices")" >&2
  selected="$(ask_default "$label storage" "$selected")"
  grep -Fxq "$selected" <<<"$choices" || die "Storage '$selected' is not active for content type '$content'."
  printf '%s' "$selected"
}

MODE="$(ask_default 'Choose setup mode: 1=Default, 2=Advanced' '1')"
[[ "$MODE" == 1 || "$MODE" == 2 ]] || die "Choose 1 or 2."

AUTO_ID="$(available_id)"
if [[ "$MODE" == 2 ]]; then
  read -r -p "CTID (blank for next free ID ${AUTO_ID}): " REQUESTED_ID
  CTID="${REQUESTED_ID:-$AUTO_ID}"
  validate_id "$CTID"
  HOSTNAME="$(ask_default 'Container hostname' 'ovms')"
  CORES="$(ask_default 'CPU cores' '8')"
  MEMORY="$(ask_default 'RAM (MiB)' '16384')"
  SWAP="$(ask_default 'Swap (MiB)' '4096')"
  ROOTFS_GB="$(ask_default 'Root disk (GiB)' '32')"
  BRIDGE="$(ask_default 'Network bridge' 'vmbr0')"
else
  CTID="$AUTO_ID"
  HOSTNAME='ovms'
  CORES=8
  MEMORY=16384
  SWAP=4096
  ROOTFS_GB=32
  BRIDGE='vmbr0'
fi

for value_name in CORES MEMORY SWAP ROOTFS_GB; do
  value="${!value_name}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$value_name must be a whole number."
done
CORES=$((10#$CORES))
MEMORY=$((10#$MEMORY))
SWAP=$((10#$SWAP))
ROOTFS_GB=$((10#$ROOTFS_GB))
(( CORES >= 2 && CORES <= 128 )) || die "CPU cores must be between 2 and 128."
(( MEMORY >= 8192 && MEMORY <= 98304 )) || die "RAM must be between 8192 and 98304 MiB for this vision model."
(( SWAP <= 32768 )) || die "Swap must be no more than 32768 MiB."
(( ROOTFS_GB >= 20 && ROOTFS_GB <= 512 )) || die "Root disk must be between 20 and 512 GiB."
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Invalid hostname."
[[ -d "/sys/class/net/${BRIDGE}" ]] || die "Network bridge '$BRIDGE' does not exist on this host."

ROOT_STORAGE="$(choose_storage 'Container root disk' rootdir local-lvm)"
TEMPLATE_STORAGE="$(choose_storage 'Ubuntu template' vztmpl local)"

say "Refreshing Proxmox template catalog..."
pveam update
TEMPLATE="$(pveam available --section system | awk 'NF >= 2 && $2 ~ /^ubuntu-24\.04-standard_/ { print $2 }' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || die "Could not find an Ubuntu 24.04 LXC template."
TEMPLATE_VOL="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
if ! pvesm path "$TEMPLATE_VOL" >/dev/null 2>&1; then
  say "Downloading template ${TEMPLATE} to ${TEMPLATE_STORAGE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

say "Plan: CT ${CTID}, ${HOSTNAME}, ${CORES} cores, ${MEMORY} MiB RAM, ${ROOTFS_GB} GiB root disk, bridge ${BRIDGE}."
say "Model files will live inside this CT. First startup downloads about 3.1 GB from Hugging Face."
read -r -p 'Create this new container? [y/N] ' CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { say "Cancelled; no container was created."; exit 0; }

ROOT_PASSWORD="$(openssl rand -hex 20)"
GPU_NODE='/dev/dri/renderD128'

say "Creating CT ${CTID} (existing containers and VMs are not modified)..."
pct create "$CTID" "$TEMPLATE_VOL" \
  --ostype ubuntu \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${ROOT_STORAGE}:${ROOTFS_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --onboot 1 \
  --password "$ROOT_PASSWORD"

# OVMS only needs the render node. Give it root:root ownership within this
# isolated, unprivileged CT; mode 0660 keeps access limited to root processes.
pct set "$CTID" --dev0 "path=${GPU_NODE},uid=0,gid=0,mode=0660"
pct start "$CTID"

say "Waiting for Ubuntu container to boot..."
for attempt in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CTID" -- true >/dev/null 2>&1 || die "CT ${CTID} did not become ready. It is preserved for troubleshooting."

say "Installing Intel GPU userspace runtime and native OVMS ${OVMS_VERSION}..."
pct exec "$CTID" -- env \
  OVMS_VERSION="$OVMS_VERSION" \
  OVMS_ARCHIVE="$OVMS_ARCHIVE" \
  OVMS_SHA256="$OVMS_SHA256" \
  OVMS_RELEASE_URL="$OVMS_RELEASE_URL" \
  OVMS_MODEL_ID="$OVMS_MODEL_ID" \
  OVMS_MODEL_NAME="$OVMS_MODEL_NAME" \
  bash -s <<'IN_CONTAINER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl libxml2 software-properties-common \
  python3-pip python3-venv

# Intel's Ubuntu compute packages provide the userspace Level Zero/OpenCL
# runtime; the i915 kernel driver remains on the Proxmox host.
add-apt-repository -y ppa:kobuk-team/intel-graphics
apt-get update
apt-get install -y --no-install-recommends \
  libze-intel-gpu1 libze1 intel-metrics-discovery intel-opencl-icd clinfo intel-gsc

if ! clinfo -l 2>&1 | grep -qi 'Intel'; then
  echo "Intel GPU not visible inside the new LXC; stopping before OVMS/model download." >&2
  exit 1
fi

mkdir -p /opt /var/lib/ovms/models /etc/ovms
cd /tmp
curl -fL --retry 3 "$OVMS_RELEASE_URL" -o "$OVMS_ARCHIVE"
echo "$OVMS_SHA256  $OVMS_ARCHIVE" | sha256sum --check --status || {
  echo "OVMS archive SHA256 verification failed" >&2
  exit 1
}
tar -xzf "$OVMS_ARCHIVE" -C /opt
[[ -x /opt/ovms/bin/ovms ]] || { echo "Expected /opt/ovms/bin/ovms after extraction" >&2; exit 1; }

# OVMS's Python-enabled native bundle needs these chat-template dependencies.
python3 -m pip install --break-system-packages \
  'Jinja2==3.1.6' 'MarkupSafe==3.0.2' numpy

cat >/etc/systemd/system/ovms.service <<EOF
[Unit]
Description=OpenVINO Model Server (Intel GPU)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/ovms
Environment=LD_LIBRARY_PATH=/opt/ovms/lib
Environment=PATH=/opt/ovms/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONPATH=/opt/ovms/lib/python
ExecStart=/opt/ovms/bin/ovms --source_model ${OVMS_MODEL_ID} --model_repository_path /var/lib/ovms/models --model_name ${OVMS_MODEL_NAME} --rest_port 8000 --task text_generation --pipeline_type VLM_CB --target_device GPU
Restart=on-failure
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ovms.service
IN_CONTAINER

CT_IP="$(pct exec "$CTID" -- bash -lc 'hostname -I | awk "{print \$1}"' 2>/dev/null | tr -d '[:space:]' || true)"

say "Install submitted. OVMS will download and initialize the model on first start."
say "Container: ${CTID} (${HOSTNAME}); GPU device: ${GPU_NODE}"
say "OpenAI-compatible endpoint: http://${CT_IP:-<CT-IP>}:8000/v1"
say "Model name for clients: ${OVMS_MODEL_NAME}"
say "Logs: pct exec ${CTID} -- journalctl -u ovms -f"
say "Status: pct exec ${CTID} -- systemctl status ovms"
say "The API has no authentication configured; keep it on your trusted LAN / firewall it to Home Assistant."
say "Root console password generated for this CT: ${ROOT_PASSWORD}"
