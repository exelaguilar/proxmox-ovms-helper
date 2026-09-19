#!/usr/bin/env bash
# Personal Proxmox VE helper: creates an Ubuntu LXC and installs native OVMS.
# Standalone implementation following the Community Scripts interaction style.
# It creates a new CT only; it does not modify existing guests.
set -Eeuo pipefail

readonly OVMS_VERSION="2026.4.0"
readonly OVMS_ARCHIVE="ovms_ubuntu24_${OVMS_VERSION}_python_on.tar.gz"
# Official digest for this exact Ubuntu 24.04 Python-enabled release asset.
readonly OVMS_SHA256="4a142a7a7409d91299f115562c587b342c74f3b6749b588ac8e40c8f977dcbf8"
readonly OVMS_MODEL_ID="OpenVINO/Qwen3-VL-4B-Instruct-int4-ov"
readonly OVMS_MODEL_NAME="qwen3-vl-4b"
readonly OVMS_RELEASE_URL="https://github.com/openvinotoolkit/model_server/releases/download/v${OVMS_VERSION}/${OVMS_ARCHIVE}"

header_info() {
  printf '\033[1;36m\n  OpenVINO Model Server LXC\n  Intel GPU · Ubuntu 24.04 · no Docker\033[0m\n\n'
}

msg_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
msg_ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
msg_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { msg_error "$*"; exit 1; }

on_error() {
  local status="$1" line="$2"
  trap - ERR
  msg_error "Setup stopped at line ${line} (exit ${status})."
  if [[ -n "${CTID:-}" ]]; then
    msg_error "Container ${CTID} was left in place for troubleshooting; it was not deleted."
    msg_error "Reset its console password from the host with: pct exec ${CTID} -- passwd"
  fi
  exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

check_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this on the Proxmox VE host as root."
}

arch_check() {
  [[ "$(dpkg --print-architecture 2>/dev/null || true)" == amd64 ]] || die "This installer requires an amd64 Proxmox host with Intel graphics."
}

pve_check() {
  local version major_minor
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pveversion not found)."
  version="$(pveversion | awk -F/ 'NR == 1 { print $2 }' | cut -d- -f1)"
  major_minor="$(cut -d. -f1-2 <<<"$version")"
  case "$major_minor" in
    8.4|8.5|8.6|8.7|8.8|8.9|9.0|9.1|9.2) ;;
    *) die "Unsupported Proxmox VE version '${version:-unknown}'. This helper is checked for PVE 8.4-8.9 and 9.0-9.2." ;;
  esac
}

ssh_check() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    if whiptail --backtitle "OVMS Proxmox Helper" --defaultno --title "SSH SESSION DETECTED" \
      --yesno "It is safer to run this from the Proxmox web shell. Continue over SSH?" 10 68; then
      :
    else
      die "Cancelled from SSH session."
    fi
  fi
}

check_root
REPAIR_CTID=""
if [[ "$#" -gt 0 ]]; then
  [[ "$#" -eq 2 && "$1" == --repair ]] || die "Usage: $0 [--repair CTID]"
  REPAIR_CTID="$2"
fi
pve_check
arch_check
for required in pct pvesh pvesm pveam whiptail openssl curl sha256sum; do
  command -v "$required" >/dev/null 2>&1 || die "Required command not found: ${required}."
done
[[ -t 0 && -t 1 ]] || die "Run this helper from an interactive Proxmox shell."
ssh_check
header_info
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

validate_repair_ct() {
  local candidate="$1" config hostname
  [[ "$candidate" =~ ^[1-9][0-9]{2,5}$ ]] || die "CTID must be between 100 and 999999, with no leading zero."
  [[ -f "/etc/pve/lxc/${candidate}.conf" ]] || die "LXC ${candidate} does not exist on this node."
  config="$(pct config "$candidate")"
  hostname="$(awk -F': ' '$1 == "hostname" { print $2; exit }' <<<"$config")"
  [[ -n "$hostname" ]] || die "Could not read the hostname for LXC ${candidate}."
  REPAIR_HOSTNAME="$hostname"
  grep -Eq '^dev[0-9]+: .*renderD128' <<<"$config" || die "LXC ${candidate} does not have /dev/dri/renderD128 mapped; refusing to modify it."
  pct status "$candidate" | grep -q 'status: running' || die "LXC ${candidate} must be running before repair."
}

active_storages() {
  local content="$1"
  pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'
}

