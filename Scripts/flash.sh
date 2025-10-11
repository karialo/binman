#!/usr/bin/env bash
# flash — image writer with interactive wizard + expand + headless Wi-Fi/SSH + first-boot user setup
# Wizard: flash <image.(img|xz|gz|bz2|zst)>
# Direct : flash [--verify] [--expand] [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] [--User NAME --UserPass PASS] <image> <device>

set -Eeuo pipefail
VERSION="0.7.0"

# ---------- helpers ----------
err() { echo "[-] $*" >&2; }
ok()  { echo "[+] $*"; }
run() { echo "\$ $*" >&2; "$@"; }
pause() { read -rp "$*"; }

# self-sudo so users can run from their own dir
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[flash] 🔐 Root access required — elevating via sudo…"
  exec sudo -E "$0" "$@"
fi

VERIFY=0; EXPAND=0
HEADLESS=0; SSID=""; PASSWORD=""; COUNTRY=""; HIDDEN=0
USER_NAME=""; USER_PASS=""

# ---------- parse flags ----------
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)   VERIFY=1; shift ;;
    --expand)   EXPAND=1; shift ;;
    --headless) HEADLESS=1; shift ;;
    --SSID)     SSID="${2:-}"; shift 2 ;;
    --Password) PASSWORD="${2:-}"; shift 2 ;;
    --Country)  COUNTRY="${2:-}"; shift 2 ;;
    --Hidden)   HIDDEN=1; shift ;;
    --User)     USER_NAME="${2:-}"; shift 2 ;;
    --UserPass) USER_PASS="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
flash v$VERSION
Wizard: flash <image>
Direct : flash [--verify] [--expand] \
               [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] \
               [--User NAME --UserPass PASS] \
               <image> <device>
