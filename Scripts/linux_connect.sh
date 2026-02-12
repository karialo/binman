#!/usr/bin/env bash
# linux_connect.sh  —  plug · detect · connect · persist
VERSION="0.1.0"

# -----------------------------------------------------------------------------
# linux_connect.sh  —  plug · detect · connect · persist
#
# by jayofelony + K.A.R.I (Knowledgeable Autonomous Reactive Interface)
# -----------------------------------------------------------------------------
# Purpose:
#   Automatically set up Ethernet-over-USB networking to a Raspberry Pi
#   (e.g., Pwnagotchi or Kali Pi Zero gadget mode).
# -----------------------------------------------------------------------------
# Features:
#   ✅ Detect USB gadget NIC automatically (no guessing enx* names)
#   ✅ Configure host as 10.0.0.1/24 and NAT traffic to Internet
#   ✅ Support both nftables and iptables (auto-detect or force)
#   ✅ Auto-detect Pi peer IP on gadget link, then verify stable ping
#   ✅ --persist installs systemd unit + timer to reconnect at boot
#   ✅ --install and --uninstall manage itself
# -----------------------------------------------------------------------------

set -euo pipefail

# ----- ssh defaults -----
SSH_USER="${SSH_USER:-pi}"
# default to the invoking user's home, not root's
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SSH_IDENTITY="${SSH_IDENTITY:-$TARGET_HOME/.ssh/id_ed25519}"   # or override to ~/.ssh/id_rsa

# ----- default config -----
PI_IP_DEFAULT=""                      # auto-discover by default
HOST_IP_CIDR_DEFAULT="10.0.0.1/24"
DISCOVERED_PI_IP=""

# ----- timing parameters (can tweak via env) -----
REQUIRED_PINGS="${REQUIRED_PINGS:-3}"          # how many consecutive pings = "stable"
PING_TIMEOUT="${PING_TIMEOUT:-1}"              # seconds per ping
RETRY_SLEEP="${RETRY_SLEEP:-3}"                # delay between ping attempts
MAX_TRIES="${MAX_TRIES:-8}"                    # max tries per iface

# ----- logging helpers -----
say()  { echo ">>> [K.A.R.I] $*"; }
warn() { echo "!!! [K.A.R.I] $*" >&2; }
die()  { echo "xxx [K.A.R.I] $*" >&2; exit 1; }

# ----- global paths -----
SELF_PATH="$(readlink -f "$0")"
INSTALL_PATH="/usr/local/sbin/linux_connect.sh"
UNIT_PATH="/etc/systemd/system/linux-connect.service"
TIMER_PATH="/etc/systemd/system/linux-connect.timer"

# ----- help text -----
show_help() {
cat <<EOF
Usage:
  sudo linux_connect.sh [PI_IP] [HOST_IP/CIDR] [--persist]
  sudo linux_connect.sh --install       Install script to $INSTALL_PATH
  sudo linux_connect.sh --uninstall     Remove systemd unit + script
  sudo linux_connect.sh --persist       Install systemd auto-reconnect timer
  sudo linux_connect.sh --iface=name    Hint USB interface to try first
  sudo linux_connect.sh --upstream=dev  Force upstream interface

Examples:
  sudo linux_connect.sh
  sudo PI_IP=10.0.0.2 linux_connect.sh
  sudo HOST_IP_CIDR=10.42.0.1/24 linux_connect.sh
  sudo linux_connect.sh 10.42.0.2 10.42.0.1/24
  sudo linux_connect.sh --persist
EOF
}

# -----------------------------------------------------------------------------
# Utility: detect nft/iptables backend
# -----------------------------------------------------------------------------
detect_firewall_backend() {
  if [[ "${FORCE_NFT:-0}" == "1" ]]; then echo nft; return; fi
  if [[ "${FORCE_IPTABLES:-0}" == "1" ]]; then echo iptables; return; fi
  if command -v nft &>/dev/null && nft list ruleset &>/dev/null; then
    echo nft
  else
    echo iptables
  fi
}

