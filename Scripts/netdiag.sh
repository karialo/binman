#!/usr/bin/env bash
# Description: Network diagnostics CLI for usb0/wlan0 and related interfaces
VERSION="0.1.0"
set -u -o pipefail

PROG="netdiag"
START_TS="$(date '+%Y-%m-%d %H:%M:%S %z')"
START_EPOCH="$(date +%s)"

MODE="quick"
JSON_MODE=0
VERBOSE=0
NO_SUDO=0
IFACE_ARG=""
TARGET_ARG=""
TARGET=""
WRITE_REPORT_ARG=""
SUPPORT_BUNDLE_ARG=""
ELEVATED=0

HAS_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
fi

TMP_ROOT="${TMPDIR:-/tmp}"
CMD_LOG_FILE="$(mktemp "${TMP_ROOT}/netdiag-cmd.XXXXXX")"

REPORT_FILE=""
SUPPORT_DIR=""

ROUTE_GET_OUTPUT=""
ROUTE_DEV=""
ROUTE_SRC=""
DEFAULT_GW=""
TARGET_REACHABLE=0
GATEWAY_REACHABLE=0
ARPING_REACHABLE=0
USB_ENUM_FOUND=0

SECTION_A=""
SECTION_B=""
SECTION_C=""
SECTION_D=""
SECTION_E=""
SECTION_F=""
SECTION_G=""
SECTION_H=""
SECTION_I=""
SECTION_J=""
SUMMARY_TEXT=""

CMD_COUNT=0

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "${PROG}: requires bash 4+" >&2
  exit 2
fi

declare -a IFACES=()
declare -A IF_STATE=()
declare -A IF_CARRIER=()
declare -A IF_DRIVER=()
declare -A IF_SPEED=()
declare -A IF_DUPLEX=()
declare -A IF_ADDR4=()
declare -A IF_ADDR6=()
declare -A IF_USB_HINT=()
declare -A IF_NM_STATE=()
declare -A IF_RP_FILTER=()
declare -A IF_ACCEPT_RA=()
declare -A IF_DISABLE_IPV6=()
declare -A IF_DHCP_HINT=()

declare -a ISSUE_SEV=()
declare -a ISSUE_MSG=()
declare -a ISSUE_CAUSE=()
declare -a ISSUE_CONF=()
declare -a ISSUE_FIX=()
declare -a NEXT_ACTIONS=()
declare -a NEEDS_SUDO_ITEMS=()

cleanup() {
  rm -f "$CMD_LOG_FILE" 2>/dev/null || true
}
trap cleanup EXIT

usage() {
  cat <<USAGE
$PROG v$VERSION

Usage:
  $PROG [--quick|--full] [--iface IFACE] [--json] [--no-sudo]
        [--write-report PATH] [--support-bundle DIR] [--target HOST_OR_IP]
        [--verbose] [-h|--help]

Modes:
  --quick              Fast checks only (default)
  --full               Full diagnostics (includes privileged checks when available)

Options:
  --iface IFACE        Focus on a specific interface (default: auto detect)
  --json               Emit machine-readable JSON
  --no-sudo            Never escalate privileges; report "needs sudo" items instead
  --write-report PATH  Write timestamped text report to PATH (file prefix or dir)
  --support-bundle DIR Write redacted support bundle under DIR
  --target VALUE       Ping target (default: interactive prompt, fallback 10.0.0.2)
  --verbose            Echo every executed command
  -h, --help           Show this help
USAGE
}

print_hr() {
  local title="$1"
  [[ "$JSON_MODE" -eq 1 ]] && return 0
  printf '\n-----\n%s\n-----\n' "$title"
}