EOF
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# ---------- args ----------
if (( $# < 1 || $# > 2 )); then
  err "Usage: flash <image> [device]   (use --help for options)"
  exit 64
fi
IMG="$1"
DEV="${2:-}"
[[ -f "$IMG" ]] || { err "Image not found: $IMG"; exit 66; }

# ---------- device picker ----------
root_disk() { lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true; }
if [[ -z "$DEV" ]]; then
  ok "No device specified — discovering removable disks…"
  mapfile -t CANDS < <(lsblk -dno NAME,SIZE,MODEL,RM,TYPE | awk '$5=="disk" && $4==1{print}')
  RD="$(root_disk)"
  OPTIONS=()
  for L in "${CANDS[@]}"; do
    read -r NAME SIZE MODEL RM TYPE <<<"$L"
    [[ "$NAME" == "$RD" ]] && continue
    OPTIONS+=("$NAME|$SIZE|$MODEL")
  done
  ((${#OPTIONS[@]}>0)) || { err "No removable disks detected."; exit 65; }

  if command -v fzf >/dev/null 2>&1; then
    SEL="$(printf '%s\n' "${OPTIONS[@]}" | sed 's/|/  |  /g' | \
           fzf --prompt="Select target device > " --header="name   |   size   |   model")" \
           || { err "No selection."; exit 65; }
    DEV="/dev/$(awk '{print $1}' <<<"$SEL")"
  else
    echo "Available removable disks:"
    i=1; for o in "${OPTIONS[@]}"; do echo "  [$i] $o"; ((i++)); done
    read -rp "Pick a number: " N
    [[ "$N" =~ ^[0-9]+$ ]] || { err "Invalid selection."; exit 65; }
    CH="${OPTIONS[$((N-1))]}"; DEV="/dev/$(cut -d'|' -f1 <<<"$CH")"
  fi
fi

# ---------- device sanity ----------
[[ -b "$DEV" ]] || { err "Not a block device: $DEV"; exit 65; }
if [[ "$DEV" =~ [0-9]$ || "$DEV" =~ .+p[0-9]+$ ]]; then
  err "Target must be the WHOLE device (e.g., /dev/sdb), not a partition."
  exit 65
fi
RD="$(root_disk)"; [[ -n "$RD" && "/dev/$RD" == "$DEV" ]] && { err "Refusing to flash current root disk: $DEV"; exit 70; }

# ---------- confirmations ----------
echo ">>> Image : $IMG"
echo ">>> Device: $DEV"
echo ">>> Pre-state:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DEV" || true; echo
read -rp "Type the device path to confirm (exact): " A
read -rp "Type it again to confirm (exact): " B
[[ "$A" == "$DEV" && "$B" == "$DEV" ]] || { err "Confirmation mismatch. Aborting."; exit 71; }
read -rp "FINAL WARNING: This will overwrite $DEV. Type YEAH to continue: " FINAL
[[ "$FINAL" == "YEAH" ]] || { err "Aborted."; exit 0; }

# interactive toggles if not provided
if (( EXPAND==0 )); then
  read -rp "Expand root partition to fill the device? [y/N]: " Y; [[ "$Y" =~ ^[Yy]$ ]] && EXPAND=1
fi
if (( HEADLESS==0 )); then
  read -rp "Configure Wi-Fi + enable SSH for headless boot? [y/N]: " Y; [[ "$Y" =~ ^[Yy]$ ]] && HEADLESS=1
fi
if (( HEADLESS )); then
  [[ -n "$SSID"     ]] || read -rp "SSID: " SSID
  [[ -n "$PASSWORD" ]] || { read -rsp "Password: " PASSWORD; echo; }
  # Country auto-detect if not provided: iw reg -> LANG -> US
  if [[ -z "$COUNTRY" ]]; then
    if command -v iw >/dev/null 2>&1; then
      CC="$(iw reg get 2>/dev/null | awk '/country /{print $2}' | sed 's/:.*//; q')"
      [[ "$CC" =~ ^[A-Z][A-Z]$ ]] && COUNTRY="$CC"
    fi
    if [[ -z "$COUNTRY" && -n "${LANG:-}" && "$LANG" =~ _([A-Z]{2})\. ]]; then
      COUNTRY="${BASH_REMATCH[1]}"
    fi
    COUNTRY="${COUNTRY:-US}"
  fi
  read -rp "Is the SSID hidden? [y/N]: " Y; [[ "$Y" =~ ^[Yy]$ ]] && HIDDEN=1
fi
if [[ -z "$USER_NAME" && -z "$USER_PASS" ]]; then
  read -rp "Create/set a default user on first boot? [y/N]: " Y
  if [[ "$Y" =~ ^[Yy]$ ]]; then
    read -rp "Username (e.g., kali): " USER_NAME
    read -rsp "Password for $USER_NAME: " USER_PASS; echo
  fi
fi

# ---------- unmount any mounted partitions ----------
ok "Unmounting any mounted partitions on $DEV…"
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
  if mountpoint -q "$p" || grep -q "^$p " /proc/mounts; then run umount -f "$p"; fi
done

# ---------- decompressor ----------
decompress() {
  case "$IMG" in
    *.img)  cat "$IMG" ;;
    *.xz)   xz -dc --threads=0 "$IMG" ;;
    *.gz)   gzip -dc "$IMG" ;;
    *.bz2)  bzip2 -dc "$IMG" ;;
    *.zst)  zstd -dc "$IMG" ;;
    *)      err "Unsupported extension. Use .img, .xz, .gz, .bz2, or .zst"; return 1 ;;
  esac
}

# ---------- write ----------
ok "Flashing image to $DEV…"
decompress | dd of="$DEV" bs=8M status=progress iflag=fullblock oflag=direct conv=fsync
sync
ok "Re-scanning partition table…"
partprobe "$DEV" || true; sleep 1

ok "Post-write partitions:"
lsblk -o NAME,SIZE,FSTYPE "$DEV" || true
fdisk -l "$DEV" | sed -n '1,24p' || true

# ---------- expand rootfs ----------
if (( EXPAND )); then
  ok "Expanding root partition to fill device…"
  if ! command -v growpart &>/dev/null; then
    err "growpart not found — install with: sudo apt install cloud-guest-utils"
    exit 72
  fi
  PART="${DEV}2"
  if ! lsblk -no NAME "$DEV" | grep -q "${PART##*/}"; then
    err "Could not detect partition 2. Skipping expand."
  else
    run growpart "$DEV" 2
    run e2fsck -f "$PART"
    run resize2fs "$PART"
    ok "Root partition expanded."
  fi
fi

