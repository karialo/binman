#!/usr/bin/env bash
# flash — image writer with interactive wizard + expand + headless Wi-Fi/SSH + first-boot user setup
# Wizard: flash <image.(img|xz|gz|bz2|zst)>
# Direct : flash [--verify] [--expand] [--gadget|--no-gadget] [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] [--User NAME --UserPass PASS] <image> <device>
#
# Manual test checklist:
# - Run flash.sh with --headless --SSID --Password --Country GB [--gadget] on a spare SD.
# - Mount SD partitions on laptop:
# - Verify NM connection exists, no interface-name, psk uses NM-escaped password.
# - Verify dtparam=spi=on present in config file (firmware/config.txt or config.txt).
# - If --gadget is used, verify config/cmdline include dtoverlay=dwc2 + modules-load=dwc2,g_ether.
# - Verify rootfs /etc/wpa_supplicant/wpa_supplicant.conf contains country=GB.
# - Verify first-boot scripts check both /boot and /boot/firmware triggers and remove triggers.
# - Boot Pi, plug into the DATA USB port, and confirm host sees usb0/enx*.
# - For hotspot testing, use a 2.4 GHz WPA2 hotspot (not 5 GHz-only or WPA3-only).

set -Eeuo pipefail
VERSION="0.8.2"

# ---------- helpers ----------
err() { echo "[-] $*" >&2; }
ok()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
run() { echo "\$ $*" >&2; "$@"; }
pause() { read -rp "$*"; }

normalize_country() {
  local cc="${1:-}"
  cc="${cc#"${cc%%[![:space:]]*}"}"
  cc="${cc%"${cc##*[![:space:]]}"}"
  printf '%s' "${cc^^}"
}

is_iso3166_alpha2() {
  local cc="${1:-}"
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || return 1

  # Prefer tzdata's ISO3166 list if present.
  if [[ -r /usr/share/zoneinfo/iso3166.tab ]]; then
    grep -qE "^${cc}[[:space:]]" /usr/share/zoneinfo/iso3166.tab || return 1
    return 0
  fi

  # Fallback list (ISO 3166-1 alpha-2).
  case "$cc" in
    AD|AE|AF|AG|AI|AL|AM|AO|AQ|AR|AS|AT|AU|AW|AX|AZ) return 0 ;;
    BA|BB|BD|BE|BF|BG|BH|BI|BJ|BL|BM|BN|BO|BQ|BR|BS|BT|BV|BW|BY|BZ) return 0 ;;
    CA|CC|CD|CF|CG|CH|CI|CK|CL|CM|CN|CO|CR|CU|CV|CW|CX|CY|CZ) return 0 ;;
    DE|DJ|DK|DM|DO|DZ) return 0 ;;
    EC|EE|EG|EH|ER|ES|ET) return 0 ;;
    FI|FJ|FK|FM|FO|FR) return 0 ;;
    GA|GB|GD|GE|GF|GG|GH|GI|GL|GM|GN|GP|GQ|GR|GS|GT|GU|GW|GY) return 0 ;;
    HK|HM|HN|HR|HT|HU) return 0 ;;
    ID|IE|IL|IM|IN|IO|IQ|IR|IS|IT) return 0 ;;
    JE|JM|JO|JP) return 0 ;;
    KE|KG|KH|KI|KM|KN|KP|KR|KW|KY|KZ) return 0 ;;
    LA|LB|LC|LI|LK|LR|LS|LT|LU|LV|LY) return 0 ;;
    MA|MC|MD|ME|MF|MG|MH|MK|ML|MM|MN|MO|MP|MQ|MR|MS|MT|MU|MV|MW|MX|MY|MZ) return 0 ;;
    NA|NC|NE|NF|NG|NI|NL|NO|NP|NR|NU|NZ) return 0 ;;
    OM) return 0 ;;
    PA|PE|PF|PG|PH|PK|PL|PM|PN|PR|PS|PT|PW|PY) return 0 ;;
    QA) return 0 ;;
    RE|RO|RS|RU|RW) return 0 ;;
    SA|SB|SC|SD|SE|SG|SH|SI|SJ|SK|SL|SM|SN|SO|SR|SS|ST|SV|SX|SY|SZ) return 0 ;;
    TC|TD|TF|TG|TH|TJ|TK|TL|TM|TN|TO|TR|TT|TV|TW|TZ) return 0 ;;
    UA|UG|UM|US|UY|UZ) return 0 ;;
    VA|VC|VE|VG|VI|VN|VU) return 0 ;;
    WF|WS) return 0 ;;
    YE|YT) return 0 ;;
    ZA|ZM|ZW) return 0 ;;
    *) return 1 ;;
  esac
}