print_note() {
  [[ "$JSON_MODE" -eq 1 ]] && return 0
  printf '%s\n' "$*"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

redact_stream() {
  sed -E \
    -e 's/([Pp][Ss][Kk][[:space:]]*=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Pp]assword[[:space:]]*=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]*=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Pp][Ss][Kk][[:space:]]*:[[:space:]]*).*/\1[REDACTED]/g' \
    -e 's/([Pp]assword[[:space:]]*:[[:space:]]*).*/\1[REDACTED]/g' \
    -e 's/([Tt]oken[[:space:]]*:[[:space:]]*).*/\1[REDACTED]/g'
}

command_string() {
  local out=""
  local a
  for a in "$@"; do
    out+="$(printf '%q ' "$a")"
  done
  printf '%s' "${out% }"
}

run_cmd() {
  local timeout_s="$1"
  shift
  local -a cmd=("$@")
  local pretty
  pretty="$(command_string "${cmd[@]}")"

  CMD_COUNT=$((CMD_COUNT + 1))
  printf '[cmd] %s\n' "$pretty" >> "$CMD_LOG_FILE"
  if [[ "$VERBOSE" -eq 1 && "$JSON_MODE" -eq 0 ]]; then
    printf '[cmd] %s\n' "$pretty"
  fi

  local out rc
  if [[ "$HAS_TIMEOUT" -eq 1 && "$timeout_s" -gt 0 ]]; then
    out="$(timeout "$timeout_s" "${cmd[@]}" 2>&1)"
    rc=$?
    if [[ "$rc" -eq 124 ]]; then
      out+=$'\n'
      out+="[timed out after ${timeout_s}s]"
    fi
  else
    out="$("${cmd[@]}" 2>&1)"
    rc=$?
  fi

  printf '%s\n\n' "$out" >> "$CMD_LOG_FILE"
  printf '%s' "$out"
  return "$rc"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

resolve_report_path() {
  local raw="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -d "$raw" || "$raw" == */ ]]; then
    printf '%s/netdiag-report-%s.txt' "${raw%/}" "$ts"
    return 0
  fi

  local base="$raw"
  local dir
  dir="$(dirname "$base")"
  if [[ "$dir" != "." ]]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi

  if [[ "$base" == *.txt ]]; then
    printf '%s-%s.txt' "${base%.txt}" "$ts"
  else
    printf '%s-%s.txt' "$base" "$ts"
  fi
}

init_report() {
  [[ -z "$WRITE_REPORT_ARG" ]] && return 0
  REPORT_FILE="$(resolve_report_path "$WRITE_REPORT_ARG")"
  mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null || true
  exec > >(tee -a "$REPORT_FILE") 2>&1
  print_note "Report file: $REPORT_FILE"
}

add_issue() {
  local sev="$1"
  local msg="$2"
  local cause="$3"
  local conf="$4"
  local fix="$5"
  ISSUE_SEV+=("$sev")
  ISSUE_MSG+=("$msg")
  ISSUE_CAUSE+=("$cause")
  ISSUE_CONF+=("$conf")
  ISSUE_FIX+=("$fix")
}

add_next_action() {
  local action="$1"
  local exists=0
  local a
  for a in "${NEXT_ACTIONS[@]}"; do
    if [[ "$a" == "$action" ]]; then
      exists=1
      break
    fi
  done
  [[ "$exists" -eq 0 ]] && NEXT_ACTIONS+=("$action")
}

mark_needs_sudo() {
  local item="$1"
  NEEDS_SUDO_ITEMS+=("$item")
}

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  local o1 o2 o3 o4
  read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$o" -ge 0 && "$o" -le 255 ]] || return 1
  done
  return 0
}

is_valid_target() {
  local t="$1"
  if is_valid_ipv4 "$t"; then
    return 0
  fi
  [[ "$t" =~ ^[A-Za-z0-9._-]+$ ]]
}

prompt_target() {
  if [[ -n "$TARGET_ARG" ]]; then
    TARGET="$TARGET_ARG"
    return 0
  fi

  local default_target="10.0.0.2"

  if [[ -t 0 ]]; then
    while true; do
      local input
      printf 'Target IP/host to test [%s]: ' "$default_target" >&2
      read -r input
      if [[ -z "$input" ]]; then
        TARGET="$default_target"
        break
      fi
      if is_valid_target "$input"; then
        TARGET="$input"
        break
      fi
      printf 'Invalid target. Try IPv4 (e.g. 10.0.0.2) or hostname.\n' >&2
    done
  else
    TARGET="$default_target"
  fi
}

read_driver_name() {
  local iface="$1"
  local path
  path="$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    basename "$path"
  else
    printf 'unknown'
  fi
}

iface_usb_hint() {
  local iface="$1"
  local driver="$2"
  if [[ "$driver" =~ ^(cdc_ether|rndis_host|cdc_ncm|cdc_mbim|usbnet|asix|ax88179_178a|r8152|smsc95xx)$ ]]; then
    printf 'yes'
    return 0
  fi

  if has_cmd udevadm; then
    local props
    props="$(run_cmd 3 udevadm info --query=property --name "$iface" || true)"
    if printf '%s\n' "$props" | grep -Eq '(^ID_BUS=usb$|ID_USB_DRIVER=|ID_MODEL=.*RNDIS|ID_MODEL=.*CDC)'; then
      printf 'yes'
      return 0
    fi
  fi

  printf 'no'
}

append_iface_unique() {
  local iface="$1"
  local existing
  for existing in "${IFACES[@]}"; do
    [[ "$existing" == "$iface" ]] && return 0
  done
  IFACES+=("$iface")
}

detect_interfaces() {
  IFACES=()

  if [[ -n "$IFACE_ARG" ]]; then
    append_iface_unique "$IFACE_ARG"
    return 0
  fi

  local all_ifaces=()
  local iface
  if has_cmd ip; then
    while IFS= read -r iface; do
      [[ -n "$iface" ]] && all_ifaces+=("$iface")
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk -F'@' '{print $1}')
  else
    while IFS= read -r iface; do
      iface="${iface##*/}"
      [[ -n "$iface" ]] && all_ifaces+=("$iface")
    done < <(ls -1 /sys/class/net 2>/dev/null)
  fi

  local ordered=()
  for iface in "${all_ifaces[@]}"; do
    [[ "$iface" == "usb0" ]] && ordered+=("$iface")
  done
  for iface in "${all_ifaces[@]}"; do
    [[ "$iface" == enx* ]] && ordered+=("$iface")
  done
  for iface in "${all_ifaces[@]}"; do
    [[ "$iface" == enp* ]] && ordered+=("$iface")
  done
  for iface in "${all_ifaces[@]}"; do
    [[ "$iface" == eth* ]] && ordered+=("$iface")
  done
  for iface in "${all_ifaces[@]}"; do
    [[ "$iface" == "wlan0" ]] && ordered+=("$iface")
  done

  for iface in "${ordered[@]}"; do
    append_iface_unique "$iface"
  done

  if [[ "${#IFACES[@]}" -eq 0 ]]; then
    for iface in "${all_ifaces[@]}"; do
      append_iface_unique "$iface"
    done
  fi
}

