#!/usr/bin/env bash
# Personal Proxmox VE helper: creates an Ubuntu LXC and installs native OVMS.
# Standalone implementation following the Community Scripts interaction style.
set -Eeuo pipefail

readonly HELPER_VERSION="1.3.0"
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

header_info() {
  printf '\033[1;36m\n  OpenVINO Model Server LXC\n  Personal Proxmox VE Helper · Ubuntu 24.04 · Native install\033[0m\n\n'
}

msg_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
msg_ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
msg_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
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
  local version major_minor major minor
  command -v pveversion >/dev/null 2>&1 || die "This does not look like a Proxmox VE host (pveversion not found)."
  version="$(pveversion | awk -F/ 'NR == 1 { print $2 }' | cut -d- -f1)"
  major_minor="$(cut -d. -f1-2 <<<"$version")"
  [[ "$major_minor" =~ ^([0-9]+)\.([0-9]+)$ ]] || die "Could not parse Proxmox VE version '${version:-unknown}'."
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  major=$((10#$major))
  minor=$((10#$minor))
  (( major == 8 && minor >= 4 || major == 9 )) || die "Unsupported Proxmox VE version '${version:-unknown}'. This helper requires PVE 8.4 or newer in the 8.x/9.x series."
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
host_gpu_check

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
  local candidate="$1" config hostname os_info marker service
  [[ "$candidate" =~ ^[1-9][0-9]{2,5}$ ]] || die "CTID must be between 100 and 999999, with no leading zero."
  [[ -f "/etc/pve/lxc/${candidate}.conf" ]] || die "LXC ${candidate} does not exist on this node."
  config="$(pct config "$candidate")"
  hostname="$(awk -F': ' '$1 == "hostname" { print $2; exit }' <<<"$config")"
  [[ -n "$hostname" ]] || die "Could not read the hostname for LXC ${candidate}."
  REPAIR_HOSTNAME="$hostname"
  grep -Eq '^dev[0-9]+: .*renderD128' <<<"$config" || die "LXC ${candidate} does not have /dev/dri/renderD128 mapped; refusing to modify it."
  pct status "$candidate" | grep -q 'status: running' || die "LXC ${candidate} must be running before repair."
  os_info="$(pct exec "$candidate" -- bash -lc '. /etc/os-release; printf "%s:%s" "$ID" "$VERSION_ID"' 2>/dev/null || true)"
  [[ "$os_info" == ubuntu:24.04 ]] || die "Repair only supports Ubuntu 24.04 containers; CT ${candidate} reports '${os_info:-unknown}'."
  if pct exec "$candidate" -- test -f /etc/ovms/proxmox-helper-managed 2>/dev/null; then marker=0; else marker=1; fi
  if pct exec "$candidate" -- test -f /etc/systemd/system/ovms.service 2>/dev/null; then service=0; else service=1; fi
  if (( marker != 0 )); then
    [[ "$hostname" == ovms && "$service" == 0 ]] || die "CT ${candidate} has no OVMS helper ownership marker. Refusing to modify an unrelated container."
    REPAIR_ADOPT=1
  else
    REPAIR_ADOPT=0
  fi
}

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

Default: next free CTID, 8 cores, 16 GiB RAM, 48 GiB disk, DHCP.
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
  free_kib="$(storage_free_kib "$selected" "$content")"
  free_gib=$((free_kib / 1024 / 1024))
  msg_info "$label storage: $selected (${free_gib} GiB free)" >&2
  printf '%s' "$selected"
}

ensure_lxc_features() {
  local target_ct="$1" existing feature
  local -a features=()
  existing="$(pct config "$target_ct" | awk -F': ' '$1 == "features" { print $2; exit }')"
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

install_ovms() {
  local target_ct="$1"
  local render_gid attempt root_free_kib
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
    bash -s <<'IN_CONTAINER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if [[ -e /usr/bin/update || -L /usr/bin/update ]] && ! grep -Fq 'exec /usr/local/bin/ovms-helper update' /usr/bin/update; then
  echo "/usr/bin/update already exists and is not managed by this helper; refusing to overwrite it." >&2
  exit 1
fi
systemctl stop ovms.service 2>/dev/null || true

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

mkdir -p /opt /var/lib/ovms/models /var/lib/ovms/.cache/huggingface /etc/ovms
cd /tmp
curl -fL --retry 3 "$OVMS_RELEASE_URL" -o "$OVMS_ARCHIVE"
echo "$OVMS_SHA256  $OVMS_ARCHIVE" | sha256sum --check --status || {
  echo "OVMS archive SHA256 verification failed" >&2
  exit 1
}
tar -xzf "$OVMS_ARCHIVE" -C /opt
[[ -x /opt/ovms/bin/ovms ]] || { echo "Expected /opt/ovms/bin/ovms after extraction" >&2; exit 1; }
rm -f -- "/tmp/$OVMS_ARCHIVE"

# OVMS's Python-enabled native bundle needs these chat-template dependencies.
python3 -m pip install --break-system-packages \
  'Jinja2==3.1.6' 'MarkupSafe==3.0.2' numpy

# Give the unprivileged server only render-node access, not container root.
getent group render >/dev/null || groupadd --system render
id -u ovms >/dev/null 2>&1 || useradd --system --home-dir /var/lib/ovms --shell /usr/sbin/nologin ovms
usermod --append --groups render ovms
chown -R ovms:ovms /var/lib/ovms
chmod 0750 /var/lib/ovms
printf '%s\n' "$(getent group render | cut -d: -f3)" >/etc/ovms/render.gid
printf 'HELPER_VERSION=%s\nCTID=%s\nMODEL_ID=%s\n' \
  "$HELPER_VERSION" "$CTID" "$OVMS_MODEL_ID" >/etc/ovms/proxmox-helper-managed
chmod 0644 /etc/ovms/proxmox-helper-managed
cat >/etc/ovms/ovms.env <<'EOF'
OVMS_TARGET_DEVICE=GPU
EOF
chmod 0644 /etc/ovms/ovms.env

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
    runtime_before="$(mktemp)"
    runtime_after="$(mktemp)"
    runtime_diff="$(mktemp)"
    ovms_was_active=0
    systemctl is-active --quiet ovms && ovms_was_active=1 || true
    systemctl stop ovms
    update_cleanup() {
      rm -f -- "$runtime_before" "$runtime_after" "$runtime_diff"
      if [[ "$ovms_was_active" == 1 ]] && ! systemctl is-active --quiet ovms; then systemctl start ovms || true; fi
    }
    trap update_cleanup EXIT
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | grep -Ei '(intel|level-zero|libze|openvino|igdgmm)' | sort >"$runtime_before" || true
    apt-get update
    apt-get full-upgrade -y
    dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null | grep -Ei '(intel|level-zero|libze|openvino|igdgmm)' | sort >"$runtime_after" || true
    if ! diff -u "$runtime_before" "$runtime_after" >"$runtime_diff"; then
      printf '\nIntel/OpenVINO runtime package versions changed during update; validating inference against the updated stack.\n'
      cat "$runtime_diff"
      { date --iso-8601=seconds; cat "$runtime_diff"; printf '\n'; } >>/var/log/ovms-runtime-updates.log
    fi
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
set -Eeuo pipefail
readonly MODEL_NAME="qwen3-vl-4b"
readonly API_URL="http://127.0.0.1:8000"
readonly WAIT_SECONDS=1800

if (( $# > 0 )); then
  echo "Usage: ovms-healthcheck (tests the configured device only; no CPU fallback)." >&2
  exit 2
fi

current_device() {
  . /etc/ovms/ovms.env
  printf '%s' "${OVMS_TARGET_DEVICE:-GPU}"
}

check_gpu_access() {
  if ! runuser -u ovms -- clinfo -l 2>&1 | grep -qi Intel; then
    echo "WARNING: clinfo cannot see an Intel GPU as the unprivileged ovms service user." >&2
    return 1
  fi
}

wait_for_model() {
  local deadline=$((SECONDS + WAIT_SECONDS)) response initial_restarts restarts
  initial_restarts="$(systemctl show --property=NRestarts --value ovms 2>/dev/null || printf 0)"
  while (( SECONDS < deadline )); do
    if systemctl is-active --quiet ovms; then
      response="$(curl -fsS --max-time 5 "$API_URL/v1/models" 2>/dev/null || true)"
      if grep -Fq "\"id\":\"$MODEL_NAME\"" <<<"$response"; then
        return 0
      fi
    fi
    restarts="$(systemctl show --property=NRestarts --value ovms 2>/dev/null || printf 0)"
    if [[ "$initial_restarts" =~ ^[0-9]+$ && "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= initial_restarts + 4 )); then
      echo "OVMS has restarted repeatedly while loading the model; not waiting the full download timeout." >&2
      journalctl -u ovms -n 40 --no-pager >&2 || true
      return 1
    fi
    sleep 5
  done
  echo "OVMS model did not become available within $WAIT_SECONDS seconds." >&2
  journalctl -u ovms -n 40 --no-pager >&2 || true
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
  payload='{"model":"qwen3-vl-4b","messages":[{"role":"user","content":"Reply with the exact token OVMS_HEALTH_OK and nothing else."}],"max_tokens":24,"temperature":0,"stream":false}'
  response="$(curl -fsS --max-time 240 "$API_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null)" || return 1
  python3 -c 'import json,sys; d=json.load(sys.stdin); c=d["choices"][0]["message"]["content"]; sys.exit(0 if "OVMS_HEALTH_OK" in c else 1)' <<<"$response"
}

image_probe() {
  local image_b64 payload response
  image_b64="$(make_red_image)" || return 1
  payload="$(python3 - "$image_b64" <<'PY'
import json, sys
image = sys.argv[1]
print(json.dumps({"model":"qwen3-vl-4b","messages":[{"role":"user","content":[{"type":"text","text":"What color is the solid square? Reply with the single word RED."},{"type":"image_url","image_url":{"url":"data:image/png;base64," + image}}]}],"max_tokens":24,"temperature":0,"stream":False}))
PY
)" || return 1
  response="$(curl -fsS --max-time 240 "$API_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null)" || return 1
  python3 -c 'import json,re,sys; d=json.load(sys.stdin); c=d["choices"][0]["message"]["content"]; sys.exit(0 if re.search(r"\bred\b", c, re.I) else 1)' <<<"$response"
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
  systemctl is-active --quiet ovms
}

device="$(current_device)"
echo "Testing OVMS text and image inference with target device: $device"
if [[ "$device" == GPU ]]; then check_gpu_access || true; fi
if run_probes; then
  echo "[OK] Text and image inference passed; OVMS stayed running on $device."
  exit 0
fi
journalctl -u ovms -n 40 --no-pager >&2 || true
echo "[ERROR] OVMS did not pass its $device inference health checks; device setting was not changed." >&2
exit 1
HEALTHCHECK
chmod 0755 /usr/local/sbin/ovms-healthcheck

cat >/etc/systemd/system/ovms.service <<EOF
[Unit]
Description=OpenVINO Model Server (Intel GPU)
Wants=network-online.target
After=network-online.target

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
ExecStart=/opt/ovms/bin/ovms --source_model ${OVMS_MODEL_ID} --model_repository_path /var/lib/ovms/models --model_name ${OVMS_MODEL_NAME} --rest_port 8000 --task text_generation --pipeline_type VLM --target_device \${OVMS_TARGET_DEVICE}
Restart=on-failure
RestartSec=5
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
  if pct status "$target_ct" | grep -q 'status: running'; then
    pct shutdown "$target_ct" --timeout 60 >/dev/null 2>&1 || true
    if pct status "$target_ct" | grep -q 'status: running'; then pct stop "$target_ct"; fi
  fi
  ensure_lxc_features "$target_ct"
  msg_info "Mapping /dev/dri/renderD128 to the LXC render group (GID ${render_gid})"
  pct set "$target_ct" --dev0 "path=/dev/dri/renderD128,uid=0,gid=${render_gid},mode=0660"
  pct start "$target_ct"
  for attempt in $(seq 1 30); do
    if pct exec "$target_ct" -- true >/dev/null 2>&1; then break; fi
    sleep 2
  done
  pct exec "$target_ct" -- true >/dev/null 2>&1 || die "CT ${target_ct} did not restart after applying its render-group mapping."
  pct exec "$target_ct" -- bash -lc 'clinfo -l 2>&1 | grep -qi Intel' || msg_warn "clinfo cannot see the Intel GPU in CT ${target_ct}; GPU-only inference validation may fail. No CPU fallback will be performed."
  pct exec "$target_ct" -- systemctl enable --now ovms.service
  pct exec "$target_ct" -- /usr/local/sbin/ovms-healthcheck
}

print_install_summary() {
  local target_ct="$1" ct_hostname="$2" root_password="${3:-}" ct_ip target_device
  ct_ip="$(pct exec "$target_ct" -- hostname -I 2>/dev/null | awk '{ print $1 }' || true)"
  target_device="$(pct exec "$target_ct" -- bash -lc '. /etc/ovms/ovms.env; printf "%s" "${OVMS_TARGET_DEVICE:-GPU}"' 2>/dev/null || printf 'unknown')"
  msg_ok "Text and image inference checks passed on ${target_device}."
  if [[ "$target_device" != GPU ]]; then
    printf '\033[1;33m[WARN]\033[0m OVMS is configured for %s; GPU acceleration is not verified.\n' "$target_device"
  fi
  printf '\nContainer: %s (%s); render device: /dev/dri/renderD128\n' "$target_ct" "$ct_hostname"
  printf 'OpenAI-compatible endpoint: http://%s:8000/v1\n' "${ct_ip:-<CT-IP>}"
  printf 'Model name for clients: %s\n' "$OVMS_MODEL_NAME"
  printf 'Status: pct exec %s -- systemctl status ovms\n' "$target_ct"
  printf 'Logs: pct exec %s -- journalctl -u ovms -f\n' "$target_ct"
  printf 'Update this container: pct exec %s -- update\n' "$target_ct"
  printf 'Service helper: pct exec %s -- ovms-helper {status|restart|logs|healthcheck|update}\n' "$target_ct"
  printf 'Console autologin: enabled on LXC tty1 only; SSH is not enabled by this helper.\n'
  printf 'The API has no authentication configured; keep it on your trusted LAN or firewall it to Home Assistant.\n'
  [[ -z "$root_password" ]] || printf 'Root console password: %s\n' "$root_password"
}

if [[ -n "$REPAIR_CTID" ]]; then
  CTID="$REPAIR_CTID"
  validate_repair_ct "$CTID"
  REPAIR_NOTE=""
  if [[ "${REPAIR_ADOPT:-0}" == 1 ]]; then
    REPAIR_NOTE=$'\n\nThis CT has no helper ownership marker. You are explicitly adopting it as the OVMS helper container.'
  fi
  if ! whiptail --backtitle "OVMS Proxmox Helper" --title "REPAIR EXISTING CONTAINER" \
    --yesno "Retry OVMS installation inside existing CT ${CTID} (${REPAIR_HOSTNAME})?

Only this running CT will be changed. Confirm this is the partial OVMS container and that its Intel GPU mapping is present. No new container will be created.${REPAIR_NOTE}" 17 76; then
    msg_info "Repair cancelled; no changes were made."
    exit 0
  fi
  install_ovms "$CTID"
  CT_HOSTNAME="$(pct config "$CTID" | awk -F': ' '$1 == "hostname" { print $2; exit }')"
  msg_ok "Repair completed; model text and image inference was validated."
  print_install_summary "$CTID" "$CT_HOSTNAME"
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
  ROOTFS_GB="$(ask_default 'Root disk (GiB)' "$DEFAULT_ROOTFS_GB")"
  BRIDGE="$(ask_default 'Network bridge' 'vmbr0')"
else
  CTID="$AUTO_ID"
  HOSTNAME='ovms'
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
[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Invalid hostname."
[[ "$BRIDGE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die "Invalid bridge interface name."
if [[ -d "/sys/class/net/${BRIDGE}/bridge" ]]; then
  :
elif command -v ovs-vsctl >/dev/null 2>&1 && ovs-vsctl br-exists "$BRIDGE" >/dev/null 2>&1; then
  :
else
  die "'$BRIDGE' is not an existing Linux or Open vSwitch bridge on this host."
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

CTID: ${CTID}
Hostname: ${HOSTNAME}
CPU: ${CORES} cores
RAM: ${MEMORY} MiB
Root disk: ${ROOTFS_GB} GiB
Root storage: ${ROOT_STORAGE}
Template storage: ${TEMPLATE_STORAGE}
Bridge: ${BRIDGE} (DHCP)

Template: ${TEMPLATE} ($([[ "$TEMPLATE_PRESENT" == 1 ]] && printf 'already cached' || printf 'will download after confirmation'))
OVMS model: ${OVMS_MODEL_NAME} (~3.1 GB, first startup)
Validation: GPU-only text and image inference; install stops on failure and does not switch to CPU.

No container is created and no template is downloaded until you confirm. Existing guests are not modified."
if ! whiptail --backtitle "OVMS Proxmox Helper" --title "CONFIRM INSTALLATION" --yesno "$PLAN" 22 78; then
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
GPU_NODE='/dev/dri/renderD128'

msg_info "Creating CT ${CTID}; existing containers and VMs are not modified"
pct create "$CTID" "$TEMPLATE_VOL" \
  --description "OpenVINO Model Server; personal helper v${HELPER_VERSION}; model ${OVMS_MODEL_NAME}" \
  --features nesting=1,keyctl=1 \
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

msg_ok "Container ${CTID} created; Intel render device will be mapped to its service group during setup"
pct start "$CTID"

msg_info "Waiting for Ubuntu container to boot"
for attempt in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CTID" -- true >/dev/null 2>&1 || die "CT ${CTID} did not become ready. It is preserved for troubleshooting."

install_ovms "$CTID"

print_install_summary "$CTID" "$HOSTNAME" "$ROOT_PASSWORD"
