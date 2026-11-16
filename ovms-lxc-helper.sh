#!/usr/bin/env bash
# Personal Proxmox VE helper: creates an Ubuntu LXC and installs native OVMS.
# Standalone implementation following the Community Scripts interaction style.
set -Eeuo pipefail

readonly HELPER_VERSION="1.4.0"
readonly OVMS_VERSION="2026.4.0"
readonly OVMS_ARCHIVE="ovms_ubuntu24_${OVMS_VERSION}_python_on.tar.gz"
# Official digest for this exact Ubuntu 24.04 Python-enabled release asset.
readonly OVMS_SHA256="4a142a7a7409d91299f115562c587b342c74f3b6749b588ac8e40c8f977dcbf8"
readonly OVMS_MODEL_ID="OpenVINO/Qwen3-VL-4B-Instruct-int4-ov"
readonly OVMS_MODEL_NAME="qwen3-vl-4b"
readonly OVMS_RELEASE_URL="https://github.com/openvinotoolkit/model_server/releases/download/v${OVMS_VERSION}/${OVMS_ARCHIVE}"
readonly DEFAULT_ROOTFS_GB=48
readonly MIN_ROOTFS_GB=32
readonly MIN_ROOT_STORAGE_FREE_GB=4
readonly MIN_TEMPLATE_STORAGE_FREE_GB=2
# Characters allowed in extra OVMS arguments carried into ovms.env. Keeps the
# value safe to embed in a systemd EnvironmentFile and a shell-sourced file.
readonly EXTRA_ARGS_RE='^[A-Za-z0-9_.,:/=@+ -]*$'
# OVMS arguments the helper owns; anything else in ExecStart is a local extra.
readonly MANAGED_FLAGS=" --source_model --model_repository_path --model_name --rest_port --task --pipeline_type --target_device "

ACTION="install"
TARGET_CT=""
CTID=""
CT_TOUCHED=0
SNAPSHOT_NAME=""
GPU_NODE=""
OVMS_EXTRA_ARGS=""
CHECK_PROBLEMS=0

# ---------------------------------------------------------------------------
# Output and error handling
# ---------------------------------------------------------------------------

header_info() {
  printf '\033[1;36m\n  OpenVINO Model Server LXC\n  Personal Proxmox VE Helper v%s · Ubuntu 24.04 · Native install\033[0m\n\n' "$HELPER_VERSION"
}

msg_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
msg_ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
msg_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
msg_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { msg_error "$*"; print_ct_context; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $0                  Create a new OVMS LXC (interactive)
       $0 --repair CTID    Reinstall OVMS into an existing helper LXC, keeping local OVMS arguments
       $0 --update CTID    Snapshot the LXC, then run its in-container update and GPU health check
       $0 --check CTID     Read-only report of the LXC's OVMS/GPU state (changes nothing)
EOF
  exit 2
}

# Explains what was left behind. Only the main shell prints it, so a die()
# inside a command substitution does not repeat it.
print_ct_context() {
  if [[ "$CT_TOUCHED" == 1 ]] && (( BASH_SUBSHELL == 0 )); then
    msg_error "Container ${CTID} was left in place for troubleshooting; it was not deleted."
    if [[ "$ACTION" == install ]]; then
      msg_error "If you need its console password, reset it from the host with: pct exec ${CTID} -- passwd"
    fi
    if [[ -n "$SNAPSHOT_NAME" ]]; then
      msg_error "To return to the state before this run: pct rollback ${CTID} ${SNAPSHOT_NAME}"
    fi
  fi
  return 0
}

on_error() {
  local status="$1" line="$2"
  trap - ERR
  msg_error "Stopped at line ${line} (exit ${status})."
  print_ct_context
  exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------

check_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this on the Proxmox VE host as root."
}

arch_check() {
  [[ "$(dpkg --print-architecture 2>/dev/null || true)" == amd64 ]] || die "This installer requires an amd64 Proxmox host with Intel graphics."
}

pve_check() {
  local version major_minor major minor
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pveversion not found)."
  version="$(pveversion | awk -F/ 'NR == 1 { print $2 }' | cut -d- -f1)"
  major_minor="$(cut -d. -f1-2 <<<"$version")"
  [[ "$major_minor" =~ ^([0-9]+)\.([0-9]+)$ ]] || die "Could not parse Proxmox VE version '${version:-unknown}'."
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  (( (major == 8 && minor >= 4) || major == 9 )) || die "Unsupported Proxmox VE version '${version:-unknown}'. This helper requires PVE 8.4 or newer in the 8.x/9.x series."
}