ask_default() {
  local prompt="$1" default="$2" answer
  answer="$(whiptail --backtitle "OVMS Proxmox Helper" --title "ADVANCED SETTINGS" \
    --inputbox "$prompt" 10 72 "$default" 3>&1 1>&2 2>&3)" || die "Advanced setup cancelled."
  printf '%s' "$answer"
}

start_script() {
  local result=0
  if whiptail --backtitle "OVMS Proxmox Helper" --title "SETUP MODE" \
    --yesno "Use Default Settings?

Default: next free CTID, 8 cores, 16 GiB RAM, 32 GiB disk, DHCP.
Advanced: edit CT resources, bridge, and storage." \
    --no-button "Advanced" 12 72; then
    MODE="default"
  else
    result=$?
    (( result == 1 )) || die "Setup mode selection cancelled."
    MODE="advanced"
  fi
  msg_info "Using ${MODE^} Settings"
}

choose_storage() {
  local label="$1" content="$2" preferred="$3" choices selected item
  local -a menu=()
  choices="$(active_storages "$content")"
  [[ -n "$choices" ]] || die "No active Proxmox storage supports content type '$content'."
  if grep -Fxq "$preferred" <<<"$choices"; then
    selected="$preferred"
  else
    selected="$(head -n1 <<<"$choices")"
  fi
  if [[ "$MODE" == advanced ]]; then
    while IFS= read -r item; do
      [[ -n "$item" ]] && menu+=("$item" "Active · ${content}")
    done <<<"$choices"
    selected="$(whiptail --backtitle "OVMS Proxmox Helper" --title "STORAGE" \
      --menu "$label storage" 16 72 8 "${menu[@]}" 3>&1 1>&2 2>&3)" || die "Storage selection cancelled."
  fi
  grep -Fxq "$selected" <<<"$choices" || die "Storage '$selected' is not active for content type '$content'."
  msg_info "$label storage: $selected" >&2
  printf '%s' "$selected"
}

install_ovms() {
  local target_ct="$1"
  msg_info "Installing Intel GPU userspace runtime and native OVMS ${OVMS_VERSION} in CT ${target_ct}"
  pct exec "$target_ct" -- env \
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
  ca-certificates curl libxml2 libpython3.12-dev software-properties-common \
  python3-pip python3-venv

# Intel's Ubuntu compute packages provide the userspace Level Zero/OpenCL
# runtime; the i915 kernel driver remains on the Proxmox host.
add-apt-repository -y ppa:kobuk-team/intel-graphics
apt-get update
apt-get install -y --no-install-recommends \
  libze-intel-gpu1 libze1 intel-metrics-discovery intel-opencl-icd clinfo intel-gsc

if ! clinfo -l 2>&1 | grep -qi 'Intel'; then
  echo "Intel GPU not visible inside the LXC; stopping before OVMS/model download." >&2
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

# Match the Community Scripts console convenience. This is only LXC tty1
# autologin; it does not enable SSH or network password login.
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p "$(dirname "$GETTY_OVERRIDE")"
cat >"$GETTY_OVERRIDE" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF

cat >/etc/profile.d/00-ovms-details.sh <<'EOF'
[ -t 1 ] || return 0
printf '\nOpenVINO Model Server LXC\n'
printf 'Hostname: %s\n' "$(hostname)"
printf 'IP: %s\n' "$(hostname -I | awk '{print $1}')"
printf 'Service: systemctl status ovms\n'
printf 'Helper: ovms-helper status|restart|logs|update-os\n\n'
EOF

cat >/usr/local/bin/ovms-helper <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  status) systemctl status ovms --no-pager ;;
  restart) systemctl restart ovms ;;
  logs) journalctl -u ovms -f ;;
  update-os) apt-get update && apt-get full-upgrade -y ;;
  *) printf 'Usage: ovms-helper {status|restart|logs|update-os}\n' >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/ovms-helper

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
systemctl restart container-getty@1.service
systemctl enable --now ovms.service
IN_CONTAINER
}

if [[ -n "$REPAIR_CTID" ]]; then
  CTID="$REPAIR_CTID"
  validate_repair_ct "$CTID"
  if ! whiptail --backtitle "OVMS Proxmox Helper" --title "REPAIR EXISTING CONTAINER" \
    --yesno "Retry OVMS installation inside existing CT ${CTID} (${REPAIR_HOSTNAME})?