collect_iface_data() {
  local iface="$1"
  local state="unknown"
  local carrier="n/a"
  local driver
  local addr4=""
  local addr6=""
  local speed="n/a"
  local duplex="n/a"
  local rp="n/a"
  local ra="n/a"
  local dis6="n/a"
  local nmstate="unknown"
  local dhcp_hint="unknown"

  [[ -r "/sys/class/net/$iface/operstate" ]] && state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"
  [[ -r "/sys/class/net/$iface/carrier" ]] && carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo n/a)"
  driver="$(read_driver_name "$iface")"

  if has_cmd ip; then
    addr4="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | paste -sd',' -)"
    addr6="$(ip -6 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | paste -sd',' -)"
  fi

  if has_cmd ethtool; then
    local eo
    eo="$(run_cmd 3 ethtool "$iface" || true)"
    speed="$(printf '%s\n' "$eo" | awk -F': ' '/Speed:/{print $2; exit}')"
    duplex="$(printf '%s\n' "$eo" | awk -F': ' '/Duplex:/{print $2; exit}')"
    [[ -z "$speed" ]] && speed="n/a"
    [[ -z "$duplex" ]] && duplex="n/a"
  fi

  [[ -r "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]] && rp="$(cat "/proc/sys/net/ipv4/conf/$iface/rp_filter" 2>/dev/null || echo n/a)"
  [[ -r "/proc/sys/net/ipv6/conf/$iface/accept_ra" ]] && ra="$(cat "/proc/sys/net/ipv6/conf/$iface/accept_ra" 2>/dev/null || echo n/a)"
  [[ -r "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" ]] && dis6="$(cat "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" 2>/dev/null || echo n/a)"

  if has_cmd nmcli; then
    local nm_line
    nm_line="$(run_cmd 4 nmcli -t -f DEVICE,STATE,CONNECTION device status | awk -F: -v d="$iface" '$1==d{print $0; exit}' || true)"
    if [[ -n "$nm_line" ]]; then
      nmstate="$(printf '%s' "$nm_line" | awk -F: '{print $2}')"
      if printf '%s\n' "$nm_line" | grep -qi 'connected'; then
        dhcp_hint="possible"
      fi
      if printf '%s\n' "$nm_line" | grep -qi 'unmanaged'; then
        dhcp_hint="unmanaged"
      fi
    else
      nmstate="not-listed"
      dhcp_hint="unknown"
    fi
  fi

  IF_STATE["$iface"]="$state"
  IF_CARRIER["$iface"]="$carrier"
  IF_DRIVER["$iface"]="$driver"
  IF_ADDR4["$iface"]="$addr4"
  IF_ADDR6["$iface"]="$addr6"
  IF_SPEED["$iface"]="$speed"
  IF_DUPLEX["$iface"]="$duplex"
  IF_RP_FILTER["$iface"]="$rp"
  IF_ACCEPT_RA["$iface"]="$ra"
  IF_DISABLE_IPV6["$iface"]="$dis6"
  IF_NM_STATE["$iface"]="$nmstate"
  IF_DHCP_HINT["$iface"]="$dhcp_hint"
  IF_USB_HINT["$iface"]="$(iface_usb_hint "$iface" "$driver")"
}

maybe_reexec_sudo() {
  [[ "$MODE" != "full" ]] && return 0
  [[ "$EUID" -eq 0 ]] && return 0
  [[ "$NO_SUDO" -eq 1 ]] && return 0
  [[ "$ELEVATED" -eq 1 ]] && return 0

  if ! has_cmd sudo; then
    mark_needs_sudo "sudo not available; privileged checks skipped"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    mark_needs_sudo "non-interactive mode; cannot prompt for sudo"
    return 0
  fi

  [[ "$JSON_MODE" -eq 0 ]] && print_note "Requesting sudo for full diagnostics ..."
  if ! sudo -v; then
    mark_needs_sudo "sudo authentication failed"
    return 0
  fi

  local -a reexec=("--full")
  [[ "$JSON_MODE" -eq 1 ]] && reexec+=("--json")
  [[ "$VERBOSE" -eq 1 ]] && reexec+=("--verbose")
  [[ -n "$IFACE_ARG" ]] && reexec+=("--iface" "$IFACE_ARG")
  [[ -n "$WRITE_REPORT_ARG" ]] && reexec+=("--write-report" "$WRITE_REPORT_ARG")
  [[ -n "$SUPPORT_BUNDLE_ARG" ]] && reexec+=("--support-bundle" "$SUPPORT_BUNDLE_ARG")
  [[ -n "$TARGET" ]] && reexec+=("--target" "$TARGET")

  exec sudo -E bash "$0" --_elevated "${reexec[@]}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quick) MODE="quick"; shift ;;
      --full) MODE="full"; shift ;;
      --iface)
        IFACE_ARG="${2:-}"
        [[ -z "$IFACE_ARG" ]] && { echo "$PROG: --iface requires value" >&2; exit 2; }
        shift 2
        ;;
      --json) JSON_MODE=1; shift ;;
      --no-sudo) NO_SUDO=1; shift ;;
      --write-report)
        WRITE_REPORT_ARG="${2:-}"
        [[ -z "$WRITE_REPORT_ARG" ]] && { echo "$PROG: --write-report requires value" >&2; exit 2; }
        shift 2
        ;;
      --support-bundle)
        SUPPORT_BUNDLE_ARG="${2:-}"
        [[ -z "$SUPPORT_BUNDLE_ARG" ]] && { echo "$PROG: --support-bundle requires value" >&2; exit 2; }
        shift 2
        ;;
      --target)
        TARGET_ARG="${2:-}"
        [[ -z "$TARGET_ARG" ]] && { echo "$PROG: --target requires value" >&2; exit 2; }
        shift 2
        ;;
      --verbose) VERBOSE=1; shift ;;
      --_elevated) ELEVATED=1; shift ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "$PROG: unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

section_a_system_info() {
  local hostname="$(hostname 2>/dev/null || echo unknown)"
  local kernel="$(uname -srmo 2>/dev/null || uname -a 2>/dev/null || echo unknown)"
  local distro="unknown"
  if [[ -r /etc/os-release ]]; then
    distro="$(grep -E '^(PRETTY_NAME=|NAME=)' /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"')"
  fi
  local uptime="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown)"

  SECTION_A=$(cat <<EOF_A
hostname: $hostname
kernel:   $kernel
distro:   $distro
date:     $START_TS
uptime:   $uptime
mode:     $MODE
json:     $JSON_MODE
iface:    ${IFACE_ARG:-auto}
target:   $TARGET
EOF_A
)

  print_hr "1) A) System Info"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_A"
}

section_b_inventory() {
  local out=""

  if has_cmd ip; then
    out+="$ ip -br link"$'\n'
    out+="$(run_cmd 3 ip -br link || true)"$'\n\n'

    out+="$ ip -br addr"$'\n'
    out+="$(run_cmd 3 ip -br addr || true)"$'\n\n'
  else
    out+="ip command missing"$'\n\n'
    add_issue "FAIL" "iproute2 tools missing" "Core network tools unavailable" "high" "Install iproute2 (Debian/Ubuntu: sudo apt install iproute2)."
  fi

  if has_cmd nmcli; then
    out+="$ nmcli dev status"$'\n'
    out+="$(run_cmd 4 nmcli dev status || true)"$'\n\n'
  else
    out+="nmcli not installed; skipping NetworkManager inventory"$'\n\n'
  fi

  if has_cmd ethtool; then
    local iface
    for iface in "${IFACES[@]}"; do
      out+="$ ethtool ${iface}"$'\n'
      out+="$(run_cmd 3 ethtool "$iface" || true)"$'\n\n'
    done
  else
    out+="ethtool not installed; speed/duplex checks reduced"$'\n\n'
  fi

  SECTION_B="$out"

  print_hr "2) B) Interface Inventory"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_B"
}