# -----------------------------------------------------------------------------
# Utility: Check for SSH access
# -----------------------------------------------------------------------------
ensure_ssh_key_access() {
  local pi_ip="$1"

  # 1) ensure the user has a key
  if ! sudo -u "$TARGET_USER" -H test -r "${SSH_IDENTITY}"; then
    say "No SSH key found for $TARGET_USER — generating ${SSH_IDENTITY} (ed25519)"
    sudo -u "$TARGET_USER" -H mkdir -p "$(dirname "$SSH_IDENTITY")"
    sudo -u "$TARGET_USER" -H ssh-keygen -t ed25519 -N '' -f "$SSH_IDENTITY"
  fi

  # 2) quick check: does key auth already work?
  if sudo -u "$TARGET_USER" -H ssh \
      -i "$SSH_IDENTITY" \
      -o BatchMode=yes \
      -o PasswordAuthentication=no \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=3 \
      "${SSH_USER}@${pi_ip}" true >/dev/null 2>&1; then
    say "SSH key auth already works for ${SSH_USER}@${pi_ip} — skipping copy."
    return 0
  fi

  # 3) offer to copy key
  echo -n ">>> [K.A.R.I] No key auth yet for ${SSH_USER}@${pi_ip}. Copy your public key now? [Y/n] "
  read -r ans
  if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
    say "Copying key (${SSH_IDENTITY}.pub) to ${SSH_USER}@${pi_ip}"
    if sudo -u "$TARGET_USER" -H ssh-copy-id \
         -i "${SSH_IDENTITY}.pub" \
         -o StrictHostKeyChecking=accept-new \
         "${SSH_USER}@${pi_ip}"; then
      say "Key installed. Future connects should be passwordless. 🎉"
    else
      warn "ssh-copy-id failed (maybe wrong password?). You can retry later with: ssh-copy-id -i ${SSH_IDENTITY}.pub ${SSH_USER}@${pi_ip}"
    fi
  else
    warn "Skipped key copy. You’ll be prompted for a password."
  fi
}

# -----------------------------------------------------------------------------
# Utility: open SSH inline (single session, same terminal)
# -----------------------------------------------------------------------------
open_ssh_inline() {
  local pi_ip="$1"
  if [[ "$TARGET_USER" != "$(id -un)" ]]; then
    # run ssh as the invoking desktop user
    exec sudo -u "$TARGET_USER" -H ssh -i "$SSH_IDENTITY" "${SSH_USER}@${pi_ip}"
  else
    exec ssh -i "$SSH_IDENTITY" "${SSH_USER}@${pi_ip}"
  fi
}

# -----------------------------------------------------------------------------
# Utility: find upstream interface (default route)
# -----------------------------------------------------------------------------
detect_upstream() {
  if [[ -n "${HINT_UPSTREAM:-}" ]]; then echo "$HINT_UPSTREAM"; return; fi
  local dev
  dev=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$dev" ]] && echo "$dev" && return
  ip route | awk '/^default/ {print $5; exit}'
}