require_country_or_exit() {
  local cc
  cc="$(normalize_country "${1:-}")"
  if [[ -z "$cc" ]]; then
    err "Country code is empty. Use --Country CC (ISO3166-1 alpha-2, e.g. GB)."
    exit 64
  fi
  if ! is_iso3166_alpha2 "$cc"; then
    err "Invalid country code: '$cc' (expected ISO3166-1 alpha-2, e.g. GB, US, DE)."
    exit 64
  fi
  printf '%s' "$cc"
}

nm_escape() {
  # Escape for NetworkManager keyfile (.nmconnection) format (GLib keyfile string escapes).
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ensure_root_wpa_country() {
  local root="${1:?}"
  local cc="${2:?}"
  local wpa="$root/etc/wpa_supplicant/wpa_supplicant.conf"
  local tmp

  mkdir -p "${wpa%/*}"
  if [[ ! -e "$wpa" ]]; then
    cat >"$wpa" <<EOF
country=$cc
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF
    return 0
  fi

  tmp="${wpa}.flash.$$"
  awk -v cc="$cc" '
    BEGIN{inserted=0}
    /^[[:space:]]*country=/ {next}
    {
      if (!inserted && $0 !~ /^[[:space:]]*($|[#;])/ ) {
        print "country=" cc
        inserted=1
      }
      print
    }
    END{
      if (!inserted) print "country=" cc
    }
  ' "$wpa" >"$tmp"
  cat "$tmp" >"$wpa"
  rm -f "$tmp"
}

ensure_root_crda_regdomain() {
  local root="${1:?}"
  local cc="${2:?}"
  local crda="$root/etc/default/crda"

  [[ -f "$crda" ]] || return 0
  if grep -qE '^[[:space:]]*REGDOMAIN=' "$crda"; then
    sed -i -E "s/^[[:space:]]*REGDOMAIN=.*/REGDOMAIN=$cc/" "$crda"
  else
    printf '\nREGDOMAIN=%s\n' "$cc" >>"$crda"
  fi
}

cmdline_has_gadget_modules() {
  local cmdline="${1:?}"
  local line token modules

  IFS= read -r line <"$cmdline" || line=""
  line="${line//$'\r'/}"
  for token in $line; do
    [[ "$token" == modules-load=* ]] || continue
    modules=",${token#modules-load=},"
    [[ "$modules" == *,dwc2,* && "$modules" == *,g_ether,* ]] && return 0
  done
  return 1
}

ensure_cmdline_gadget_modules() {
  local cmdline="${1:?}"
  local line token raw csv m
  local -a out=()
  local -a mods=()
  local -a merged=()
  local had_modules_load=0
  local changed=0
  declare -A seen=()

  IFS= read -r line <"$cmdline" || line=""
  line="${line//$'\r'/}"

  for token in $line; do
    if [[ "$token" == modules-load=* ]]; then
      had_modules_load=1
      raw="${token#modules-load=}"
      mods=()
      merged=()
      seen=()
      IFS=',' read -r -a mods <<<"$raw"
      for m in "${mods[@]}"; do
        m="${m//[[:space:]]/}"
        [[ -z "$m" ]] && continue
        if [[ -z "${seen[$m]+x}" ]]; then
          seen["$m"]=1
          merged+=("$m")
        fi
      done
      for m in dwc2 g_ether; do
        if [[ -z "${seen[$m]+x}" ]]; then
          seen["$m"]=1
          merged+=("$m")
          changed=1
        fi
      done
      csv="$(IFS=,; echo "${merged[*]}")"
      token="modules-load=${csv}"
    fi
    out+=("$token")
  done

  if (( !had_modules_load )); then
    out+=("modules-load=dwc2,g_ether")
    changed=1
  fi

  if [[ "${out[*]}" != "$line" ]]; then
    changed=1
  fi

  printf '%s\n' "${out[*]}" >"$cmdline"
  (( changed ))
}

stage_usb_gadget_fallback_service() {
  local root="${1:?}"

  mkdir -p "$root/usr/local/sbin" "$root/etc/systemd/system"

  cat >"$root/usr/local/sbin/apply-usb-gadget.sh" <<'EOS'
#!/bin/bash
set -o pipefail

loaded() {
  grep -qE '^g_ether ' /proc/modules 2>/dev/null
}

cleanup() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable apply-usb-gadget.service >/dev/null 2>&1 || true
  fi
}

if loaded; then
  cleanup
  exit 0
fi

if ! command -v modprobe >/dev/null 2>&1; then
  cleanup
  exit 0
fi

modprobe dwc2 >/dev/null 2>&1 || true
modprobe g_ether >/dev/null 2>&1 || true

loaded && cleanup
exit 0
EOS
  chmod 755 "$root/usr/local/sbin/apply-usb-gadget.sh"

  cat >"$root/etc/systemd/system/apply-usb-gadget.service" <<'EOS'
[Unit]
Description=Fallback USB gadget setup (dwc2 + g_ether)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-usb-gadget.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOS

  chroot "$root" systemctl enable apply-usb-gadget.service >/dev/null 2>&1 || true
}

# self-sudo so users can run from their own dir
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[flash] 🔐 Root access required — elevating via sudo…"
  exec sudo -E "$0" "$@"
fi

VERIFY=0; EXPAND=0
# Default is OFF for safety. Use --gadget to opt in.
GADGET=0
HEADLESS=0; SSID=""; PASSWORD=""; COUNTRY=""; HIDDEN=0
USER_NAME=""; USER_PASS=""

# ---------- parse flags ----------
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)   VERIFY=1; shift ;;
    --expand)   EXPAND=1; shift ;;
    --gadget)   GADGET=1; shift ;;
    --no-gadget) GADGET=0; shift ;;
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
               [--gadget|--no-gadget] \
               [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] \
               [--User NAME --UserPass PASS] \
               <image> <device>