section_c_focus_iface() {
  local out=""
  local iface

  if [[ "${#IFACES[@]}" -eq 0 ]]; then
    out="No candidate interfaces detected."
    add_issue "FAIL" "No candidate interfaces found" "No usb0/enx/enp/eth/wlan0 interface present" "high" "Check adapter/cable and kernel driver."
    SECTION_C="$out"
    print_hr "3) C) Focused Interface Deep Dive"
    [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_C"
    return 0
  fi

  for iface in "${IFACES[@]}"; do
    collect_iface_data "$iface"

    out+="iface: $iface"$'\n'
    out+="  state: ${IF_STATE[$iface]}"$'\n'
    out+="  carrier: ${IF_CARRIER[$iface]}"$'\n'
    out+="  driver: ${IF_DRIVER[$iface]}"$'\n'
    out+="  usb-ethernet-hint: ${IF_USB_HINT[$iface]}"$'\n'
    out+="  ipv4: ${IF_ADDR4[$iface]:-(none)}"$'\n'
    out+="  ipv6: ${IF_ADDR6[$iface]:-(none)}"$'\n'
    out+="  speed: ${IF_SPEED[$iface]}"$'\n'
    out+="  duplex: ${IF_DUPLEX[$iface]}"$'\n'
    out+="  rp_filter: ${IF_RP_FILTER[$iface]}"$'\n'
    out+="  accept_ra: ${IF_ACCEPT_RA[$iface]}"$'\n'
    out+="  disable_ipv6: ${IF_DISABLE_IPV6[$iface]}"$'\n'
    out+="  nm_state: ${IF_NM_STATE[$iface]}"$'\n'

    if has_cmd ip; then
      out+="$ ip route show dev ${iface}"$'\n'
      out+="$(run_cmd 3 ip route show dev "$iface" || true)"$'\n'

      out+="$ ip -6 route show dev ${iface}"$'\n'
      out+="$(run_cmd 3 ip -6 route show dev "$iface" || true)"$'\n'
    fi

    if has_cmd udevadm; then
      out+="$ udevadm info --query=property --name ${iface}"$'\n'
      out+="$(run_cmd 4 udevadm info --query=property --name "$iface" || true)"$'\n'
    fi

    out+=$'\n'

    if [[ "${IF_STATE[$iface]}" != "up" ]]; then
      add_issue "WARN" "Interface $iface is ${IF_STATE[$iface]}" "Link is not fully up" "high" "ip link set $iface up"
      add_next_action "Bring interface up: ip link set $iface up"
    fi

    if [[ -z "${IF_ADDR4[$iface]}" ]]; then
      if [[ "$iface" == "usb0" || -n "$IFACE_ARG" ]]; then
        add_issue "WARN" "Interface $iface has no IPv4 address" "No L3 address on focused link" "high" "Host side example: ip addr add 10.0.0.1/24 dev $iface"
        add_next_action "Assign host IP if needed: ip addr add 10.0.0.1/24 dev $iface"
      fi
    fi

    if [[ "${IF_ADDR4[$iface]}" == *"169.254."* ]]; then
      add_issue "WARN" "Interface $iface has link-local 169.254.x.x" "DHCP/static mismatch likely" "medium" "Set static host/Pi USB-gadget IPs (10.0.0.1/24 and 10.0.0.2/24) or ensure DHCP server exists."
    fi

    if [[ "${IF_NM_STATE[$iface],,}" == "unmanaged" ]]; then
      add_issue "WARN" "NetworkManager shows $iface as unmanaged" "NM policy/udev unmanaged flag" "high" "Review udev rules for NM_UNMANAGED and run: nmcli device set $iface managed yes"
      add_next_action "Check unmanaged rules: grep -R NM_UNMANAGED /etc/udev/rules.d /usr/lib/udev/rules.d"
    fi
  done

  SECTION_C="$out"

  print_hr "3) C) Focused Interface Deep Dive"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_C"
}

section_d_route_target() {
  local out=""

  if has_cmd ip; then
    out+="$ ip route get $TARGET"$'\n'
    ROUTE_GET_OUTPUT="$(run_cmd 3 ip route get "$TARGET" || true)"
    out+="$ROUTE_GET_OUTPUT"$'\n\n'

    ROUTE_DEV="$(printf '%s\n' "$ROUTE_GET_OUTPUT" | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
    ROUTE_SRC="$(printf '%s\n' "$ROUTE_GET_OUTPUT" | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"

    out+="$ ip rule show"$'\n'
    out+="$(run_cmd 3 ip rule show || true)"$'\n\n'

    out+="$ ip route show table main"$'\n'
    out+="$(run_cmd 3 ip route show table main || true)"$'\n\n'

    DEFAULT_GW="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"

    if [[ -z "$ROUTE_DEV" ]]; then
      add_issue "FAIL" "No route to target $TARGET" "Kernel route lookup failed" "high" "Add route example: ip route add 10.0.0.0/24 dev usb0"
      add_next_action "Check route: ip route add 10.0.0.0/24 dev usb0"
    fi
  else
    out+="ip command missing; cannot evaluate routes"$'\n'
  fi

  SECTION_D="$out"

  print_hr "4) D) Routing To Target"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_D"
}

maybe_flush_neighbors() {
  local iface="$1"
  local do_flush=0

  [[ "$MODE" != "full" ]] && return 0
  [[ -z "$iface" ]] && return 0

  if [[ -t 0 && "$JSON_MODE" -eq 0 ]]; then
    local ans
    printf 'Flush neighbor table on %s and retest once? [y/N]: ' "$iface" >&2
    read -r ans
    if [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      do_flush=1
    fi
  fi

  [[ "$do_flush" -eq 0 ]] && return 0

  if [[ "$EUID" -ne 0 ]]; then
    if [[ "$NO_SUDO" -eq 1 ]]; then
      mark_needs_sudo "ip neigh flush dev $iface"
      return 0
    fi
    mark_needs_sudo "ip neigh flush dev $iface (rerun --full interactively for sudo re-exec)"
    return 0
  fi

  local flush_out
  flush_out="$(run_cmd 3 ip neigh flush dev "$iface" || true)"
  SECTION_E+="$ ip neigh flush dev ${iface}"$'\n'
  SECTION_E+="$flush_out"$'\n'

  local ping_once
  ping_once="$(run_cmd 4 ping -c 1 -W 1 "$TARGET" || true)"
  SECTION_E+="$ ping -c 1 -W 1 ${TARGET}"$'\n'
  SECTION_E+="$ping_once"$'\n'
}

section_e_neighbor() {
  local out=""
  local dev="${ROUTE_DEV:-}"
  if [[ -z "$dev" && "${#IFACES[@]}" -gt 0 ]]; then
    dev="${IFACES[0]}"
  fi

  if has_cmd ip; then
    if [[ -n "$dev" ]]; then
      out+="$ ip neigh show dev ${dev}"$'\n'
      out+="$(run_cmd 3 ip neigh show dev "$dev" || true)"$'\n\n'
    else
      out+="$ ip neigh show"$'\n'
      out+="$(run_cmd 3 ip neigh show || true)"$'\n\n'
    fi
  else
    out+="ip command missing; neighbor table skipped"$'\n'
  fi

  SECTION_E="$out"
  maybe_flush_neighbors "$dev"

  if printf '%s\n' "$SECTION_E" | grep -q 'FAILED'; then
    add_issue "WARN" "Neighbor resolution has FAILED entries" "ARP/ND resolution problem on path" "high" "Try flushing neighbors and reping target; verify both peers are in same subnet."
  fi

  print_hr "5) E) ARP / Neighbor"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_E"
}

section_f_ping_ladder() {
  local out=""
  local ping_out

  out+="$ ping -c 3 -W 1 ${TARGET}"$'\n'
  ping_out="$(run_cmd 6 ping -c 3 -W 1 "$TARGET" || true)"
  out+="$ping_out"$'\n\n'
  if printf '%s\n' "$ping_out" | grep -Eq '([1-9][0-9]* packets transmitted, [1-9][0-9]* received|bytes from)'; then
    TARGET_REACHABLE=1
  else
    TARGET_REACHABLE=0
    add_issue "FAIL" "Target $TARGET is not reachable by ping" "ICMP failed to reach target" "high" "Check cable/OTG mode, IP config, route, and firewall policy."
    add_next_action "Verify host/Pi USB gadget IPs: host 10.0.0.1/24, Pi 10.0.0.2/24"
  fi

  if [[ -n "$DEFAULT_GW" ]]; then
    local gw_out
    out+="$ ping -c 2 -W 1 ${DEFAULT_GW}"$'\n'
    gw_out="$(run_cmd 4 ping -c 2 -W 1 "$DEFAULT_GW" || true)"
    out+="$gw_out"$'\n\n'
    if printf '%s\n' "$gw_out" | grep -Eq '(bytes from|[1-9][0-9]* received)'; then
      GATEWAY_REACHABLE=1
    fi
  else
    out+="No default gateway detected."$'\n\n'
  fi

  if [[ "$MODE" == "full" ]]; then
    local bcast=""
    if has_cmd ip && [[ -n "$ROUTE_DEV" ]]; then
      bcast="$(ip -4 -o addr show dev "$ROUTE_DEV" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="brd") {print $(i+1); exit}}')"
    fi
    if [[ -n "$bcast" ]]; then
      out+="$ ping -b -c 1 -W 1 ${bcast}"$'\n'
      out+="$(run_cmd 4 ping -b -c 1 -W 1 "$bcast" || true)"$'\n\n'
    else
      out+="Broadcast ping skipped (no broadcast address for selected path)."$'\n\n'
    fi
  else
    out+="Broadcast ping skipped in quick mode (noise control)."$'\n\n'
  fi

  if has_cmd arping && [[ -n "$ROUTE_DEV" ]] && is_valid_ipv4 "$TARGET"; then
    out+="$ arping -c 2 -w 3 -I ${ROUTE_DEV} ${TARGET}"$'\n'
    local arping_out
    arping_out="$(run_cmd 6 arping -c 2 -w 3 -I "$ROUTE_DEV" "$TARGET" || true)"
    out+="$arping_out"$'\n\n'
    if printf '%s\n' "$arping_out" | grep -Eq '(Unicast reply from|bytes from)'; then
      ARPING_REACHABLE=1
    fi
  else
    out+="arping unavailable or target is not IPv4; skipping ARP ping."$'\n\n'
  fi

  if has_cmd tracepath; then
    out+="$ tracepath -n ${TARGET}"$'\n'
    out+="$(run_cmd 8 tracepath -n "$TARGET" || true)"$'\n\n'
  elif has_cmd mtr; then
    out+="$ mtr -n -r -c 3 -w ${TARGET}"$'\n'
    out+="$(run_cmd 8 mtr -n -r -c 3 -w "$TARGET" || true)"$'\n\n'
  else
    out+="tracepath/mtr not installed; skipping path trace."$'\n\n'
  fi

  if has_cmd curl; then
    out+="$ curl --max-time 3 -sS http://${TARGET} (connectivity sanity)"$'\n'
    out+="$(run_cmd 5 curl --max-time 3 -sS "http://${TARGET}" || true | head -n 5)"$'\n\n'
  else
    out+="curl not installed; skipping HTTP connectivity sanity."$'\n\n'
  fi

  SECTION_F="$out"

  print_hr "6) F) Ping Ladder"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_F"
}

section_g_firewall() {
  local out=""

  if [[ "$MODE" == "quick" ]]; then
    out+="Quick mode: firewall deep inspection skipped (use --full)."$'\n'
    SECTION_G="$out"
    print_hr "7) G) Firewall Summary"
    [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_G"
    return 0
  fi

  if has_cmd nft; then
    if [[ "$EUID" -eq 0 ]]; then
      out+="$ nft list ruleset"$'\n'
      local nft_out
      nft_out="$(run_cmd 8 nft list ruleset || true)"
      out+="$nft_out"$'\n\n'
      if printf '%s\n' "$nft_out" | grep -Eqi '(icmp|icmpv6).*(drop|reject)|(drop|reject).*(icmp|icmpv6)'; then
        add_issue "WARN" "nftables may block ICMP" "Firewall policy can block ping" "medium" "Temporary test rule example: sudo nft add rule inet filter input ip protocol icmp accept"
      fi
    else
      mark_needs_sudo "nft list ruleset"
      out+="nft list ruleset: needs sudo"$'\n\n'
    fi
  else
    out+="nft not installed"$'\n\n'
  fi

  if has_cmd iptables; then
    out+="$ iptables -S"$'\n'
    local ipt_out
    ipt_out="$(run_cmd 6 iptables -S || true)"
    out+="$ipt_out"$'\n\n'
    if printf '%s\n' "$ipt_out" | grep -Eqi '(icmp.*(DROP|REJECT)|(DROP|REJECT).*-p icmp)'; then
      add_issue "WARN" "iptables may block ICMP" "Legacy firewall policy can block ping" "medium" "Temporary test rule: sudo iptables -I INPUT -p icmp -j ACCEPT"
    fi
  else
    out+="iptables not installed"$'\n\n'
  fi

  if has_cmd ufw; then
    out+="$ ufw status"$'\n'
    out+="$(run_cmd 4 ufw status || true)"$'\n\n'
  else
    out+="ufw not installed"$'\n\n'
  fi

  if has_cmd firewall-cmd; then
    out+="$ firewall-cmd --state"$'\n'
    out+="$(run_cmd 4 firewall-cmd --state || true)"$'\n\n'
  else
    out+="firewalld not installed"$'\n\n'
  fi

  SECTION_G="$out"

  print_hr "7) G) Firewall Summary"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_G"
}

section_h_usb_and_kernel() {
  local out=""

  if has_cmd lsusb; then
    out+="$ lsusb"$'\n'
    local lsusb_out
    lsusb_out="$(run_cmd 5 lsusb || true)"
    out+="$lsusb_out"$'\n\n'
    if printf '%s\n' "$lsusb_out" | grep -Eqi '(RNDIS|CDC|Ethernet|Gadget|Linux Foundation)'; then
      USB_ENUM_FOUND=1
    fi
  else
    out+="lsusb not installed"$'\n\n'
  fi

  local dmesg_out=""
  if [[ "$EUID" -eq 0 ]]; then
    dmesg_out="$(run_cmd 6 dmesg --since '30 minutes ago' || true)"
    if [[ -z "$dmesg_out" ]]; then
      dmesg_out="$(run_cmd 6 dmesg | tail -n 250 || true)"
    fi
  else
    dmesg_out="$(run_cmd 6 dmesg --since '30 minutes ago' || true)"
    if printf '%s\n' "$dmesg_out" | grep -qi 'Operation not permitted'; then
      mark_needs_sudo "dmesg --since '30 minutes ago'"
      dmesg_out="needs sudo"
    fi
  fi

  out+="usb-related dmesg lines:"$'\n'
  out+="$(printf '%s\n' "$dmesg_out" | grep -Ei 'usb|cdc|rndis|gadget|g_ether|dwc2|libcomposite' | tail -n 80 || true)"$'\n\n'

  if has_cmd lsmod; then
    out+="$ lsmod | egrep 'g_ether|dwc2|libcomposite|rndis_host|cdc_ether'"$'\n'
    out+="$(run_cmd 4 lsmod | grep -E 'g_ether|dwc2|libcomposite|rndis_host|cdc_ether' || true)"$'\n\n'
  fi

  if [[ -r /proc/cmdline ]]; then
    out+="/proc/cmdline:"$'\n'
    out+="$(cat /proc/cmdline 2>/dev/null)"$'\n\n'
  fi

  if [[ "$USB_ENUM_FOUND" -eq 0 ]]; then
    local any_usb_iface=0
    local iface
    for iface in "${IFACES[@]}"; do
      if [[ "${IF_USB_HINT[$iface]:-no}" == "yes" ]]; then
        any_usb_iface=1
        break
      fi
    done
    if [[ "$any_usb_iface" -eq 0 ]]; then
      add_issue "WARN" "No clear USB Ethernet enumeration found" "Pi gadget may not be enumerating" "high" "Check USB data cable, OTG port/mode, and Pi boot options (dtoverlay=dwc2, modules-load=dwc2,g_ether)."
      add_next_action "On Pi, verify /boot cmdline/config for dwc2 and g_ether"
    fi
  fi

  SECTION_H="$out"

  print_hr "8) H) USB Enumeration + Kernel Modules"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_H"
}

section_i_nm_deep() {
  local out=""

  if ! has_cmd nmcli; then
    out="nmcli missing; skipping NetworkManager deep dive."
    SECTION_I="$out"
    print_hr "9) I) NetworkManager Deep Dive"
    [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_I"
    return 0
  fi

  out+="$ nmcli general status"$'\n'
  out+="$(run_cmd 4 nmcli general status || true)"$'\n\n'

  local iface
  for iface in "${IFACES[@]}"; do
    out+="$ nmcli -f GENERAL.STATE,GENERAL.REASON,IP4.ADDRESS,IP6.ADDRESS dev show ${iface}"$'\n'
    out+="$(run_cmd 5 nmcli -f GENERAL.STATE,GENERAL.REASON,IP4.ADDRESS,IP6.ADDRESS dev show "$iface" || true)"$'\n\n'

    out+="$ nmcli -t -f NAME,UUID,TYPE,DEVICE con show"$'\n'
    out+="$(run_cmd 5 nmcli -t -f NAME,UUID,TYPE,DEVICE con show | awk -F: -v d="$iface" '$4==d || $4=="--" {print}' || true)"$'\n\n'

    if has_cmd udevadm; then
      local up
      up="$(run_cmd 4 udevadm info --query=property --name "$iface" || true)"
      if printf '%s\n' "$up" | grep -q 'NM_UNMANAGED=1'; then
        add_issue "WARN" "udev marks $iface as NM_UNMANAGED=1" "Udev policy prevents NetworkManager management" "high" "Adjust udev rule to remove NM_UNMANAGED and reload rules, then restart NetworkManager."
      fi
    fi
  done

  if [[ "$MODE" == "full" ]]; then
    out+="$ grep -R NM_UNMANAGED /etc/udev/rules.d /usr/lib/udev/rules.d"$'\n'
    out+="$(run_cmd 5 grep -R NM_UNMANAGED /etc/udev/rules.d /usr/lib/udev/rules.d || true)"$'\n\n'
  fi

  SECTION_I="$out"

  print_hr "9) I) NetworkManager Deep Dive"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_I"
}

section_j_recommend() {
  local out=""
  local count="${#ISSUE_MSG[@]}"

  out+="Most Likely Causes:"$'\n'
  if [[ "$count" -eq 0 ]]; then
    out+="  - No high-confidence blockers detected."$'\n'
  else
    local i
    for ((i=0; i<count && i<5; i++)); do
      out+="  - (${ISSUE_CONF[$i]}) ${ISSUE_CAUSE[$i]}"$'\n'
    done
  fi

  out+=$'\n'
  out+="Fix Steps (not applied automatically):"$'\n'
  if [[ "$count" -eq 0 ]]; then
    out+="  - Re-run with --full --verbose for deeper diagnostics."$'\n'
  else
    local i
    for ((i=0; i<count && i<5; i++)); do
      out+="  - ${ISSUE_FIX[$i]}"$'\n'
    done
  fi

  SECTION_J="$out"

  print_hr "10) J) Recommendations Engine"
  [[ "$JSON_MODE" -eq 0 ]] && printf '%s\n' "$SECTION_J"
}

build_summary() {
  local verdict="OK"
  local has_warn=0
  local has_fail=0
  local i

  for ((i=0; i<${#ISSUE_SEV[@]}; i++)); do
    if [[ "${ISSUE_SEV[$i]}" == "FAIL" ]]; then
      has_fail=1
    elif [[ "${ISSUE_SEV[$i]}" == "WARN" ]]; then
      has_warn=1
    fi
  done

  if [[ "$has_fail" -eq 1 ]]; then
    verdict="FAIL"
  elif [[ "$has_warn" -eq 1 ]]; then
    verdict="WARN"
  fi

  if [[ "$TARGET_REACHABLE" -eq 1 ]]; then
    add_next_action "Target responds to ICMP now; validate stability with repeated pings."
  else
    add_next_action "If using Pi Zero gadget mode, verify Pi side is 10.0.0.2/24 and host usb0 is 10.0.0.1/24."
  fi

  if [[ -n "$ROUTE_DEV" && "$ROUTE_DEV" != "usb0" && "$TARGET" == 10.0.0.* ]]; then
    add_issue "WARN" "Traffic to $TARGET does not route via usb0" "Wrong interface selected for gadget subnet" "high" "Route fix: ip route add 10.0.0.0/24 dev usb0"
  fi

  local top_issues=""
  for ((i=0; i<${#ISSUE_MSG[@]} && i<3; i++)); do
    top_issues+="- ${ISSUE_MSG[$i]}"$'\n'
  done
  if [[ -z "$top_issues" ]]; then
    top_issues="- No blocking issues detected"$'\n'
  fi

  local next_steps=""
  for ((i=0; i<${#NEXT_ACTIONS[@]} && i<3; i++)); do
    next_steps+="- ${NEXT_ACTIONS[$i]}"$'\n'
  done
  if [[ -z "$next_steps" ]]; then
    next_steps="- Re-run with --full --verbose if the issue persists"$'\n'
  fi

  if [[ "${#NEEDS_SUDO_ITEMS[@]}" -gt 0 ]]; then
    add_next_action "Run full privileged checks: netdiag --full"
  fi

  local elapsed=$(( $(date +%s) - START_EPOCH ))
  SUMMARY_TEXT=$(cat <<EOF_SUM
verdict: $verdict
elapsed_seconds: $elapsed

Top issues:
$top_issues
Next actions:
$next_steps
EOF_SUM
)

  if [[ "$JSON_MODE" -eq 0 ]]; then
    print_hr "Final Verdict"
    printf '%s\n' "$SUMMARY_TEXT"
    if [[ "${#NEEDS_SUDO_ITEMS[@]}" -gt 0 ]]; then
      printf 'Needs sudo items:\n'
      local item
      for item in "${NEEDS_SUDO_ITEMS[@]}"; do
        printf '  - %s\n' "$item"
      done
    fi
  fi

  VERDICT_RESULT="$verdict"
}

maybe_prompt_bundle() {
  [[ -n "$SUPPORT_BUNDLE_ARG" ]] && return 0
  [[ "$JSON_MODE" -eq 1 ]] && return 0
  [[ ! -t 0 ]] && return 0

  local ans
  printf 'Create support bundle now? [y/N]: ' >&2
  read -r ans
  if [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    local dir
    printf 'Bundle directory [./netdiag-support]: ' >&2
    read -r dir
    [[ -z "$dir" ]] && dir="./netdiag-support"
    SUPPORT_BUNDLE_ARG="$dir"
  fi
}

write_support_bundle() {
  [[ -z "$SUPPORT_BUNDLE_ARG" ]] && return 0

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -d "$SUPPORT_BUNDLE_ARG" || "$SUPPORT_BUNDLE_ARG" == */ ]]; then
    SUPPORT_DIR="${SUPPORT_BUNDLE_ARG%/}/netdiag-${ts}"
  else
    SUPPORT_DIR="${SUPPORT_BUNDLE_ARG%/}-netdiag-${ts}"
  fi

  mkdir -p "$SUPPORT_DIR"

  printf '%s\n' "$SECTION_A" | redact_stream > "$SUPPORT_DIR/section-A-system.txt"
  printf '%s\n' "$SECTION_B" | redact_stream > "$SUPPORT_DIR/section-B-inventory.txt"
  printf '%s\n' "$SECTION_C" | redact_stream > "$SUPPORT_DIR/section-C-iface.txt"
  printf '%s\n' "$SECTION_D" | redact_stream > "$SUPPORT_DIR/section-D-route.txt"
  printf '%s\n' "$SECTION_E" | redact_stream > "$SUPPORT_DIR/section-E-neigh.txt"
  printf '%s\n' "$SECTION_F" | redact_stream > "$SUPPORT_DIR/section-F-ping.txt"
  printf '%s\n' "$SECTION_G" | redact_stream > "$SUPPORT_DIR/section-G-firewall.txt"
  printf '%s\n' "$SECTION_H" | redact_stream > "$SUPPORT_DIR/section-H-usb-kernel.txt"
  printf '%s\n' "$SECTION_I" | redact_stream > "$SUPPORT_DIR/section-I-nm.txt"
  printf '%s\n' "$SECTION_J" | redact_stream > "$SUPPORT_DIR/section-J-recommendations.txt"
  printf '%s\n' "$SUMMARY_TEXT" | redact_stream > "$SUPPORT_DIR/summary.txt"

  redact_stream < "$CMD_LOG_FILE" > "$SUPPORT_DIR/commands.log"

  if [[ -n "$REPORT_FILE" && -f "$REPORT_FILE" ]]; then
    redact_stream < "$REPORT_FILE" > "$SUPPORT_DIR/report-redacted.txt"
  fi

  [[ "$JSON_MODE" -eq 0 ]] && print_note "Support bundle: $SUPPORT_DIR"
}

emit_json() {
  local i
  printf '{\n'
  printf '  "tool": "netdiag",\n'
  printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
  printf '  "mode": "%s",\n' "$(json_escape "$MODE")"
  printf '  "timestamp": "%s",\n' "$(json_escape "$START_TS")"
  printf '  "target": "%s",\n' "$(json_escape "$TARGET")"
  printf '  "route": {"dev": "%s", "src": "%s"},\n' "$(json_escape "$ROUTE_DEV")" "$(json_escape "$ROUTE_SRC")"
  printf '  "interfaces": ['
  for ((i=0; i<${#IFACES[@]}; i++)); do
    local iface="${IFACES[$i]}"
    [[ "$i" -gt 0 ]] && printf ', '
    printf '{"name":"%s","state":"%s","carrier":"%s","driver":"%s","usb_hint":"%s","ipv4":"%s","ipv6":"%s","nm_state":"%s"}' \
      "$(json_escape "$iface")" \
      "$(json_escape "${IF_STATE[$iface]:-unknown}")" \
      "$(json_escape "${IF_CARRIER[$iface]:-n/a}")" \
      "$(json_escape "${IF_DRIVER[$iface]:-unknown}")" \
      "$(json_escape "${IF_USB_HINT[$iface]:-no}")" \
      "$(json_escape "${IF_ADDR4[$iface]:-}")" \
      "$(json_escape "${IF_ADDR6[$iface]:-}")" \
      "$(json_escape "${IF_NM_STATE[$iface]:-unknown}")"
  done
  printf '],\n'

  printf '  "checks": {'
  printf '"target_reachable": %s, "gateway_reachable": %s, "arping_reachable": %s, "usb_enumeration_hint": %s, "commands_executed": %d' \
    "$([[ "$TARGET_REACHABLE" -eq 1 ]] && echo true || echo false)" \
    "$([[ "$GATEWAY_REACHABLE" -eq 1 ]] && echo true || echo false)" \
    "$([[ "$ARPING_REACHABLE" -eq 1 ]] && echo true || echo false)" \
    "$([[ "$USB_ENUM_FOUND" -eq 1 ]] && echo true || echo false)" \
    "$CMD_COUNT"
  printf '},\n'

  printf '  "issues": ['
  for ((i=0; i<${#ISSUE_MSG[@]}; i++)); do
    [[ "$i" -gt 0 ]] && printf ', '
    printf '{"severity":"%s","message":"%s","cause":"%s","confidence":"%s","fix":"%s"}' \
      "$(json_escape "${ISSUE_SEV[$i]}")" \
      "$(json_escape "${ISSUE_MSG[$i]}")" \
      "$(json_escape "${ISSUE_CAUSE[$i]}")" \
      "$(json_escape "${ISSUE_CONF[$i]}")" \
      "$(json_escape "${ISSUE_FIX[$i]}")"
  done
  printf '],\n'

  printf '  "needs_sudo": ['
  for ((i=0; i<${#NEEDS_SUDO_ITEMS[@]}; i++)); do
    [[ "$i" -gt 0 ]] && printf ', '
    printf '"%s"' "$(json_escape "${NEEDS_SUDO_ITEMS[$i]}")"
  done
  printf '],\n'

  printf '  "verdict": {"status": "%s", "summary": "%s", "next_actions": [' \
    "$(json_escape "$VERDICT_RESULT")" "$(json_escape "$(printf '%s' "$SUMMARY_TEXT" | head -n1)")"
  for ((i=0; i<${#NEXT_ACTIONS[@]} && i<3; i++)); do
    [[ "$i" -gt 0 ]] && printf ', '
    printf '"%s"' "$(json_escape "${NEXT_ACTIONS[$i]}")"
  done
  printf ']}'

  if [[ -n "$SUPPORT_DIR" ]]; then
    printf ',\n  "support_bundle": "%s"\n' "$(json_escape "$SUPPORT_DIR")"
  else
    printf '\n'
  fi
  printf '}\n'
}

main() {
  parse_args "$@"

  if [[ -n "$TARGET_ARG" ]] && ! is_valid_target "$TARGET_ARG"; then
    echo "$PROG: invalid --target value: $TARGET_ARG" >&2
    exit 2
  fi

  prompt_target
  detect_interfaces

  maybe_reexec_sudo
  init_report

  section_a_system_info
  section_b_inventory
  section_c_focus_iface
  section_d_route_target
  section_e_neighbor
  section_f_ping_ladder
  section_g_firewall
  section_h_usb_and_kernel
  section_i_nm_deep
  section_j_recommend
  build_summary

  maybe_prompt_bundle
  write_support_bundle

  if [[ "$JSON_MODE" -eq 1 ]]; then
    emit_json
  fi

  return 0
}

main "$@"