Only this running CT will be changed. Confirm this is the partial OVMS container and that its Intel GPU mapping is present. No new container will be created." 14 76; then
    msg_info "Repair cancelled; no changes were made."
    exit 0
  fi
  install_ovms "$CTID"
  CT_HOSTNAME="$(pct config "$CTID" | awk -F': ' '$1 == "hostname" { print $2; exit }')"
  CT_IP="$(pct exec "$CTID" -- bash -lc 'hostname -I | awk "{print \\$1}"' 2>/dev/null | tr -d '[:space:]' || true)"
  msg_ok "Repair submitted; OVMS downloads and initializes the model on first startup."
  printf '\nContainer: %s (%s); GPU device: /dev/dri/renderD128\n' "$CTID" "$CT_HOSTNAME"
  printf 'OpenAI-compatible endpoint: http://%s:8000/v1\n' "${CT_IP:-<CT-IP>}"
  printf 'Model name for clients: %s\n' "$OVMS_MODEL_NAME"
  printf 'Logs: pct exec %s -- journalctl -u ovms -f\n' "$CTID"
  printf 'Console autologin: enabled on LXC tty1 only; SSH is not enabled by this helper.\n'
  printf 'In-container helper: ovms-helper {status|restart|logs|update-os}\n'
  exit 0
fi

start_script

AUTO_ID="$(available_id)"
if [[ "$MODE" == advanced ]]; then
  CTID="$(ask_default 'Container ID (CTID)' "$AUTO_ID")"
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

msg_info "Refreshing Proxmox template catalog"
pveam update
TEMPLATE="$(pveam available --section system | awk 'NF >= 2 && $2 ~ /^ubuntu-24\.04-standard_/ { print $2 }' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || die "Could not find an Ubuntu 24.04 LXC template."
TEMPLATE_VOL="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
if ! pvesm path "$TEMPLATE_VOL" >/dev/null 2>&1; then
  msg_info "Downloading template ${TEMPLATE} to ${TEMPLATE_STORAGE}"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

PLAN="Create a NEW container with these settings?

CTID: ${CTID}
Hostname: ${HOSTNAME}
CPU: ${CORES} cores
RAM: ${MEMORY} MiB
Root disk: ${ROOTFS_GB} GiB
Root storage: ${ROOT_STORAGE}
Template storage: ${TEMPLATE_STORAGE}
Bridge: ${BRIDGE} (DHCP)

The model is downloaded inside this CT on first service startup (~3.1 GB). Existing guests are not modified."
if ! whiptail --backtitle "OVMS Proxmox Helper" --title "CONFIRM INSTALLATION" --yesno "$PLAN" 22 78; then
  msg_info "Cancelled; no container was created."
  exit 0
fi

ROOT_PASSWORD="$(openssl rand -hex 20)"
GPU_NODE='/dev/dri/renderD128'

msg_info "Creating CT ${CTID}; existing containers and VMs are not modified"
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
msg_ok "Container ${CTID} created with Intel render device mapped"
pct start "$CTID"

msg_info "Waiting for Ubuntu container to boot"
for attempt in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CTID" -- true >/dev/null 2>&1 || die "CT ${CTID} did not become ready. It is preserved for troubleshooting."

install_ovms "$CTID"

CT_IP="$(pct exec "$CTID" -- bash -lc 'hostname -I | awk "{print \$1}"' 2>/dev/null | tr -d '[:space:]' || true)"

msg_ok "Installation submitted; OVMS downloads and initializes the model on first startup."
printf '\nContainer: %s (%s); GPU device: %s\n' "$CTID" "$HOSTNAME" "$GPU_NODE"
printf 'OpenAI-compatible endpoint: http://%s:8000/v1\n' "${CT_IP:-<CT-IP>}"
printf 'Model name for clients: %s\n' "$OVMS_MODEL_NAME"
printf 'Logs: pct exec %s -- journalctl -u ovms -f\n' "$CTID"
printf 'Status: pct exec %s -- systemctl status ovms\n' "$CTID"
printf 'Console autologin: enabled on LXC tty1 only; SSH is not enabled by this helper.\n'
printf 'In-container helper: ovms-helper {status|restart|logs|update-os}\n'
printf 'The API has no authentication configured; keep it on your trusted LAN or firewall it to Home Assistant.\n'
printf 'Root console password: %s\n' "$ROOT_PASSWORD"