EOF
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

# Normalize + validate explicit --Country early (if provided).
if [[ -n "${COUNTRY:-}" ]]; then
  COUNTRY="$(require_country_or_exit "$COUNTRY")"
fi

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
  if [[ "$SSID" == *$'\n'* || "$SSID" == *$'\r'* ]]; then
    err "SSID contains a newline which is not supported."
    exit 64
  fi
  if [[ "$PASSWORD" == *$'\n'* || "$PASSWORD" == *$'\r'* ]]; then
    err "Password contains a newline which is not supported."
    exit 64
  fi
  # Country auto-detect if not provided: iw reg -> LANG -> GB
  if [[ -z "$COUNTRY" ]]; then
    if command -v iw >/dev/null 2>&1; then
      CC="$(iw reg get 2>/dev/null | awk '/country /{print $2}' | sed 's/:.*//; q')"
      [[ "$CC" =~ ^[A-Z][A-Z]$ ]] && COUNTRY="$CC"
    fi
    if [[ -z "$COUNTRY" && -n "${LANG:-}" && "$LANG" =~ _([A-Z]{2})\. ]]; then
      COUNTRY="${BASH_REMATCH[1]}"
    fi
    COUNTRY="${COUNTRY:-GB}"
  fi
  COUNTRY="$(require_country_or_exit "$COUNTRY")"
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
    (( HIDDEN )) && echo "    scan_ssid=1"
    echo "}"
  } > "$MNT_BOOT/wpa_supplicant.conf"

  # Enable SPI (best effort; safe to skip on non-Pi images).
  SPI_CFG=""
  if [[ -f "$MNT_BOOT/firmware/config.txt" ]]; then
    SPI_CFG="$MNT_BOOT/firmware/config.txt"
  elif [[ -f "$MNT_BOOT/config.txt" ]]; then
    SPI_CFG="$MNT_BOOT/config.txt"
  fi
  if [[ -n "$SPI_CFG" ]]; then
    if grep -qE '^[[:space:]]*dtparam=spi=on([[:space:]]|,|$)' "$SPI_CFG"; then
      ok "SPI already enabled (dtparam=spi=on)"
    elif grep -qE '^[[:space:]]*dtparam=spi=' "$SPI_CFG"; then
      if sed -i -E 's/^[[:space:]]*dtparam=spi=.*/dtparam=spi=on/' "$SPI_CFG"; then
        ok "SPI enabled (dtparam=spi=on)"
      else
        err "SPI enable failed (could not update config.txt; continuing)"
      fi
    else
      TMP_SPI="${SPI_CFG}.flash.$$"
      if awk '
        BEGIN{added=0}
        /^[[:space:]]*#/ {print; next}
        /^[[:space:]]*$/ {print; next}
        {
          if (!added) { print "dtparam=spi=on"; added=1 }
          print
          next
        }
        END{ if (!added) print "dtparam=spi=on" }
      ' "$SPI_CFG" >"$TMP_SPI" && cat "$TMP_SPI" >"$SPI_CFG"; then
        ok "SPI enabled (dtparam=spi=on)"
      else
        err "SPI enable failed (could not update config.txt; continuing)"
      fi
      rm -f "$TMP_SPI"
    fi
  else
    ok "SPI config.txt not found (skipping SPI enable)"
  fi

  # Also seed NetworkManager so Kali definitely connects
  run mount "$ROOT_PART" "$MNT_ROOT"
  # Persist regdom in rootfs (not just /boot).
  ensure_root_wpa_country "$MNT_ROOT" "$COUNTRY"
  ensure_root_crda_regdomain "$MNT_ROOT" "$COUNTRY"

  # Stage a first-boot country/regdom applier (best effort; safe on non-systemd images).
  ok "Staging first-boot Wi-Fi country applier…"
  {
    echo "COUNTRY=\"$COUNTRY\""
  } >"$MNT_BOOT/wificountry"
  mkdir -p "$MNT_ROOT/usr/local/sbin" "$MNT_ROOT/etc/systemd/system"
  cat >"$MNT_ROOT/usr/local/sbin/apply-wificountry.sh" <<'EOS'