# ---------- headless Wi-Fi + SSH ----------
if (( HEADLESS )); then
  ok "Injecting SSH + Wi-Fi (SSID='$SSID', Country='$COUNTRY', Hidden=$HIDDEN)…"
  BOOT_PART="${DEV}1"; ROOT_PART="${DEV}2"
  MNT_BOOT="/mnt/flash-boot.$$"; MNT_ROOT="/mnt/flash-root.$$"
  mkdir -p "$MNT_BOOT" "$MNT_ROOT"
  run mount -t vfat "$BOOT_PART" "$MNT_BOOT"
  run touch "$MNT_BOOT/ssh"

  esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }
  SSID_ESC="$(printf "%s" "$SSID" | esc)"
  PASS_ESC="$(printf "%s" "$PASSWORD" | esc)"

  # wpa_supplicant (read by some images on first boot)
  {
    echo "country=$COUNTRY"
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
    echo "update_config=1"
    echo
    echo "network={"
    echo "    ssid=\"$SSID_ESC\""
    echo "    psk=\"$PASS_ESC\""
    echo "    key_mgmt=WPA-PSK"
    echo "    proto=RSN"
    echo "    pairwise=CCMP"
    echo "    group=CCMP"
    (( HIDDEN )) && echo "    scan_ssid=1"
    echo "}"
  } > "$MNT_BOOT/wpa_supplicant.conf"

  # Also seed NetworkManager so Kali definitely connects
  run mount "$ROOT_PART" "$MNT_ROOT"
  mkdir -p "$MNT_ROOT/etc/NetworkManager/system-connections"
  NM="$MNT_ROOT/etc/NetworkManager/system-connections/${SSID_ESC}.nmconnection"
  cat > "$NM" <<EOF
[connection]
id=${SSID_ESC}
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=infrastructure
ssid=${SSID_ESC}

[wifi-security]
key-mgmt=wpa-psk
psk=${PASS_ESC}

[ipv4]
method=auto

[ipv6]
method=ignore
EOF
  chmod 600 "$NM"

  # ---------- first-boot user creation (optional) ----------
  if [[ -n "$USER_NAME" && -n "$USER_PASS" ]]; then
    ok "Seeding first-boot user creation for '$USER_NAME'…"
    # drop a one-shot service + script
    mkdir -p "$MNT_ROOT/usr/local/sbin" "$MNT_ROOT/etc/systemd/system"
    cat > "$MNT_ROOT/usr/local/sbin/apply-userconf.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
CONF="/boot/userconf"
if [[ ! -f "$CONF" ]]; then exit 0; fi
# shellcheck disable=SC1090
source "$CONF"   # expects USER_NAME, USER_PASS (plain)
user="${USER_NAME:-kali}"
pass="${USER_PASS:-kali}"
if id "$user" &>/dev/null; then
  echo "$user:$pass" | chpasswd
else
  useradd -m -s /bin/bash "$user"
  echo "$user:$pass" | chpasswd
  usermod -aG sudo,plugdev,adm,video,audio,netdev "$user" 2>/dev/null || true
fi
# enable ssh permanently (if image uses ssh service)
systemctl enable ssh 2>/dev/null || true
# cleanup and disable self
rm -f "$CONF"
systemctl disable apply-userconf.service 2>/dev/null || true
EOS
    chmod 755 "$MNT_ROOT/usr/local/sbin/apply-userconf.sh"

    cat > "$MNT_ROOT/etc/systemd/system/apply-userconf.service" <<'EOS'
[Unit]
Description=Apply first-boot user configuration
After=local-fs.target
ConditionPathExists=/boot/userconf

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-userconf.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOS
    # Write the userconf file on the boot partition for the service to consume
    {
      echo "USER_NAME=\"$USER_NAME\""
      echo "USER_PASS=\"$USER_PASS\""
    } > "$MNT_BOOT/userconf"
    # enable service
    chroot "$MNT_ROOT" systemctl enable apply-userconf.service >/dev/null 2>&1 || true
  fi

  sync
  run umount "$MNT_ROOT" || true
  run umount "$MNT_BOOT" || true
  rmdir "$MNT_ROOT" "$MNT_BOOT" || true
  ok "Headless + (optional) user setup staged."
fi

# ---------- optional quick verification ----------
if (( VERIFY )); then
  ok "Verifying first 16 MiB…"
  decompress | dd bs=1M count=16 status=none | sha256sum | awk '{print "[img:first16MiB] " $1}'
  dd if="$DEV" bs=1M count=16 status=none | sha256sum | awk '{print "[dev:first16MiB] " $1}'
fi

ok "sync + safe eject hint:"
echo "  sync && eject $DEV"
echo "[done]"