host_gpu_check() {
  local pci_dir vendor device class driver kernel
  local found=0
  kernel="$(uname -r | cut -d- -f1)"
  for pci_dir in /sys/bus/pci/devices/*; do
    [[ -r "$pci_dir/vendor" && -r "$pci_dir/device" && -r "$pci_dir/class" ]] || continue
    vendor="$(<"$pci_dir/vendor")"
    class="$(<"$pci_dir/class")"
    [[ "$vendor" == 0x8086 && "$class" == 0x03* ]] || continue
    device="$(<"$pci_dir/device")"
    driver=""
    if [[ -L "$pci_dir/driver" ]]; then driver="$(basename "$(readlink -f "$pci_dir/driver")")"; fi
    found=1
    msg_info "Intel display device ${vendor}:${device}; host driver: ${driver:-unbound}; kernel: ${kernel}"
    if [[ "$device" == 0x7d51 ]] && dpkg --compare-versions "$kernel" lt 6.9; then
      msg_warn "Intel PCI ID 8086:7d51 may need newer host i915 support. The LXC uses the Proxmox host kernel; GPU inference will be tested before success is reported."
    fi
  done
  (( found == 1 )) || die "No Intel PCI display device was found. This helper requires an Intel GPU on the Proxmox host."
}

# Prints 0 when the given /dev/dri/renderD* node belongs to an Intel GPU.
is_intel_render_node() {
  local node="$1" vendor_file
  [[ "$node" =~ ^/dev/dri/renderD[0-9]+$ && -c "$node" ]] || return 1
  vendor_file="/sys/class/drm/$(basename "$node")/device/vendor"
  [[ -r "$vendor_file" && "$(<"$vendor_file")" == 0x8086 ]]
}

find_intel_render_node() {
  local sys_node node
  for sys_node in /sys/class/drm/renderD*; do
    [[ -e "$sys_node" ]] || continue
    node="/dev/dri/$(basename "$sys_node")"
    if is_intel_render_node "$node"; then
      printf '%s' "$node"
      return 0
    fi
  done
  return 1
}

ssh_check() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    if ! whiptail --backtitle "OVMS Proxmox Helper" --defaultno --title "SSH SESSION DETECTED" \
      --yesno "It is safer to run this from the Proxmox web shell. Continue over SSH?" 10 68; then
      die "Cancelled from SSH session."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Container helpers
# ---------------------------------------------------------------------------

available_id() {
  local candidate
  candidate="$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]')"
  [[ "$candidate" =~ ^[0-9]+$ ]] || die "Could not get the next free guest ID from Proxmox."
  while [[ -e "/etc/pve/lxc/${candidate}.conf" || -e "/etc/pve/qemu-server/${candidate}.conf" ]]; do
    candidate=$((candidate + 1))
  done
  printf '%s' "$candidate"
}

validate_ctid_format() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || die "CTID must be a number of at least 100, with no leading zero."
}

validate_new_id() {
  local candidate="$1"
  validate_ctid_format "$candidate"
  [[ ! -e "/etc/pve/lxc/${candidate}.conf" && ! -e "/etc/pve/qemu-server/${candidate}.conf" ]] || die "Guest ID ${candidate} is already in use. Nothing was changed."
}

ct_running() {
  pct status "$1" 2>/dev/null | grep -q 'status: running'
}

wait_for_ct() {
  local ct="$1"
  for _ in $(seq 1 30); do
    if pct exec "$ct" -- true >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

ct_config_value() {
  pct config "$1" | awk -F': ' -v key="$2" '$1 == key { print $2; exit }'
}

# Prints the /dev/dri/renderD* path from the CT's existing devN mapping.
ct_mapped_render_node() {
  pct config "$1" | awk -F': ' '
    $1 ~ /^dev[0-9]+$/ {
      n = split($2, parts, ",")
      for (i = 1; i <= n; i++) {
        item = parts[i]
        sub(/^path=/, "", item)
        if (item ~ /^\/dev\/dri\/renderD[0-9]+$/) { print item; exit }
      }
    }'
}

# Prints the devN key already used for a render node, or the first free devN.
render_dev_slot() {
  local config key index
  config="$(pct config "$1")"
  key="$(awk -F': ' '$1 ~ /^dev[0-9]+$/ && $2 ~ /\/dev\/dri\/renderD[0-9]+/ { print $1; exit }' <<<"$config")"
  if [[ -z "$key" ]]; then
    for index in $(seq 0 255); do
      if ! grep -q "^dev${index}: " <<<"$config"; then key="dev${index}"; break; fi
    done
  fi
  [[ -n "$key" ]] || die "No free devN slot on CT $1."
  printf '%s' "$key"
}

features_need_change() {
  local existing
  existing="$(ct_config_value "$1" features)"
  [[ ",${existing}," == *",nesting=1,"* && ",${existing}," == *",keyctl=1,"* ]] && return 1
  return 0
}

ensure_lxc_features() {
  local target_ct="$1" existing feature
  local -a features=()
  existing="$(ct_config_value "$target_ct" features)"
  if [[ -n "$existing" ]]; then
    local -a current_features=()
    IFS=',' read -r -a current_features <<<"$existing"
    for feature in "${current_features[@]}"; do
      case "$feature" in nesting=*|keyctl=*) continue ;; esac
      features+=("$feature")
    done
  fi
  features+=(nesting=1 keyctl=1)
  local IFS=,
  pct set "$target_ct" --features "${features[*]}"
}

# Collects OVMS arguments that the helper does not manage, so repair keeps
# local fixes such as --allowed_media_domains. Prefers ovms.env (v1.4.0+);
# falls back to parsing ExecStart from older hand-edited units.
detect_extra_args() {
  local ct="$1" from_env exec_line token skip_next=0
  local -a tokens=() extras=()
  from_env="$(pct exec "$ct" -- bash -c 'if [[ -r /etc/ovms/ovms.env ]] && grep -q "^OVMS_EXTRA_ARGS=" /etc/ovms/ovms.env; then . /etc/ovms/ovms.env; printf "set:%s" "${OVMS_EXTRA_ARGS:-}"; fi' 2>/dev/null || true)"
  if [[ "$from_env" == set:* ]]; then
    printf '%s' "${from_env#set:}"
    return 0
  fi
  exec_line="$(pct exec "$ct" -- awk '/^ExecStart=/ { sub(/^ExecStart=/, ""); print; exit }' /etc/systemd/system/ovms.service 2>/dev/null || true)"
  [[ -n "$exec_line" ]] || return 0
  read -r -a tokens <<<"$exec_line"
  for token in "${tokens[@]:1}"; do
    if (( skip_next )); then skip_next=0; continue; fi
    if [[ "$MANAGED_FLAGS" == *" ${token} "* ]]; then skip_next=1; continue; fi
    if [[ "$token" == --*=* && "$MANAGED_FLAGS" == *" ${token%%=*} "* ]]; then continue; fi
    [[ "$token" == \$* ]] && continue
    extras+=("$token")
  done
  printf '%s' "${extras[*]}"
}

take_snapshot() {
  local ct="$1" reason="$2" name
  name="ovms-${reason}-$(date +%Y%m%d-%H%M%S)"
  msg_info "Creating snapshot ${name} of CT ${ct}"
  if pct snapshot "$ct" "$name" --description "Before OVMS helper ${reason} (helper v${HELPER_VERSION})"; then
    SNAPSHOT_NAME="$name"
    msg_ok "Snapshot ${name} created. Remove it later with: pct delsnapshot ${ct} ${name}"
    return 0
  fi
  if whiptail --backtitle "OVMS Proxmox Helper" --defaultno --title "SNAPSHOT FAILED" \
    --yesno "Could not snapshot CT ${ct} (its storage may not support snapshots).\n\nContinue WITHOUT a rollback point? Choose No and back it up with vzdump first if unsure." 12 74; then
    msg_warn "Continuing without a snapshot."
    return 0
  fi
  die "Cancelled because no snapshot could be created. Nothing was changed."
}

# Validates an existing helper container for --repair and --update.
validate_existing_ct() {
  local candidate="$1" purpose="$2" os_info marker service
  validate_ctid_format "$candidate"
  [[ -f "/etc/pve/lxc/${candidate}.conf" ]] || die "LXC ${candidate} does not exist on this node."
  EXISTING_HOSTNAME="$(ct_config_value "$candidate" hostname)"
  [[ -n "$EXISTING_HOSTNAME" ]] || die "Could not read the hostname for LXC ${candidate}."
  GPU_NODE="$(ct_mapped_render_node "$candidate")"
  [[ -n "$GPU_NODE" ]] || die "LXC ${candidate} has no /dev/dri/renderD* mapping; refusing to modify it."
  is_intel_render_node "$GPU_NODE" || die "LXC ${candidate} maps ${GPU_NODE}, which is not an Intel render node on this host."
  ct_running "$candidate" || die "LXC ${candidate} must be running before ${purpose}."
  os_info="$(pct exec "$candidate" -- bash -c '. /etc/os-release; printf "%s:%s" "$ID" "$VERSION_ID"' 2>/dev/null || true)"
  [[ "$os_info" == ubuntu:24.04 ]] || die "Only Ubuntu 24.04 containers are supported; CT ${candidate} reports '${os_info:-unknown}'."
  if pct exec "$candidate" -- test -f /etc/ovms/proxmox-helper-managed 2>/dev/null; then marker=0; else marker=1; fi
  if pct exec "$candidate" -- test -f /etc/systemd/system/ovms.service 2>/dev/null; then service=0; else service=1; fi
  REPAIR_ADOPT=0
  if (( marker != 0 )); then
    [[ "$purpose" == repair ]] || die "CT ${candidate} has no OVMS helper ownership marker. Run --repair first."
    [[ "$EXISTING_HOSTNAME" == ovms && "$service" == 0 ]] || die "CT ${candidate} has no OVMS helper ownership marker. Refusing to modify an unrelated container."
    REPAIR_ADOPT=1
  fi
}

ct_has_cpu_fallback_scripts() {
  pct exec "$1" -- grep -qs -e 'allow-cpu-fallback' -e 'set_device CPU' /usr/local/bin/ovms-helper /usr/local/sbin/ovms-healthcheck
}

ct_marker_version() {
  pct exec "$1" -- sed -n 's/^HELPER_VERSION=//p' /etc/ovms/proxmox-helper-managed 2>/dev/null | head -n1 || true
}

# ---------------------------------------------------------------------------
# Interactive setup
# ---------------------------------------------------------------------------

active_storages() {
  local content="$1"
  pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'
}

storage_free_kib() {
  local storage="$1" content="$2"
  pvesm status --content "$content" 2>/dev/null | awk -v wanted="$storage" 'NR > 1 && $1 == wanted && $3 == "active" { print $6; found=1; exit } END { if (!found) exit 1 }'
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

Default: next free CTID, 8 cores, 16 GiB RAM, 48 GiB disk, DHCP on vmbr0.
Advanced: edit CT resources, network (static IP/VLAN), storage, and allowed image URL domains." \
    --no-button "Advanced" 12 78; then
    MODE="default"
  else
    result=$?
    (( result == 1 )) || die "Setup mode selection cancelled."
    MODE="advanced"
  fi
  msg_info "Using ${MODE^} Settings"
}

choose_storage() {
  local label="$1" content="$2" preferred="$3" minimum_free_gib="$4"
  local choices selected item free_kib free_gib minimum_free_kib
  local -a menu=()
  local -a usable=()
  choices="$(active_storages "$content")"
  [[ -n "$choices" ]] || die "No active Proxmox storage supports content type '$content'."
  minimum_free_kib=$((minimum_free_gib * 1024 * 1024))
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    free_kib="$(storage_free_kib "$item" "$content" || true)"
    [[ "$free_kib" =~ ^[0-9]+$ ]] || continue
    (( free_kib >= minimum_free_kib )) || continue
    free_gib=$((free_kib / 1024 / 1024))
    usable+=("$item")
    menu+=("$item" "Free: ${free_gib} GiB")
  done <<<"$choices"
  (( ${#usable[@]} > 0 )) || die "No active '$content' storage has at least ${minimum_free_gib} GiB free. Check pvesm status before retrying."
  if printf '%s\n' "${usable[@]}" | grep -Fxq "$preferred"; then
    selected="$preferred"
  else
    selected="${usable[0]}"
  fi
  if [[ "$MODE" == advanced ]]; then
    selected="$(whiptail --backtitle "OVMS Proxmox Helper" --title "STORAGE" \
      --menu "$label storage" 16 72 8 "${menu[@]}" 3>&1 1>&2 2>&3)" || die "Storage selection cancelled."
  fi
  printf '%s\n' "${usable[@]}" | grep -Fxq "$selected" || die "Storage '$selected' does not meet the active/free-space requirements for '$content'."
  free_kib="$(storage_free_kib "$selected" "$content")" || die "Could not read free space for storage '$selected'."
  free_gib=$((free_kib / 1024 / 1024))
  msg_info "$label storage: $selected (${free_gib} GiB free)" >&2
  printf '%s' "$selected"
}

valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

# ---------------------------------------------------------------------------
# OVMS installation (fresh install and repair)
# ---------------------------------------------------------------------------

install_ovms() {
  local target_ct="$1"
  local render_gid root_free_kib slot desired current needs_restart=0
  root_free_kib="$(pct exec "$target_ct" -- df -Pk / | awk 'NR == 2 { print $4 }')"
  [[ "$root_free_kib" =~ ^[0-9]+$ ]] || die "Could not determine free root-disk space inside CT ${target_ct}."
  (( root_free_kib >= 8 * 1024 * 1024 )) || die "CT ${target_ct} needs at least 8 GiB free before installing OVMS and downloading the model; it currently has $((root_free_kib / 1024 / 1024)) GiB. Increase its root disk or free space, then retry."
  msg_info "Installing Intel GPU userspace runtime and native OVMS ${OVMS_VERSION} in CT ${target_ct}"
  pct exec "$target_ct" -- env \
    HELPER_VERSION="$HELPER_VERSION" \
    CTID="$target_ct" \
    OVMS_VERSION="$OVMS_VERSION" \
    OVMS_ARCHIVE="$OVMS_ARCHIVE" \
    OVMS_SHA256="$OVMS_SHA256" \
    OVMS_RELEASE_URL="$OVMS_RELEASE_URL" \
    OVMS_MODEL_ID="$OVMS_MODEL_ID" \
    OVMS_MODEL_NAME="$OVMS_MODEL_NAME" \
    OVMS_EXTRA_ARGS="$OVMS_EXTRA_ARGS" \
    bash -s <<'IN_CONTAINER'
set -Eeuo pipefail
trap 'echo "In-container setup failed at line $LINENO: $BASH_COMMAND" >&2' ERR
trap 'rm -f -- "/tmp/$OVMS_ARCHIVE"; rm -rf -- /opt/ovms.new' EXIT
export DEBIAN_FRONTEND=noninteractive
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/ovms-helper/$STAMP"

if [[ -e /usr/bin/update || -L /usr/bin/update ]] && ! grep -Fq 'exec /usr/local/bin/ovms-helper update' /usr/bin/update; then
  echo "/usr/bin/update already exists and is not managed by this helper; refusing to overwrite it." >&2
  exit 1
fi

# Wait for DHCP/DNS; a freshly started container may not have them yet.
for _ in $(seq 1 60); do
  getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
  sleep 2
done
getent hosts archive.ubuntu.com >/dev/null 2>&1 || { echo "No working DNS/network inside the container after 120 seconds." >&2; exit 1; }

# Keep a copy of every file this run replaces, so local edits are recoverable.
for managed in /etc/systemd/system/ovms.service /etc/ovms/ovms.env /etc/ovms/proxmox-helper-managed \
  /usr/local/bin/ovms-helper /usr/local/sbin/ovms-healthcheck /usr/local/sbin/ovms-validate-device \
  /usr/bin/update /etc/profile.d/00-ovms-details.sh /etc/systemd/system/container-getty@1.service.d/override.conf; do
  if [[ -e "$managed" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a --parents -- "$managed" "$BACKUP_DIR/"
  fi
done
[[ -d "$BACKUP_DIR" ]] && echo "Backed up existing helper files to $BACKUP_DIR"

systemctl stop ovms.service 2>/dev/null || true

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl libxml2 libpython3.12-dev software-properties-common \
  python3-pip python3-venv

# Intel's Ubuntu compute packages provide the userspace Level Zero/OpenCL
# runtime; the i915/xe kernel driver remains on the Proxmox host.
add-apt-repository -y ppa:kobuk-team/intel-graphics
apt-get update
apt-get install -y --no-install-recommends \
  libze-intel-gpu1 libze1 intel-metrics-discovery intel-opencl-icd clinfo intel-gsc

mkdir -p /var/lib/ovms/models /var/lib/ovms/.cache/huggingface /etc/ovms
cd /tmp
curl -fL --retry 3 "$OVMS_RELEASE_URL" -o "$OVMS_ARCHIVE"
echo "$OVMS_SHA256  $OVMS_ARCHIVE" | sha256sum --check --status || {
  echo "OVMS archive SHA256 verification failed" >&2
  exit 1
}
# Extract to a staging directory, then swap, so a repair never mixes files
# from two OVMS versions. The previous tree is kept as /opt/ovms.prev.
rm -rf -- /opt/ovms.new
mkdir -p /opt/ovms.new
tar -xzf "$OVMS_ARCHIVE" -C /opt/ovms.new
[[ -x /opt/ovms.new/ovms/bin/ovms ]] || { echo "Expected ovms/bin/ovms in the release archive" >&2; exit 1; }
if [[ -d /opt/ovms ]]; then
  rm -rf -- /opt/ovms.prev
  mv /opt/ovms /opt/ovms.prev
fi
mv /opt/ovms.new/ovms /opt/ovms

# OVMS's Python-enabled native bundle needs these chat-template dependencies.
python3 -m pip install --break-system-packages \
  'Jinja2==3.1.6' 'MarkupSafe==3.0.2' 'numpy==2.5.3'

# Give the unprivileged server only render-node access, not container root.
getent group render >/dev/null || groupadd --system render
id -u ovms >/dev/null 2>&1 || useradd --system --home-dir /var/lib/ovms --shell /usr/sbin/nologin ovms
usermod --append --groups render ovms
chown -R ovms:ovms /var/lib/ovms
chmod 0750 /var/lib/ovms
printf '%s\n' "$(getent group render | cut -d: -f3)" >/etc/ovms/render.gid
printf 'HELPER_VERSION=%s\nCTID=%s\nMODEL_ID=%s\nOVMS_VERSION=%s\nINSTALLED_AT=%s\n' \
  "$HELPER_VERSION" "$CTID" "$OVMS_MODEL_ID" "$OVMS_VERSION" "$STAMP" >/etc/ovms/proxmox-helper-managed
chmod 0644 /etc/ovms/proxmox-helper-managed
dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null \
  | grep -Ei '(intel|level-zero|libze|libigc|igdgmm)' | sort >/etc/ovms/runtime-versions.txt || true

# GPU is the only supported device. OVMS_EXTRA_ARGS holds local OVMS flags
# (for example --allowed_media_domains) that repair carries forward.
cat >/etc/ovms/ovms.env <<EOF
OVMS_TARGET_DEVICE=GPU
OVMS_MODEL_NAME=${OVMS_MODEL_NAME}
OVMS_EXTRA_ARGS="${OVMS_EXTRA_ARGS}"
EOF
chmod 0644 /etc/ovms/ovms.env

cat >/usr/local/sbin/ovms-validate-device <<'EOF'
#!/usr/bin/env bash
# Refuses to start OVMS on anything but an Intel GPU device; no CPU/AUTO.
set -Eeuo pipefail
device="${OVMS_TARGET_DEVICE-}"
if [[ -z "$device" && -r /etc/ovms/ovms.env ]]; then
  # shellcheck disable=SC1091
  . /etc/ovms/ovms.env
  device="${OVMS_TARGET_DEVICE-}"
fi
if [[ ! "$device" =~ ^GPU(\.[0-9]+)?$ ]]; then
  echo "OVMS_TARGET_DEVICE='${device}' is not allowed; this install is GPU-only (GPU or GPU.<n>). Fix /etc/ovms/ovms.env." >&2
  exit 1
fi
EOF
chmod 0755 /usr/local/sbin/ovms-validate-device

# Match the Community Scripts console convenience. This is only LXC tty1
# autologin; SSH comes from the Ubuntu template and is not changed here.
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p "$(dirname "$GETTY_OVERRIDE")"
cat >"$GETTY_OVERRIDE" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
EOF

cat >/etc/profile.d/00-ovms-details.sh <<'EOF'
case "$-" in *i*) ;; *) return 0 ;; esac
. /etc/os-release
RESET=$'\033[0m'
CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
printf '\n%sOVMS LXC Container%s\n' "$CYAN" "$RESET"
printf ' 🌐  Provided by: Personal Proxmox Helper | GitHub: exelaguilar\n'
printf ' 🖥️   OS: %s (%s)\n' "${PRETTY_NAME:-Ubuntu}" "${VERSION_CODENAME:-unknown}"
printf ' 🏠  Hostname: %s\n' "$(hostname)"
printf ' 💡  IP Address: %s\n' "$(hostname -I | awk '{print $1}')"
printf ' 🔌  API Endpoint: http://%s:8000/v1\n' "$(hostname -I | awk '{print $1}')"
printf ' ⚙️   Service: systemctl status ovms\n'
printf ' 🔄  Update this container: %supdate%s\n\n' "$GREEN" "$RESET"
EOF

cat >/usr/local/bin/ovms-helper <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  status) systemctl status ovms --no-pager ;;
  restart) systemctl restart ovms ;;
  logs) journalctl -u ovms -f ;;
  healthcheck) /usr/local/sbin/ovms-healthcheck ;;
  update)
    export DEBIAN_FRONTEND=noninteractive
    free_kib="$(df -Pk / | awk 'NR == 2 { print $4 }')"
    if [[ ! "$free_kib" =~ ^[0-9]+$ ]] || (( free_kib < 2 * 1024 * 1024 )); then
      echo "Less than 2 GiB free on /; free some space before updating." >&2
      exit 1
    fi
    printf 'Tip: running "ovms-lxc-helper.sh --update <CTID>" on the Proxmox host takes a snapshot first.\n'
    printf 'This updates Ubuntu and the Intel GPU runtime; OVMS itself stays at the version the helper installed.\n\n'
    runtime_before="$(mktemp)"
    runtime_after="$(mktemp)"
    runtime_diff="$(mktemp)"
    ovms_was_active=0
    update_cleanup() {
      rm -f -- "$runtime_before" "$runtime_after" "$runtime_diff"
      if [[ "$ovms_was_active" == 1 ]] && ! systemctl is-active --quiet ovms; then systemctl start ovms || true; fi
    }
    trap update_cleanup EXIT
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | grep -Ei '(intel|level-zero|libze|libigc|openvino|igdgmm)' | sort >"$runtime_before" || true
    apt-get update
    if systemctl is-active --quiet ovms; then ovms_was_active=1; fi
    systemctl stop ovms
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade -y
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | grep -Ei '(intel|level-zero|libze|libigc|openvino|igdgmm)' | sort >"$runtime_after" || true
    if ! diff -u "$runtime_before" "$runtime_after" >"$runtime_diff"; then
      printf '\nIntel/OpenVINO runtime package versions changed during update; validating inference against the updated stack.\n'
      cat "$runtime_diff"
      { date --iso-8601=seconds; cat "$runtime_diff"; printf '\n'; } >>/var/log/ovms-runtime-updates.log
      cp "$runtime_after" /etc/ovms/runtime-versions.txt
    fi
    systemctl reset-failed ovms 2>/dev/null || true
    systemctl restart ovms
    /usr/local/sbin/ovms-healthcheck
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    ;;
  *) printf 'Usage: ovms-helper {status|restart|logs|healthcheck|update}\n' >&2; exit 2 ;;
esac
EOF
chmod 0755 /usr/local/bin/ovms-helper

cat >/usr/bin/update <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/local/bin/ovms-helper update "$@"
EOF
chmod 0755 /usr/bin/update

cat >/usr/local/sbin/ovms-healthcheck <<'HEALTHCHECK'
#!/usr/bin/env bash
# GPU-only OVMS health check: real text + image inference, then proof that the
# running server was started with --target_device GPU and holds the GPU node.
set -Eeuo pipefail
readonly API_URL="http://127.0.0.1:8000"
readonly WAIT_SECONDS=1800

if (( $# > 0 )); then
  echo "Usage: ovms-healthcheck (GPU only; there is no CPU fallback)." >&2
  exit 2
fi

# shellcheck disable=SC1091
. /etc/ovms/ovms.env
readonly MODEL_NAME="${OVMS_MODEL_NAME:-qwen3-vl-4b}"
export MODEL_NAME

check_gpu_access() {
  if ! runuser -u ovms -- clinfo -l 2>&1 | grep -qi Intel; then
    echo "clinfo cannot see an Intel GPU as the unprivileged ovms service user." >&2
    return 1
  fi
}

model_listed() {
  python3 -c 'import json, os, sys; d = json.load(sys.stdin); sys.exit(0 if any(m.get("id") == os.environ["MODEL_NAME"] for m in d.get("data", [])) else 1)' 2>/dev/null
}

wait_for_model() {
  local deadline=$((SECONDS + WAIT_SECONDS)) response initial_restarts restarts
  initial_restarts="$(systemctl show --property=NRestarts --value ovms 2>/dev/null || printf 0)"
  while (( SECONDS < deadline )); do
    if systemctl is-failed --quiet ovms; then
      echo "OVMS is in the failed state (start limit reached or start check refused)." >&2
      return 1
    fi
    if systemctl is-active --quiet ovms; then
      response="$(curl -fsS --max-time 5 "$API_URL/v1/models" 2>/dev/null || true)"
      if [[ -n "$response" ]] && model_listed <<<"$response"; then
        return 0
      fi
    fi
    restarts="$(systemctl show --property=NRestarts --value ovms 2>/dev/null || printf 0)"
    if [[ "$initial_restarts" =~ ^[0-9]+$ && "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= initial_restarts + 4 )); then
      echo "OVMS has restarted repeatedly while loading the model; not waiting the full download timeout." >&2
      return 1
    fi
    sleep 5
  done
  echo "OVMS model did not become available within $WAIT_SECONDS seconds." >&2
  return 1
}

make_red_image() {
  python3 - <<'PY'
import base64, struct, zlib
w = h = 64
raw = b''.join(b'\x00' + b'\xff\x00\x00\xff' * w for _ in range(h))
def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
print(base64.b64encode(png).decode())
PY
}

text_probe() {
  local response payload
  payload="$(python3 -c 'import json, os; print(json.dumps({"model": os.environ["MODEL_NAME"], "messages": [{"role": "user", "content": "Reply with the exact token OVMS_HEALTH_OK and nothing else."}], "max_tokens": 24, "temperature": 0, "stream": False}))')" || return 1
  response="$(curl -fsS --max-time 240 "$API_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null)" || return 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["choices"][0]["message"]["content"]; sys.exit(0 if "OVMS_HEALTH_OK" in c else 1)' <<<"$response"
}

image_probe() {
  local image_b64 payload response
  image_b64="$(make_red_image)" || return 1
  payload="$(python3 - "$image_b64" <<'PY'
import json, os, sys
image = sys.argv[1]
print(json.dumps({"model": os.environ["MODEL_NAME"], "messages": [{"role": "user", "content": [{"type": "text", "text": "What color is the solid square? Reply with the single word RED."}, {"type": "image_url", "image_url": {"url": "data:image/png;base64," + image}}]}], "max_tokens": 24, "temperature": 0, "stream": False}))
PY
)" || return 1
  response="$(curl -fsS --max-time 240 "$API_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null)" || return 1
  python3 -c 'import json,re,sys; d=json.load(sys.stdin); c=d["choices"][0]["message"]["content"]; sys.exit(0 if re.search(r"\bred\b", c, re.I) else 1)' <<<"$response"
}

# The command line proves the device OVMS was started with; the open render
# node shows the GPU plugin is attached. Together they rule out a CPU run.
verify_gpu_runtime() {
  local pid="$1" device fd target
  device="$(tr '\0' '\n' <"/proc/$pid/cmdline" | grep -A1 -x -- '--target_device' | tail -n1 || true)"
  if [[ ! "$device" =~ ^GPU(\.[0-9]+)?$ ]]; then
    echo "The running OVMS process was started with --target_device '${device:-<none>}', not GPU." >&2
    return 1
  fi
  for fd in "/proc/$pid/fd/"*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    if [[ "$target" == /dev/dri/renderD* ]]; then
      echo "Running OVMS process (PID $pid) uses --target_device $device and holds $target."
      return 0
    fi
  done
  echo "The running OVMS process has no /dev/dri/renderD* node open." >&2
  return 1
}

run_probes() {
  local before_pid before_restarts after_pid after_restarts
  wait_for_model || return 1
  before_pid="$(systemctl show --property=MainPID --value ovms)"
  before_restarts="$(systemctl show --property=NRestarts --value ovms)"
  [[ "$before_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  text_probe || { echo "Text completion probe failed." >&2; return 1; }
  image_probe || { echo "Image completion probe failed." >&2; return 1; }
  sleep 1
  after_pid="$(systemctl show --property=MainPID --value ovms)"
  after_restarts="$(systemctl show --property=NRestarts --value ovms)"
  [[ "$before_pid" == "$after_pid" && "$before_restarts" == "$after_restarts" ]] || {
    echo "OVMS restarted during inference (PID ${before_pid}->${after_pid}; restarts ${before_restarts}->${after_restarts})." >&2
    return 1
  }
  verify_gpu_runtime "$after_pid" || return 1
  systemctl is-active --quiet ovms
}

fail() {
  journalctl -u ovms -n 40 --no-pager >&2 || true
  echo "[ERROR] $*" >&2
  exit 1
}

/usr/local/sbin/ovms-validate-device || fail "Configured device is not GPU; nothing was changed."
check_gpu_access || fail "The ovms user cannot reach the Intel GPU; check the LXC render-node mapping and render group."
echo "Testing OVMS text and image inference on GPU (model: $MODEL_NAME)"
run_probes || fail "OVMS did not pass its GPU inference health checks. The device setting was not changed; there is no CPU fallback."
echo "[OK] Text and image inference passed; OVMS stayed running on the Intel GPU."
HEALTHCHECK
chmod 0755 /usr/local/sbin/ovms-healthcheck

cat >/etc/systemd/system/ovms.service <<EOF
[Unit]
Description=OpenVINO Model Server (Intel GPU only)
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=900
StartLimitBurst=10

[Service]
Type=simple
User=ovms
Group=ovms
SupplementaryGroups=render
WorkingDirectory=/var/lib/ovms
Environment=HOME=/var/lib/ovms
Environment=HF_HOME=/var/lib/ovms/.cache/huggingface
Environment=LD_LIBRARY_PATH=/opt/ovms/lib
Environment=PATH=/opt/ovms/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONPATH=/opt/ovms/lib/python
EnvironmentFile=/etc/ovms/ovms.env
ExecStartPre=/usr/local/sbin/ovms-validate-device
ExecStart=/opt/ovms/bin/ovms --source_model ${OVMS_MODEL_ID} --model_repository_path /var/lib/ovms/models --model_name ${OVMS_MODEL_NAME} --rest_port 8000 --task text_generation --pipeline_type VLM --target_device \${OVMS_TARGET_DEVICE} \$OVMS_EXTRA_ARGS
Restart=on-failure
RestartSec=30
TimeoutStartSec=0
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/var/lib/ovms

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl restart container-getty@1.service
apt-get clean
rm -rf /var/lib/apt/lists/*
IN_CONTAINER

  render_gid="$(pct exec "$target_ct" -- cat /etc/ovms/render.gid | tr -d '[:space:]')"
  [[ "$render_gid" =~ ^[0-9]+$ ]] || die "Could not determine the LXC render-group GID for CT ${target_ct}."

  # Only stop the container when the GPU mapping or features actually change.
  slot="$(render_dev_slot "$target_ct")"
  desired="path=${GPU_NODE},uid=0,gid=${render_gid},mode=0660"
  current="$(ct_config_value "$target_ct" "$slot")"
  [[ "$current" == "$desired" ]] || needs_restart=1
  features_need_change "$target_ct" && needs_restart=1
  if (( needs_restart )); then
    if ct_running "$target_ct"; then
      pct shutdown "$target_ct" --timeout 60 >/dev/null 2>&1 || true
      if ct_running "$target_ct"; then pct stop "$target_ct"; fi
    fi
    ensure_lxc_features "$target_ct"
    msg_info "Mapping ${GPU_NODE} as ${slot} to the LXC render group (GID ${render_gid})"
    pct set "$target_ct" "--${slot}" "$desired"
    pct start "$target_ct"
    wait_for_ct "$target_ct" || die "CT ${target_ct} did not restart after applying its render-group mapping."
  else
    msg_ok "GPU mapping (${slot}) and LXC features already correct; no container restart needed"
  fi

  pct exec "$target_ct" -- runuser -u ovms -- bash -c 'clinfo -l 2>&1 | grep -qi Intel' \
    || die "The ovms user in CT ${target_ct} cannot see the Intel GPU through clinfo. Check ${GPU_NODE} and the render group; no CPU fallback will be configured."
  pct exec "$target_ct" -- systemctl enable ovms.service >/dev/null 2>&1
  pct exec "$target_ct" -- systemctl reset-failed ovms.service >/dev/null 2>&1 || true
  pct exec "$target_ct" -- systemctl restart ovms.service
  pct exec "$target_ct" -- /usr/local/sbin/ovms-healthcheck
}

update_notes_version() {
  local ct="$1" description
  description="$(ct_config_value "$ct" description)"
  # Only touch notes the helper wrote itself; never overwrite user notes.
  if [[ "$description" =~ ^OpenVINO\ Model\ Server\;\ personal\ helper\ v[0-9.]+\;\ model\ [A-Za-z0-9._-]+$ ]]; then
    pct set "$ct" --description "OpenVINO Model Server; personal helper v${HELPER_VERSION}; model ${OVMS_MODEL_NAME}"
  fi
}

print_install_summary() {
  local target_ct="$1" ct_hostname="$2" root_password="${3:-}" ct_ip
  ct_ip="$(pct exec "$target_ct" -- hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  msg_ok "Text and image inference checks passed on the Intel GPU."
  printf '\nContainer: %s (%s); render device: %s\n' "$target_ct" "$ct_hostname" "$GPU_NODE"
  printf 'OpenAI-compatible endpoint: http://%s:8000/v1\n' "${ct_ip:-<CT-IP>}"
  printf 'Model name for clients: %s\n' "$OVMS_MODEL_NAME"
  [[ -z "$OVMS_EXTRA_ARGS" ]] || printf 'Extra OVMS arguments (in /etc/ovms/ovms.env): %s\n' "$OVMS_EXTRA_ARGS"
  printf 'Status: pct exec %s -- systemctl status ovms\n' "$target_ct"
  printf 'Logs: pct exec %s -- journalctl -u ovms -f\n' "$target_ct"
  printf 'Read-only check from the host: bash %s --check %s\n' "$0" "$target_ct"
  printf 'Update with a snapshot first: bash %s --update %s\n' "$0" "$target_ct"
  printf 'Service helper: pct exec %s -- ovms-helper {status|restart|logs|healthcheck|update}\n' "$target_ct"
  printf 'Console autologin: enabled on LXC tty1. SSH is left as the Ubuntu template ships it (root key-only).\n'
  printf 'The API has no authentication configured; keep it on your trusted LAN or firewall it to Home Assistant.\n'
  [[ -z "$SNAPSHOT_NAME" ]] || printf 'Rollback point: pct rollback %s %s (delete when satisfied: pct delsnapshot %s %s)\n' "$target_ct" "$SNAPSHOT_NAME" "$target_ct" "$SNAPSHOT_NAME"
  [[ -z "$root_password" ]] || printf 'Root console password: %s\n' "$root_password"
}

# ---------------------------------------------------------------------------
# --check: read-only diagnostics
# ---------------------------------------------------------------------------

check_report() {
  local level="$1"; shift
  case "$level" in
    ok) msg_ok "$*" ;;
    info) msg_info "$*" ;;
    *) msg_warn "$*"; CHECK_PROBLEMS=$((CHECK_PROBLEMS + 1)) ;;
  esac
}

run_check() {
  local ct="$1" value pid render_gid mapped_gid node slot snapshots
  validate_ctid_format "$ct"
  [[ -f "/etc/pve/lxc/${ct}.conf" ]] || die "LXC ${ct} does not exist on this node."
  ct_running "$ct" || die "LXC ${ct} is not running; nothing to inspect."
  msg_info "Read-only check of CT ${ct} ($(ct_config_value "$ct" hostname)); nothing will be changed."

  value="$(ct_marker_version "$ct")"
  if [[ -z "$value" ]]; then check_report warn "No helper marker (/etc/ovms/proxmox-helper-managed)."
  elif [[ "$value" == "$HELPER_VERSION" ]]; then check_report ok "In-container scripts are from helper v${value}."
  else check_report warn "In-container scripts are from helper v${value}; this script is v${HELPER_VERSION}. Run --repair ${ct} to update them."
  fi

  if ct_has_cpu_fallback_scripts "$ct"; then
    check_report warn "Old CPU-fallback logic is still installed in ovms-helper/ovms-healthcheck; 'update' could switch OVMS to CPU. Run --repair ${ct}."
  else
    check_report ok "No CPU-fallback logic in the in-container scripts."
  fi

  value="$(pct exec "$ct" -- bash -c '. /etc/ovms/ovms.env 2>/dev/null; printf "%s" "${OVMS_TARGET_DEVICE-}"' 2>/dev/null || true)"
  if [[ "$value" =~ ^GPU(\.[0-9]+)?$ ]]; then check_report ok "Configured device: ${value}."
  else check_report warn "Configured device is '${value:-<empty>}', not GPU."
  fi

  value="$(pct exec "$ct" -- systemctl show ovms -p ActiveState --value 2>/dev/null || true)"
  if [[ "$value" == active ]]; then check_report ok "ovms.service is active."
  else check_report warn "ovms.service is '${value:-unknown}'."
  fi
  value="$(pct exec "$ct" -- systemctl show ovms -p NRestarts --value 2>/dev/null || true)"
  if [[ "$value" == 0 ]]; then check_report ok "Service restarts since last start: 0."
  else check_report warn "Service restarts since last start: ${value:-unknown}."
  fi

  pid="$(pct exec "$ct" -- systemctl show ovms -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    value="$(pct exec "$ct" -- bash -c "tr '\\0' '\\n' </proc/${pid}/cmdline | grep -A1 -x -- --target_device | tail -n1" 2>/dev/null || true)"
    if [[ "$value" =~ ^GPU(\.[0-9]+)?$ ]]; then check_report ok "Running process was started with --target_device ${value}."
    else check_report warn "Running process target device is '${value:-unknown}', not GPU."
    fi
    if pct exec "$ct" -- bash -c "ls -l /proc/${pid}/fd 2>/dev/null | grep -q '/dev/dri/renderD'"; then
      check_report ok "Running process holds a /dev/dri/renderD* node."
    else
      check_report warn "Running process has no /dev/dri/renderD* node open."
    fi
  else
    check_report warn "No running OVMS process to inspect."
  fi

  node="$(ct_mapped_render_node "$ct")"
  slot="$(render_dev_slot "$ct")"
  mapped_gid="$(ct_config_value "$ct" "$slot" | tr ',' '\n' | sed -n 's/^gid=//p')"
  render_gid="$(pct exec "$ct" -- getent group render 2>/dev/null | cut -d: -f3 || true)"
  if [[ -n "$node" ]] && is_intel_render_node "$node"; then check_report ok "${slot} maps Intel render node ${node}."
  else check_report warn "No Intel render node mapping found (found '${node:-none}')."
  fi
  if [[ -n "$mapped_gid" && "$mapped_gid" == "$render_gid" ]]; then check_report ok "Mapping GID ${mapped_gid} matches the container render group."
  else check_report warn "Mapping GID '${mapped_gid:-unset}' does not match container render group '${render_gid:-unknown}'."
  fi
  if pct exec "$ct" -- runuser -u ovms -- bash -c 'clinfo -l 2>&1 | grep -qi Intel' 2>/dev/null; then
    check_report ok "The ovms user sees the Intel GPU through OpenCL."
  else
    check_report warn "The ovms user cannot see the Intel GPU through clinfo."
  fi

  value="$(pct exec "$ct" -- curl -fsS --max-time 5 http://127.0.0.1:8000/v1/models 2>/dev/null || true)"
  if [[ "$value" == *"\"${OVMS_MODEL_NAME}\""* ]]; then check_report ok "/v1/models lists ${OVMS_MODEL_NAME}."
  else check_report warn "/v1/models does not list ${OVMS_MODEL_NAME}."
  fi

  value="$(detect_extra_args "$ct")"
  check_report info "Extra OVMS arguments that --repair will keep: ${value:-none}."

  value="$(pct exec "$ct" -- df -Pk / 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 4 * 1024 * 1024 )); then check_report ok "Root disk free: $((value / 1024 / 1024)) GiB."
  else check_report warn "Root disk free is low or unknown (${value:-?} KiB)."
  fi

  snapshots="$(pct listsnapshot "$ct" 2>/dev/null | grep -vc 'current' || true)"
  check_report info "Snapshots: ${snapshots:-0}."
  if pct exec "$ct" -- bash -c 'ss -tln 2>/dev/null | grep -q ":22 "'; then
    check_report info "sshd is listening on port 22 (from the Ubuntu template)."
  fi

  printf '\n'
  if (( CHECK_PROBLEMS == 0 )); then
    msg_ok "No problems found."
  else
    msg_warn "${CHECK_PROBLEMS} item(s) need attention."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

check_root
case "$#" in
  0) ;;
  1) [[ "$1" == -h || "$1" == --help ]] && usage; usage ;;
  2)
    case "$1" in
      --repair) ACTION=repair ;;
      --update) ACTION=update ;;
      --check) ACTION=check ;;
      *) usage ;;
    esac
    TARGET_CT="$2"
    ;;
  *) usage ;;
esac
pve_check
arch_check
for required in pct pvesh pvesm pveam whiptail openssl curl sha256sum; do
  command -v "$required" >/dev/null 2>&1 || die "Required command not found: ${required}."
done

if [[ "$ACTION" == check ]]; then
  run_check "$TARGET_CT"
  exit 0
fi

[[ -t 0 && -t 1 ]] || die "Run this helper from an interactive Proxmox shell."
ssh_check
header_info
host_gpu_check

if [[ "$ACTION" != update ]] && ! pct help set 2>&1 | grep -Eq -- '--dev|dev\[n\]'; then
  die "This Proxmox version does not advertise pct --dev[n] device mapping. Upgrade Proxmox VE before using this installer."
fi

if [[ "$ACTION" == update ]]; then
  CTID="$TARGET_CT"
  validate_existing_ct "$CTID" update
  if ct_has_cpu_fallback_scripts "$CTID"; then
    die "CT ${CTID} still has the old CPU-fallback scripts (helper v$(ct_marker_version "$CTID")). Their update could switch OVMS to CPU. Run --repair ${CTID} first; nothing was changed."
  fi
  if ! whiptail --backtitle "OVMS Proxmox Helper" --title "UPDATE CONTAINER" \
    --yesno "Snapshot CT ${CTID} (${EXISTING_HOSTNAME}), then run its in-container update?

The update upgrades Ubuntu and the Intel GPU runtime, restarts OVMS, and runs the GPU-only health check. OVMS itself stays at the installed version. If the health check fails, the snapshot is your rollback point." 14 78; then
    msg_info "Update cancelled; no changes were made."
    exit 0
  fi
  take_snapshot "$CTID" update
  CT_TOUCHED=1
  pct exec "$CTID" -- /usr/local/bin/ovms-helper update
  msg_ok "Update completed and the GPU health check passed."
  [[ -z "$SNAPSHOT_NAME" ]] || msg_info "When satisfied, remove the snapshot: pct delsnapshot ${CTID} ${SNAPSHOT_NAME}"
  exit 0
fi

if [[ "$ACTION" == repair ]]; then
  CTID="$TARGET_CT"
  validate_existing_ct "$CTID" repair
  OVMS_EXTRA_ARGS="$(detect_extra_args "$CTID")"
  [[ "$OVMS_EXTRA_ARGS" =~ $EXTRA_ARGS_RE ]] || die "CT ${CTID} has extra OVMS arguments with unexpected characters ('${OVMS_EXTRA_ARGS}'). Move them to OVMS_EXTRA_ARGS in /etc/ovms/ovms.env by hand, then retry."
  REPAIR_NOTE=""
  if [[ "$REPAIR_ADOPT" == 1 ]]; then
    REPAIR_NOTE=$'\n\nThis CT has no helper ownership marker. You are explicitly adopting it as the OVMS helper container.'
  fi
  if ! whiptail --backtitle "OVMS Proxmox Helper" --title "REPAIR EXISTING CONTAINER" \
    --yesno "Reinstall OVMS ${OVMS_VERSION} and the helper scripts inside CT ${CTID} (${EXISTING_HOSTNAME})?

- A snapshot is taken first (you can roll back).
- Replaced files are backed up to /var/backups/ovms-helper/ in the CT.
- Extra OVMS arguments kept: ${OVMS_EXTRA_ARGS:-none}
- GPU node: ${GPU_NODE}. The CT restarts only if its mapping or features need changes.
- OVMS is unavailable while it reinstalls and reloads the model.

No new container will be created.${REPAIR_NOTE}" 20 80; then
    msg_info "Repair cancelled; no changes were made."
    exit 0
  fi
  take_snapshot "$CTID" repair
  CT_TOUCHED=1
  install_ovms "$CTID"
  update_notes_version "$CTID"
  msg_ok "Repair completed; GPU text and image inference was validated."
  print_install_summary "$CTID" "$(ct_config_value "$CTID" hostname)"
  exit 0
fi

# Fresh install
GPU_NODE="$(find_intel_render_node)" || die "No Intel /dev/dri/renderD* node was found on the host. No changes made."
msg_info "Intel render node: ${GPU_NODE}"
start_script

AUTO_ID="$(available_id)"
NET_IP="dhcp"
GATEWAY=""
VLAN=""
MEDIA_DOMAINS=""
if [[ "$MODE" == advanced ]]; then
  NEW_CTID="$(ask_default 'Container ID (CTID)' "$AUTO_ID")"
  validate_new_id "$NEW_CTID"
  CT_HOSTNAME="$(ask_default 'Container hostname' 'ovms')"
  CORES="$(ask_default 'CPU cores' '8')"
  MEMORY="$(ask_default 'RAM (MiB)' '16384')"
  SWAP="$(ask_default 'Swap (MiB)' '4096')"
  ROOTFS_GB="$(ask_default 'Root disk (GiB)' "$DEFAULT_ROOTFS_GB")"
  BRIDGE="$(ask_default 'Network bridge' 'vmbr0')"
  NET_IP="$(ask_default 'IPv4 address with prefix (e.g. 10.0.0.50/24), or dhcp' 'dhcp')"
  if [[ "$NET_IP" != dhcp ]]; then
    GATEWAY="$(ask_default 'IPv4 gateway' '')"
  fi
  VLAN="$(ask_default 'VLAN tag (blank for none)' '')"
  MEDIA_DOMAINS="$(ask_default 'Domains/IPs OVMS may fetch image URLs from, comma-separated (blank = data: images only)' '')"
else
  NEW_CTID="$AUTO_ID"
  CT_HOSTNAME='ovms'
  CORES=8
  MEMORY=16384
  SWAP=4096
  ROOTFS_GB=$DEFAULT_ROOTFS_GB
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
(( ROOTFS_GB >= MIN_ROOTFS_GB && ROOTFS_GB <= 512 )) || die "Root disk must be between ${MIN_ROOTFS_GB} and 512 GiB."
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname (letters, digits, and inner hyphens; max 63 characters)."
[[ "$BRIDGE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die "Invalid bridge interface name."
if [[ -d "/sys/class/net/${BRIDGE}/bridge" ]]; then
  :
elif command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl br-exists "$BRIDGE" >/dev/null 2>&1; then
  :
else
  die "'$BRIDGE' is not an existing Linux or Open vSwitch bridge on this host."
fi
NET0="name=eth0,bridge=${BRIDGE}"
if [[ "$NET_IP" == dhcp ]]; then
  NET0+=",ip=dhcp"
else
  NET_ADDR="${NET_IP%/*}"
  NET_PREFIX="${NET_IP##*/}"
  [[ "$NET_IP" == */* && "$NET_PREFIX" =~ ^[0-9]{1,2}$ ]] && valid_ipv4 "$NET_ADDR" && (( 10#$NET_PREFIX >= 8 && 10#$NET_PREFIX <= 32 )) \
    || die "Invalid IPv4 address/prefix '${NET_IP}'. Use a form like 10.0.0.50/24, or dhcp."
  valid_ipv4 "$GATEWAY" || die "Invalid IPv4 gateway '${GATEWAY}'."
  NET0+=",ip=${NET_IP},gw=${GATEWAY}"
fi
if [[ -n "$VLAN" ]]; then
  [[ "$VLAN" =~ ^[0-9]{1,4}$ ]] && (( 10#$VLAN >= 1 && 10#$VLAN <= 4094 )) || die "VLAN tag must be between 1 and 4094."
  NET0+=",tag=$((10#$VLAN))"
fi
if [[ -n "$MEDIA_DOMAINS" ]]; then
  [[ "$MEDIA_DOMAINS" =~ ^[A-Za-z0-9.:-]+(,[A-Za-z0-9.:-]+)*$ ]] || die "Allowed image domains must be a comma-separated list of hostnames or IPs."
  OVMS_EXTRA_ARGS="--allowed_media_domains ${MEDIA_DOMAINS}"
fi

ROOT_STORAGE="$(choose_storage 'Container root disk' rootdir local-lvm "$((ROOTFS_GB + MIN_ROOT_STORAGE_FREE_GB))")"
TEMPLATE_STORAGE="$(choose_storage 'Ubuntu template' vztmpl local "$MIN_TEMPLATE_STORAGE_FREE_GB")"

msg_info "Refreshing Proxmox template catalog"
pveam update
TEMPLATE="$(pveam available --section system | awk 'NF >= 2 && $2 ~ /^ubuntu-24\.04-standard_/ { print $2 }' | sort -V | tail -n1)"
[[ -n "$TEMPLATE" ]] || die "Could not find an Ubuntu 24.04 LXC template."
TEMPLATE_VOL="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
TEMPLATE_PATH="$(pvesm path "$TEMPLATE_VOL" 2>/dev/null || true)"
TEMPLATE_PRESENT=0
if [[ -n "$TEMPLATE_PATH" && -f "$TEMPLATE_PATH" ]]; then TEMPLATE_PRESENT=1; fi

PLAN="Create a NEW container with these settings?

CTID: ${NEW_CTID}
Hostname: ${CT_HOSTNAME}
CPU: ${CORES} cores    RAM: ${MEMORY} MiB    Swap: ${SWAP} MiB
Root disk: ${ROOTFS_GB} GiB on ${ROOT_STORAGE}
Network: ${NET0}
GPU render node: ${GPU_NODE}
Extra OVMS arguments: ${OVMS_EXTRA_ARGS:-none}

Template: ${TEMPLATE} ($([[ "$TEMPLATE_PRESENT" == 1 ]] && printf 'already cached' || printf 'will download to %s' "$TEMPLATE_STORAGE"))
OVMS model: ${OVMS_MODEL_NAME} (~3.1 GB, first startup)
Validation: GPU-only text and image inference; install stops on failure and does not switch to CPU.

No container is created and no template is downloaded until you confirm. Existing guests are not modified."
if ! whiptail --backtitle "OVMS Proxmox Helper" --title "CONFIRM INSTALLATION" --yesno "$PLAN" 24 80; then
  msg_info "Cancelled; no container was created."
  exit 0
fi

if (( TEMPLATE_PRESENT == 0 )); then
  msg_info "Downloading Ubuntu template ${TEMPLATE} to ${TEMPLATE_STORAGE}"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  TEMPLATE_PATH="$(pvesm path "$TEMPLATE_VOL" 2>/dev/null || true)"
  [[ -n "$TEMPLATE_PATH" && -f "$TEMPLATE_PATH" ]] || die "Template download completed but the archive is missing from ${TEMPLATE_STORAGE}."
fi

ROOT_PASSWORD="$(openssl rand -hex 20)"

msg_info "Creating CT ${NEW_CTID}; existing containers and VMs are not modified"
pct create "$NEW_CTID" "$TEMPLATE_VOL" \
  --description "OpenVINO Model Server; personal helper v${HELPER_VERSION}; model ${OVMS_MODEL_NAME}" \
  --features nesting=1,keyctl=1 \
  --ostype ubuntu \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${ROOT_STORAGE}:${ROOTFS_GB}" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --onboot 1
CTID="$NEW_CTID"
CT_TOUCHED=1

msg_ok "Container ${CTID} created; Intel render device will be mapped to its service group during setup"
pct start "$CTID"

msg_info "Waiting for Ubuntu container to boot"
wait_for_ct "$CTID" || die "CT ${CTID} did not become ready."
# Set the password over stdin so it never appears in the host process list.
printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CTID" -- chpasswd

install_ovms "$CTID"

print_install_summary "$CTID" "$CT_HOSTNAME" "$ROOT_PASSWORD"