#!/bin/bash
set -o pipefail

CONF=""
for p in /boot/wificountry /boot/firmware/wificountry; do
  if [[ -f "$p" ]]; then
    CONF="$p"
    break
  fi
done
if [[ -z "$CONF" ]]; then
  exit 0
fi

cleanup() {
  rm -f "$CONF" 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable apply-wificountry.service >/dev/null 2>&1 || true
  fi
}

COUNTRY=""
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF" >/dev/null 2>&1 || true
fi
COUNTRY="${COUNTRY:-}"
COUNTRY="${COUNTRY#"${COUNTRY%%[![:space:]]*}"}"
COUNTRY="${COUNTRY%"${COUNTRY##*[![:space:]]}"}"
COUNTRY="${COUNTRY^^}"

if [[ ! "$COUNTRY" =~ ^[A-Z]{2}$ ]]; then
  cleanup
  exit 0
fi

if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country "$COUNTRY" >/dev/null 2>&1 || true
  raspi-config nonint do_spi 0 >/dev/null 2>&1 || true
elif command -v iw >/dev/null 2>&1; then
  iw reg set "$COUNTRY" >/dev/null 2>&1 || true
fi

WPA="/etc/wpa_supplicant/wpa_supplicant.conf"
mkdir -p "${WPA%/*}" 2>/dev/null || true
if [[ ! -e "$WPA" ]]; then
  cat >"$WPA" <<EOF
country=$COUNTRY
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF
else
  tmp="${WPA}.tmp.$$"
  awk -v cc="$COUNTRY" '
    BEGIN{inserted=0}
    /^[[:space:]]*country=/ {next}
    {
      if (!inserted && $0 !~ /^[[:space:]]*($|[#;])/ ) {
        print "country=" cc
        inserted=1
      }
      print
    }
    END{
      if (!inserted) print "country=" cc
    }
  ' "$WPA" >"$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]]; then
    cat "$tmp" >"$WPA" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
fi

CRDA="/etc/default/crda"
if [[ -f "$CRDA" ]]; then
  if grep -qE '^[[:space:]]*REGDOMAIN=' "$CRDA" 2>/dev/null; then
    sed -i -E "s/^[[:space:]]*REGDOMAIN=.*/REGDOMAIN=$COUNTRY/" "$CRDA" 2>/dev/null || true
  else
    printf '\nREGDOMAIN=%s\n' "$COUNTRY" >>"$CRDA" 2>/dev/null || true
  fi
fi

cleanup
exit 0
EOS
  chmod 755 "$MNT_ROOT/usr/local/sbin/apply-wificountry.sh"

  cat >"$MNT_ROOT/etc/systemd/system/apply-wificountry.service" <<'EOS'
[Unit]
Description=Apply first-boot Wi-Fi country/regdom
After=local-fs.target
Before=NetworkManager.service wpa_supplicant.service
ConditionPathExists=|/boot/wificountry
ConditionPathExists=|/boot/firmware/wificountry

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-wificountry.sh
RemainAfterExit=no

[Install]
WantedBy=network-pre.target
WantedBy=multi-user.target
EOS
  chroot "$MNT_ROOT" systemctl enable apply-wificountry.service >/dev/null 2>&1 || true

  mkdir -p "$MNT_ROOT/etc/NetworkManager/system-connections"
  NM_UUID="$(cat /proc/sys/kernel/random/uuid)"
  NM="$MNT_ROOT/etc/NetworkManager/system-connections/wifi-${NM_UUID}.nmconnection"
  SSID_NM="$(nm_escape "$SSID")"
  PASS_NM="$(nm_escape "$PASSWORD")"
  cat > "$NM" <<EOF
[connection]
id=${SSID_NM}
uuid=${NM_UUID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${SSID_NM}
powersave=2
EOF
  if (( HIDDEN )); then
    echo "hidden=true" >>"$NM"
  fi
  cat >>"$NM" <<EOF

[wifi-security]
key-mgmt=wpa-psk
psk=${PASS_NM}

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
set -o pipefail

CONF=""
for p in /boot/userconf /boot/firmware/userconf; do
  if [[ -f "$p" ]]; then
    CONF="$p"
    break
  fi
done
if [[ -z "$CONF" ]]; then
  exit 0
fi

cleanup() {
  rm -f "$CONF" 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable apply-userconf.service >/dev/null 2>&1 || true
  fi
}

# shellcheck disable=SC1090
source "$CONF" >/dev/null 2>&1 || true  # expects USER_NAME, USER_PASS (plain)
user="${USER_NAME:-kali}"
pass="${USER_PASS:-kali}"
if command -v id >/dev/null 2>&1 && id "$user" &>/dev/null; then
  echo "$user:$pass" | chpasswd 2>/dev/null || true
else
  useradd -m -s /bin/bash "$user" 2>/dev/null || true
  echo "$user:$pass" | chpasswd 2>/dev/null || true
  usermod -aG sudo,plugdev,adm,video,audio,netdev "$user" 2>/dev/null || true
fi
# enable ssh permanently (if image uses ssh service)
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable ssh >/dev/null 2>&1 || true
fi

cleanup
exit 0
EOS
    chmod 755 "$MNT_ROOT/usr/local/sbin/apply-userconf.sh"

    cat > "$MNT_ROOT/etc/systemd/system/apply-userconf.service" <<'EOS'
[Unit]
Description=Apply first-boot user configuration
After=local-fs.target
ConditionPathExists=|/boot/userconf
ConditionPathExists=|/boot/firmware/userconf

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

# ---------- optional USB gadget mode ----------
if (( GADGET )); then
  ok "Staging USB gadget mode (dwc2 + g_ether)…"
  BOOT_PART="${DEV}1"; ROOT_PART="${DEV}2"
  MNT_BOOT="/mnt/flash-boot-gadget.$$"
  MNT_ROOT="/mnt/flash-root-gadget.$$"
  GADGET_CFG=""
  GADGET_CMDLINE=""
  GADGET_CHANGED=0
  NEED_GADGET_FALLBACK=0

  mkdir -p "$MNT_BOOT"
  run mount -t vfat "$BOOT_PART" "$MNT_BOOT"

  if [[ -f "$MNT_BOOT/firmware/config.txt" ]]; then
    GADGET_CFG="$MNT_BOOT/firmware/config.txt"
  elif [[ -f "$MNT_BOOT/config.txt" ]]; then
    GADGET_CFG="$MNT_BOOT/config.txt"
  fi

  if [[ -f "$MNT_BOOT/firmware/cmdline.txt" ]]; then
    GADGET_CMDLINE="$MNT_BOOT/firmware/cmdline.txt"
  elif [[ -f "$MNT_BOOT/cmdline.txt" ]]; then
    GADGET_CMDLINE="$MNT_BOOT/cmdline.txt"
  fi

  if [[ -z "$GADGET_CFG" ]]; then
    warn "USB gadget config.txt not found"
    NEED_GADGET_FALLBACK=1
  else
    if ! grep -qE '^[[:space:]]*dtoverlay=dwc2[[:space:]]*$' "$GADGET_CFG"; then
      printf '\n[all]\ndtoverlay=dwc2\n' >>"$GADGET_CFG"
      GADGET_CHANGED=1
    fi
  fi

  if [[ -z "$GADGET_CMDLINE" ]]; then
    warn "USB gadget cmdline.txt not found"
    NEED_GADGET_FALLBACK=1
  else
    if ensure_cmdline_gadget_modules "$GADGET_CMDLINE"; then
      GADGET_CHANGED=1
    fi
    if ! cmdline_has_gadget_modules "$GADGET_CMDLINE"; then
      NEED_GADGET_FALLBACK=1
    fi
  fi

  if (( NEED_GADGET_FALLBACK )); then
    ok "Staging USB gadget fallback service…"
    mkdir -p "$MNT_ROOT"
    run mount "$ROOT_PART" "$MNT_ROOT"
    stage_usb_gadget_fallback_service "$MNT_ROOT"
    sync
    run umount "$MNT_ROOT" || true
    rmdir "$MNT_ROOT" || true
  fi

  if (( GADGET_CHANGED || NEED_GADGET_FALLBACK )); then
    ok "USB gadget enabled (dwc2 + g_ether)"
  else
    ok "USB gadget already enabled"
  fi

  sync
  run umount "$MNT_BOOT" || true
  rmdir "$MNT_BOOT" || true
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