# -----------------------------------------------------------------------------
# Utility: list candidate USB gadget NICs
# -----------------------------------------------------------------------------
find_usb_nics() {
  [[ -n "${HINT_IFACE:-}" && -e "/sys/class/net/$HINT_IFACE" ]] && echo "$HINT_IFACE"
  for i in /sys/class/net/*; do
    local name="$(basename "$i")"
    [[ "$name" == "lo" ]] && continue
    [[ "$(cat "$i/type")" != "1" ]] && continue   # only ARPHRD_ETHER
    if readlink -f "$i/device" | grep -q '/usb'; then
      echo "$name"
    elif [[ "$name" =~ ^enx || "$name" =~ ^enp.*u ]]; then
      echo "$name"
    fi
  done
}

# -----------------------------------------------------------------------------
# Configure IP + bring link up
# -----------------------------------------------------------------------------
configure_usb_iface() {
  local ifc="$1" host_ip_cidr="$2"
  local host_ip prefix addr
  host_ip="${host_ip_cidr%%/*}"
  prefix="${host_ip%.*}"
  say "Configuring $ifc as $host_ip_cidr"
  ip link set "$ifc" up || return 1
  while read -r addr; do
    ip addr del "$addr" dev "$ifc" 2>/dev/null || true
  done < <(ip -o -4 addr show dev "$ifc" | awk -v pfx="$prefix" '$4 ~ ("^" pfx "\\.") {print $4}')
  ip addr add "$host_ip_cidr" dev "$ifc" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Utility: host/peer IP helpers
# -----------------------------------------------------------------------------
host_ip_from_cidr() {
  local host_cidr="$1"
  echo "${host_cidr%%/*}"
}

is_valid_ipv4() {
  local ip="$1" oct o1 o2 o3 o4
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip" || return 1
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$oct" =~ ^[0-9]+$ ]] || return 1
    (( oct >= 0 && oct <= 255 )) || return 1
  done
  return 0
}

discover_pi_ip() {
  local ifc="$1" host_cidr="$2"
  local host_ip host_prefix host_mask candidate prefix label value net o1 o2 o3 o4
  local max_prefixes max_scan_pings ping_attempts
  local quick_hosts host i ip host_octet hop_host_ip hop_cidr addr
  local did_prefix_hop=0
  local -a neigh_ip_candidates=() route_ip_candidates=()
  local -a neigh_prefix_candidates=() route_prefix_candidates=()
  local -a scan_prefixes=()
  local -a original_addrs=()
  local -A seen_neigh_ip=() seen_route_ip=()
  local -A seen_neigh_prefix=() seen_route_prefix=()
  local -A seen_scan_prefix=() tried_ip=()

  DISCOVERED_PI_IP=""
  host_ip="$(host_ip_from_cidr "$host_cidr")"
  is_valid_ipv4 "$host_ip" || return 1
  host_prefix="${host_ip%.*}"
  host_mask="${host_cidr#*/}"
  [[ "$host_mask" == "$host_cidr" ]] && host_mask="24"
  if ! [[ "$host_mask" =~ ^[0-9]+$ ]] || (( host_mask < 1 || host_mask > 32 )); then
    host_mask="24"
  fi

  max_prefixes="${DISCOVERY_MAX_PREFIXES:-8}"
  max_scan_pings="${DISCOVERY_MAX_PINGS:-220}"
  ping_attempts=0
  quick_hosts="2 3 4 5 10 20 30 40 42 50 60 70 75 80 90 100 110 120 130 140 150 160 170 180 190 200 210 220 230 240 250 254"

  # Stage A: neighbor table first (non-failed, non-incomplete)
  while read -r candidate; do
    is_valid_ipv4 "$candidate" || continue
    [[ "$candidate" =~ ^10\. ]] || continue
    [[ "$candidate" == "10.0.0.1" ]] && continue
    [[ "$candidate" == "$host_ip" ]] && continue
    [[ -n "${seen_neigh_ip[$candidate]+x}" ]] && continue
    seen_neigh_ip["$candidate"]=1
    neigh_ip_candidates+=("$candidate")
  done < <(ip -4 neigh show dev "$ifc" | awk '$0 !~ /(FAILED|INCOMPLETE)/ {print $1}')

  # Keep neighbor-derived /24 prefixes as bounded scan hints.
  while read -r candidate; do
    is_valid_ipv4 "$candidate" || continue
    [[ "$candidate" =~ ^10\. ]] || continue
    [[ "$candidate" == "10.0.0.1" ]] && continue
    [[ "$candidate" == "$host_ip" ]] && continue
    prefix="${candidate%.*}"
    [[ "$prefix" =~ ^10\.[0-9]+\.[0-9]+$ ]] || continue
    [[ -n "${seen_neigh_prefix[$prefix]+x}" ]] && continue
    seen_neigh_prefix["$prefix"]=1
    neigh_prefix_candidates+=("$prefix")
  done < <(ip -4 neigh show dev "$ifc" | awk '$0 !~ /(FAILED|INCOMPLETE)/ {print $1}')

  for candidate in "${neigh_ip_candidates[@]}"; do
    (( ping_attempts >= max_scan_pings )) && break
    [[ -n "${tried_ip[$candidate]+x}" ]] && continue
    tried_ip["$candidate"]=1
    ((ping_attempts++))
    if ping -c1 -W1 -I "$ifc" "$candidate" >/dev/null 2>&1; then
      DISCOVERED_PI_IP="$candidate"
      say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from neighbor/route discovery)"
      return 0
    fi
  done

  # Stage B: route-derived hints (prefer scope link first).
  while read -r label value; do
    case "$label" in
      IP)
        is_valid_ipv4 "$value" || continue
        [[ "$value" =~ ^10\. ]] || continue
        [[ "$value" == "10.0.0.1" ]] && continue
        [[ "$value" == "$host_ip" ]] && continue
        [[ -n "${seen_neigh_ip[$value]+x}" ]] && continue
        [[ -n "${seen_route_ip[$value]+x}" ]] && continue
        seen_route_ip["$value"]=1
        route_ip_candidates+=("$value")
        ;;
      PREFIX)
        net="${value%/*}"
        is_valid_ipv4 "$net" || continue
        [[ "$net" =~ ^10\. ]] || continue
        prefix="${net%.*}"
        [[ "$prefix" =~ ^10\.[0-9]+\.[0-9]+$ ]] || continue
        [[ -n "${seen_route_prefix[$prefix]+x}" ]] && continue
        seen_route_prefix["$prefix"]=1
        route_prefix_candidates+=("$prefix")
        ;;
    esac
  done < <(
    ip -4 route show dev "$ifc" | awk '
      $0 ~ /scope link/ {
        if ($1 ~ /^10\./) {
          print "PREFIX " $1
          if ($1 ~ /^10\.[0-9]+\.[0-9]+\.[0-9]+$/) print "IP " $1
        }
        for (i = 1; i <= NF; i++) {
          if (($i == "via" || $i == "src") && (i + 1) <= NF && $(i + 1) ~ /^10\./) print "IP " $(i + 1)
        }
      }
    '
  )

  while read -r label value; do
    case "$label" in
      IP)
        is_valid_ipv4 "$value" || continue
        [[ "$value" =~ ^10\. ]] || continue
        [[ "$value" == "10.0.0.1" ]] && continue
        [[ "$value" == "$host_ip" ]] && continue
        [[ -n "${seen_neigh_ip[$value]+x}" ]] && continue
        [[ -n "${seen_route_ip[$value]+x}" ]] && continue
        seen_route_ip["$value"]=1
        route_ip_candidates+=("$value")
        ;;
      PREFIX)
        net="${value%/*}"
        is_valid_ipv4 "$net" || continue
        [[ "$net" =~ ^10\. ]] || continue
        prefix="${net%.*}"
        [[ "$prefix" =~ ^10\.[0-9]+\.[0-9]+$ ]] || continue
        [[ -n "${seen_route_prefix[$prefix]+x}" ]] && continue
        seen_route_prefix["$prefix"]=1
        route_prefix_candidates+=("$prefix")
        ;;
    esac
  done < <(
    ip -4 route show dev "$ifc" | awk '
      $0 !~ /scope link/ {
        if ($1 ~ /^10\./) {
          print "PREFIX " $1
          if ($1 ~ /^10\.[0-9]+\.[0-9]+\.[0-9]+$/) print "IP " $1
        }
        for (i = 1; i <= NF; i++) {
          if (($i == "via" || $i == "src") && (i + 1) <= NF && $(i + 1) ~ /^10\./) print "IP " $(i + 1)
        }
      }
    '
  )

  for candidate in "${route_ip_candidates[@]}"; do
    (( ping_attempts >= max_scan_pings )) && break
    [[ -n "${tried_ip[$candidate]+x}" ]] && continue
    tried_ip["$candidate"]=1
    ((ping_attempts++))
    if ping -c1 -W1 -I "$ifc" "$candidate" >/dev/null 2>&1; then
      DISCOVERED_PI_IP="$candidate"
      say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from neighbor/route discovery)"
      return 0
    fi
  done

  IFS='.' read -r o1 o2 o3 o4 <<< "$host_ip"
  [[ -n "$o1" && -n "$o2" && -n "$o3" && -n "$o4" ]] || return 1

  # Stage C: bounded fallback scan over a small, deduped /24 list.
  if [[ "$host_ip" =~ ^10\. ]] && (( ${#scan_prefixes[@]} < max_prefixes )); then
    seen_scan_prefix["$host_prefix"]=1
    scan_prefixes+=("$host_prefix")
  fi

  for prefix in "${neigh_prefix_candidates[@]}"; do
    (( ${#scan_prefixes[@]} >= max_prefixes )) && break
    [[ -n "${seen_scan_prefix[$prefix]+x}" ]] && continue
    seen_scan_prefix["$prefix"]=1
    scan_prefixes+=("$prefix")
  done
  for prefix in "${route_prefix_candidates[@]}"; do
    (( ${#scan_prefixes[@]} >= max_prefixes )) && break
    [[ -n "${seen_scan_prefix[$prefix]+x}" ]] && continue
    seen_scan_prefix["$prefix"]=1
    scan_prefixes+=("$prefix")
  done

  for prefix in "${scan_prefixes[@]}"; do
    ping -c1 -W1 -I "$ifc" "${prefix}.255" >/dev/null 2>&1 || true
  done

  for prefix in "${scan_prefixes[@]}"; do
    for host in $quick_hosts; do
      (( ping_attempts >= max_scan_pings )) && break 2
      ip="${prefix}.${host}"
      [[ "$ip" == "10.0.0.1" ]] && continue
      [[ "$ip" == "$host_ip" ]] && continue
      [[ -n "${tried_ip[$ip]+x}" ]] && continue
      tried_ip["$ip"]=1
      ((ping_attempts++))
      if ping -c1 -W1 -I "$ifc" "$ip" >/dev/null 2>&1; then
        DISCOVERED_PI_IP="$ip"
        say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from bounded 10.* scan)"
        return 0
      fi
    done
  done

  for prefix in "${scan_prefixes[@]}"; do
    for ((i=2; i<=254; i++)); do
      (( ping_attempts >= max_scan_pings )) && break 2
      ip="${prefix}.${i}"
      [[ "$ip" == "10.0.0.1" ]] && continue
      [[ "$ip" == "$host_ip" ]] && continue
      [[ -n "${tried_ip[$ip]+x}" ]] && continue
      tried_ip["$ip"]=1
      ((ping_attempts++))
      if ping -c1 -W1 -I "$ifc" "$ip" >/dev/null 2>&1; then
        DISCOVERED_PI_IP="$ip"
        say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from bounded 10.* scan)"
        return 0
      fi
    done
  done

  # Optional bounded prefix-hop fallback for peers on a different 10.* /24.
  if [[ -z "${PI_IP:-}" && ${#scan_prefixes[@]} -gt 0 ]]; then
    mapfile -t original_addrs < <(ip -o -4 addr show dev "$ifc" | awk '{print $4}')
    host_octet="$o4"
    tried_ip=()
    for prefix in "${scan_prefixes[@]}"; do
      (( ping_attempts >= max_scan_pings )) && break
      hop_host_ip="${prefix}.${host_octet}"
      hop_cidr="${hop_host_ip}/${host_mask}"

      while read -r addr; do
        ip addr del "$addr" dev "$ifc" 2>/dev/null || true
      done < <(ip -o -4 addr show dev "$ifc" | awk '{print $4}')
      ip addr add "$hop_cidr" dev "$ifc" 2>/dev/null || true
      did_prefix_hop=1

      ping -c1 -W1 -I "$ifc" "${prefix}.255" >/dev/null 2>&1 || true

      for host in $quick_hosts; do
        (( ping_attempts >= max_scan_pings )) && break 2
        ip="${prefix}.${host}"
        [[ "$ip" == "10.0.0.1" ]] && continue
        [[ "$ip" == "$hop_host_ip" ]] && continue
        [[ -n "${tried_ip[$ip]+x}" ]] && continue
        tried_ip["$ip"]=1
        ((ping_attempts++))
        if ping -c1 -W1 -I "$ifc" "$ip" >/dev/null 2>&1; then
          while read -r addr; do
            ip addr del "$addr" dev "$ifc" 2>/dev/null || true
          done < <(ip -o -4 addr show dev "$ifc" | awk '{print $4}')
          if (( ${#original_addrs[@]} > 0 )); then
            for addr in "${original_addrs[@]}"; do
              ip addr add "$addr" dev "$ifc" 2>/dev/null || true
            done
          else
            ip addr add "$host_cidr" dev "$ifc" 2>/dev/null || true
          fi
          DISCOVERED_PI_IP="$ip"
          say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from bounded 10.* scan)"
          return 0
        fi
      done

      for ((i=2; i<=254; i++)); do
        (( ping_attempts >= max_scan_pings )) && break 2
        ip="${prefix}.${i}"
        [[ "$ip" == "10.0.0.1" ]] && continue
        [[ "$ip" == "$hop_host_ip" ]] && continue
        [[ -n "${tried_ip[$ip]+x}" ]] && continue
        tried_ip["$ip"]=1
        ((ping_attempts++))
        if ping -c1 -W1 -I "$ifc" "$ip" >/dev/null 2>&1; then
          while read -r addr; do
            ip addr del "$addr" dev "$ifc" 2>/dev/null || true
          done < <(ip -o -4 addr show dev "$ifc" | awk '{print $4}')
          if (( ${#original_addrs[@]} > 0 )); then
            for addr in "${original_addrs[@]}"; do
              ip addr add "$addr" dev "$ifc" 2>/dev/null || true
            done
          else
            ip addr add "$host_cidr" dev "$ifc" 2>/dev/null || true
          fi
          DISCOVERED_PI_IP="$ip"
          say "Detected Pi peer on $ifc: $DISCOVERED_PI_IP (from bounded 10.* scan)"
          return 0
        fi
      done
    done
  fi

  if (( did_prefix_hop )); then
    while read -r addr; do
      ip addr del "$addr" dev "$ifc" 2>/dev/null || true
    done < <(ip -o -4 addr show dev "$ifc" | awk '{print $4}')
    if (( ${#original_addrs[@]} > 0 )); then
      for addr in "${original_addrs[@]}"; do
        ip addr add "$addr" dev "$ifc" 2>/dev/null || true
      done
    else
      ip addr add "$host_cidr" dev "$ifc" 2>/dev/null || true
    fi
  fi

  warn "No 10.* peer found on $ifc"
  warn "gadget may not be configured on the Pi side."
  if (( ping_attempts >= max_scan_pings )); then
    warn "Discovery stopped after $ping_attempts bounded ping attempts."
  fi
  if [[ ${#scan_prefixes[@]} -eq 0 ]]; then
    warn "No directly reachable 10.* prefixes were visible on $ifc."
  else
    warn "Checked 10.* prefixes on $ifc: ${scan_prefixes[*]}"
  fi

  if [[ "$o1" != "10" ]]; then
    warn "Host IP $host_ip is outside 10.*; set HOST_IP_CIDR to a 10.* subnet for best discovery."
  fi
  warn "Try enabling gadget networking or set PI_IP=..."
  warn "Try ssh over Wi-Fi instead."
  return 1
}
# -----------------------------------------------------------------------------
# Enable IP forwarding and NAT rules
# -----------------------------------------------------------------------------
enable_nat_iptables() {
  local usb_if="$1" up_if="$2"
  say "Setting up NAT via iptables"
  echo 1 > /proc/sys/net/ipv4/ip_forward
  iptables -C FORWARD -i "$usb_if" -o "$up_if" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$usb_if" -o "$up_if" -j ACCEPT
  iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -t nat -C POSTROUTING -o "$up_if" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$up_if" -j MASQUERADE
}

enable_nat_nft() {
  local usb_if="$1" up_if="$2"
  say "Setting up NAT via nftables"
  echo 1 > /proc/sys/net/ipv4/ip_forward
  nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
  nft list chain ip nat POSTROUTING >/dev/null 2>&1 || nft add chain ip nat POSTROUTING { type nat hook postrouting priority 100 \; }
  nft list table ip filter >/dev/null 2>&1 || nft add table ip filter
  nft list chain ip filter forward >/dev/null 2>&1 || nft add chain ip filter forward { type filter hook forward priority 0 \; }
  nft list chain ip nat POSTROUTING | grep -q "oifname \"$up_if\" masquerade" || nft add rule ip nat POSTROUTING oifname "$up_if" masquerade
  nft list chain ip filter forward | grep -q "iifname \"$usb_if\" oifname \"$up_if\"" || nft add rule ip filter forward iifname "$usb_if" oifname "$up_if" accept
  nft list chain ip filter forward | grep -q "ct state established,related" || nft add rule ip filter forward ct state established,related accept
}

# -----------------------------------------------------------------------------
# Ping loop until stable
# -----------------------------------------------------------------------------
wait_for_stable_link() {
  local ip="$1" ifc="$2"
  local ok=0 tries=0
  while true; do
    ((tries++))
    if ping -c1 -W"$PING_TIMEOUT" -I "$ifc" "$ip" &>/dev/null; then
      ((ok++))
      say "Ping success ($ok/$REQUIRED_PINGS) via $ifc"
      (( ok >= REQUIRED_PINGS )) && return 0
    else
      warn "Ping fail (#$tries) via $ifc"
      ok=0
    fi
    (( tries >= MAX_TRIES && ok == 0 )) && return 1
    sleep "$RETRY_SLEEP"
  done
}

# -----------------------------------------------------------------------------
# Systemd persistence installers
# -----------------------------------------------------------------------------
install_systemd_timer() {
  say "Installing persistence timer"
  cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Reconnect USB gadget network
After=network-online.target
[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
EOF
  cat >"$TIMER_PATH" <<EOF
[Unit]
Description=Run linux-connect every 5 minutes
[Timer]
OnBootSec=15
OnUnitActiveSec=5min
Unit=linux-connect.service
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now linux-connect.timer
  say "Persistence active (timer + service)"
}

remove_systemd_timer() {
  say "Removing persistence"
  systemctl disable --now linux-connect.timer 2>/dev/null || true
  rm -f "$UNIT_PATH" "$TIMER_PATH"
  systemctl daemon-reload
  say "Removed systemd service and timer"
}

# -----------------------------------------------------------------------------
# Self installer/uninstaller
# -----------------------------------------------------------------------------
self_install() {
  say "Installing to $INSTALL_PATH"
  cp "$SELF_PATH" "$INSTALL_PATH"
  chmod 755 "$INSTALL_PATH"
  say "Installed. Run with: sudo linux_connect.sh"
}

self_uninstall() {
  say "Uninstalling linux_connect.sh"
  remove_systemd_timer
  rm -f "$INSTALL_PATH"
  say "Uninstall complete."
}

# -----------------------------------------------------------------------------
# MAIN FUNCTION
# -----------------------------------------------------------------------------
main() {
  [[ $EUID -eq 0 ]] || die "Run as root/sudo."

  # Parse args
  local CLI_PI_IP="" CLI_HOST_IP_CIDR=""
  if (( $# > 0 )) && [[ "${1:-}" != -* ]]; then
    CLI_PI_IP="$1"
    shift
  fi
  if (( $# > 0 )) && [[ "${1:-}" != -* ]]; then
    CLI_HOST_IP_CIDR="$1"
    shift
  fi

  local PI_IP="${PI_IP:-${CLI_PI_IP:-$PI_IP_DEFAULT}}"
  local HOST_IP_CIDR="${HOST_IP_CIDR:-${CLI_HOST_IP_CIDR:-$HOST_IP_CIDR_DEFAULT}}"
  local HOST_IP
  HOST_IP="$(host_ip_from_cidr "$HOST_IP_CIDR")"
  is_valid_ipv4 "$HOST_IP" || die "Invalid host CIDR/IP: $HOST_IP_CIDR"
  if [[ -n "$PI_IP" ]]; then
    [[ "$PI_IP" == "10.0.0.1" ]] && die "Refusing PI_IP=10.0.0.1 (host-side address)."
    [[ "$PI_IP" == "$HOST_IP" ]] && die "Refusing PI_IP=$PI_IP (matches host-side IP)."
  fi
  [[ -n "$PI_IP" ]] && say "Using PI_IP override: $PI_IP"

  for arg in "$@"; do
    case "$arg" in
      --help|-h) show_help; exit 0 ;;
      --install) self_install; exit 0 ;;
      --uninstall) self_uninstall; exit 0 ;;
      --persist) PERSIST=1 ;;
      --iface=*) HINT_IFACE="${arg#--iface=}" ;;
      --upstream=*) HINT_UPSTREAM="${arg#--upstream=}" ;;
      *) ;;
    esac
  done

  local upstream backend
  upstream="$(detect_upstream)"
  backend="$(detect_firewall_backend)"
  [[ -n "$upstream" ]] || die "No upstream interface detected."
  say "Using upstream: $upstream"
  say "Firewall backend: $backend"

  mapfile -t CANDIDATES < <(find_usb_nics)
  (( ${#CANDIDATES[@]} > 0 )) || die "No USB gadget interfaces detected."

  local auto_peer_found=0 last_iface=""
  for iface in "${CANDIDATES[@]}"; do
    local pi_peer="$PI_IP"
    last_iface="$iface"
    say "Trying $iface..."
    configure_usb_iface "$iface" "$HOST_IP_CIDR" || continue
    [[ "$backend" == "nft" ]] && enable_nat_nft "$iface" "$upstream" || enable_nat_iptables "$iface" "$upstream"

    if [[ -z "$pi_peer" ]]; then
      if discover_pi_ip "$iface" "$HOST_IP_CIDR"; then
        pi_peer="$DISCOVERED_PI_IP"
        auto_peer_found=1
      else
        warn "No peer detected on $iface; gadget may not be configured on the Pi side."
        continue
      fi
    fi

    if wait_for_stable_link "$pi_peer" "$iface"; then
      say "Connected successfully via $iface"
      [[ "${PERSIST:-0}" == "1" ]] && install_systemd_timer

      # --- Auto SSH connect to the Pi once link is confirmed stable ---
      echo
      echo ">>> [K.A.R.I] Connection stable. Attempting SSH into ${SSH_USER}@${pi_peer}..."
      echo

      # ensure we have key-based access (offer once, skip next time)
      ensure_ssh_key_access "${pi_peer}"

      # single session, inline (no second terminal)
      open_ssh_inline "${pi_peer}"

      exit 0
    fi
  done

  if [[ -z "$PI_IP" && "$auto_peer_found" -eq 0 ]]; then
    die "No peer detected on ${last_iface:-unknown}; gadget may not be configured on the Pi side."
  fi

  die "All interfaces tried, none responded. Check cable or gadget mode."
}

main "$@"
