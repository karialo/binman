#!/usr/bin/env bash
# flash — image writer with interactive wizard + expand + headless Wi-Fi/SSH + first-boot user setup
# Wizard: flash <image.(img|iso|xz|gz|bz2|zst)>
# Direct : flash [--verify] [--expand] [--gadget|--no-gadget] [--headless --SSID "name" --Password "pass" --Country CC [--Hidden]] [--User NAME --UserPass PASS] <image> <device>
# Diagnose: flash --diagnose-mounts [bootfs_mount] [rootfs_mount]
#
# Changelog:
# - v0.9.0: improved UX/logging, robust boot path resolution, optional usb0 gadget IP staging,
#           post-flash diagnostics summary, and --diagnose-mounts debug mode.
# - v0.8.3: prior release.
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
VERSION="0.9.0"

# ---------- helpers ----------
say()  { printf '%s\n' "$*"; }
info() { printf 'ℹ️  %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
err()  { printf '❌ %s\n' "$*" >&2; }
ok()   { info "$*"; }
run()  { printf '↳ $ %s\n' "$*" >&2; "$@"; }
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

is_raspbian_root() {
  local root="${1:?}"
  local osr="$root/etc/os-release"
  local id id_like

  [[ -r "$osr" ]] || return 1
  id="$(awk -F= '$1=="ID"{print tolower($2); exit}' "$osr" | tr -d '"')"
  id_like="$(awk -F= '$1=="ID_LIKE"{print tolower($2); exit}' "$osr" | tr -d '"')"
  [[ "$id" == "raspbian" ]] && return 0
  [[ " $id_like " == *" raspbian "* ]]
}

is_valid_unix_username() {
  local user="${1:-}"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

enable_service_offline() {
  local root="${1:?}"
  local unit="${2:?}"
  local target="${3:?}"
  local wants="$root/etc/systemd/system/${target}.wants"
  local unit_path="$root/etc/systemd/system/$unit"

  [[ -e "$unit_path" ]] || return 1
  mkdir -p "$wants" || return 1
  ln -sfn "../${unit}" "$wants/$unit"
}

ensure_top_level_dwc2_overlay() {
  local cfg="${1:?}"
  local tmp="${cfg}.flash.$$"

  # Return codes:
  # 0 -> changed (inserted top-level dtoverlay=dwc2)
  # 1 -> already present at top-level or in [all]
  # 2 -> failure while updating
  if awk '
    BEGIN{sec=""; found=0}
    /^[[:space:]]*\[/{
      sec=$0
      gsub(/^[[:space:]]*\[/, "", sec)
      gsub(/\][[:space:]]*$/, "", sec)
      sec=tolower(sec)
      next
    }
    /^[[:space:]]*dtoverlay=dwc2([[:space:]]|,|$)/{
      if (sec=="" || sec=="all") found=1
    }
    END{exit(found ? 0 : 1)}
  ' "$cfg"; then
    return 1
  fi

  if awk '
    BEGIN{added=0}
    {
      if (!added && $0 ~ /^[[:space:]]*\[/) {
        print "dtoverlay=dwc2"
        added=1
      }
      print
    }
    END{
      if (!added) print "dtoverlay=dwc2"
    }
  ' "$cfg" >"$tmp" && cat "$tmp" >"$cfg"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 2
}

resolve_boot_paths() {
  local boot_mount="${1:?}"
  local require="${2:-both}"

  BOOT_CONFIG=""
  BOOT_CMDLINE=""
  BOOT_LAYOUT="unknown"

  if [[ -f "$boot_mount/firmware/config.txt" || -f "$boot_mount/firmware/cmdline.txt" ]]; then
    BOOT_LAYOUT="bootfs/firmware"
  elif [[ -f "$boot_mount/config.txt" || -f "$boot_mount/cmdline.txt" ]]; then
    BOOT_LAYOUT="bootfs root"
  fi

  if [[ -f "$boot_mount/firmware/config.txt" ]]; then
    BOOT_CONFIG="$boot_mount/firmware/config.txt"
  elif [[ -f "$boot_mount/config.txt" ]]; then
    BOOT_CONFIG="$boot_mount/config.txt"
  fi

  if [[ -f "$boot_mount/firmware/cmdline.txt" ]]; then
    BOOT_CMDLINE="$boot_mount/firmware/cmdline.txt"
  elif [[ -f "$boot_mount/cmdline.txt" ]]; then
    BOOT_CMDLINE="$boot_mount/cmdline.txt"
  fi

  case "$require" in
    both)
      if [[ -z "$BOOT_CONFIG" ]]; then
        err "Unable to find config.txt in '$boot_mount' (checked '$boot_mount/config.txt' and '$boot_mount/firmware/config.txt')."
        return 1
      fi
      if [[ -z "$BOOT_CMDLINE" ]]; then
        err "Unable to find cmdline.txt in '$boot_mount' (checked '$boot_mount/cmdline.txt' and '$boot_mount/firmware/cmdline.txt')."
        return 1
      fi
      ;;
    config)
      if [[ -z "$BOOT_CONFIG" ]]; then
        err "Unable to find config.txt in '$boot_mount' (checked '$boot_mount/config.txt' and '$boot_mount/firmware/config.txt')."
        return 1
      fi
      ;;
    cmdline)
      if [[ -z "$BOOT_CMDLINE" ]]; then
        err "Unable to find cmdline.txt in '$boot_mount' (checked '$boot_mount/cmdline.txt' and '$boot_mount/firmware/cmdline.txt')."
        return 1
      fi
      ;;
    *)
      err "resolve_boot_paths called with invalid mode '$require'."
      return 1
      ;;
  esac
  return 0
}

root_has_networkmanager() {
  local root="${1:?}"
  [[ -x "$root/usr/sbin/NetworkManager" ]] \
    || [[ -x "$root/usr/bin/NetworkManager" ]] \
    || [[ -f "$root/lib/systemd/system/NetworkManager.service" ]] \
    || [[ -f "$root/usr/lib/systemd/system/NetworkManager.service" ]] \
    || [[ -f "$root/etc/NetworkManager/NetworkManager.conf" ]]
}

list_device_partitions() {
  local dev="${1:?}"
  lsblk -lnpo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"{print $1}'
}

partition_fstype_lc() {
  local part="${1:?}"
  local fs
  fs="$(lsblk -no FSTYPE "$part" 2>/dev/null | head -n1 || true)"
  printf '%s' "${fs,,}"
}

partition_size_bytes() {
  local part="${1:?}"
  lsblk -bno SIZE "$part" 2>/dev/null | head -n1 || true
}

partition_number_from_path() {
  local part="${1:?}"
  if [[ "$part" =~ p([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$part" =~ ([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

find_largest_linux_fs_partition() {
  local dev="${1:?}"
  local part fs size
  local best_part="" best_fs="" best_size=0
  local -a parts=()

  mapfile -t parts < <(list_device_partitions "$dev")
  for part in "${parts[@]}"; do
    [[ -b "$part" ]] || continue
    fs="$(partition_fstype_lc "$part")"
    case "$fs" in
      ext4|ext3|ext2|btrfs|xfs|f2fs) ;;
      *) continue ;;
    esac
    size="$(partition_size_bytes "$part")"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    if (( size > best_size )); then
      best_size="$size"
      best_part="$part"
      best_fs="$fs"
    fi
  done

  DETECTED_LINUX_PART="$best_part"
  DETECTED_LINUX_FSTYPE="$best_fs"
  [[ -n "$best_part" ]]
}

find_partitions_for_pi_staging() {
  local dev="${1:?}"
  local part fs
  local probe_mnt="/mnt/flash-probe.$$.$RANDOM"
  local mounted=0
  local root_found=0
  local rc=1
  local -a parts=()

  DETECTED_PI_BOOT_PART=""
  DETECTED_PI_BOOT_FSTYPE=""
  DETECTED_PI_ROOT_PART=""
  DETECTED_PI_ROOT_FSTYPE=""

  mapfile -t parts < <(list_device_partitions "$dev")
  ((${#parts[@]} > 0)) || return 1
  mkdir -p "$probe_mnt"

  cleanup_probe_mount() {
    if (( mounted )); then
      umount "$probe_mnt" >/dev/null 2>&1 || true
      mounted=0
    fi
    rmdir "$probe_mnt" >/dev/null 2>&1 || true
  }
  trap cleanup_probe_mount RETURN

  # 1) Boot candidate: FAT partition that looks like Pi boot.
  for part in "${parts[@]}"; do
    [[ -b "$part" ]] || continue
    fs="$(partition_fstype_lc "$part")"
    case "$fs" in
      vfat|fat|fat12|fat16|fat32|msdos) ;;
      *) continue ;;
    esac
    if mount -o ro "$part" "$probe_mnt" >/dev/null 2>&1; then
      mounted=1
      if [[ -f "$probe_mnt/config.txt" || -f "$probe_mnt/firmware/config.txt" || -d "$probe_mnt/firmware" ]]; then
        DETECTED_PI_BOOT_PART="$part"
        DETECTED_PI_BOOT_FSTYPE="$fs"
      fi
      umount "$probe_mnt" >/dev/null 2>&1 || true
      mounted=0
      [[ -n "$DETECTED_PI_BOOT_PART" ]] && break
    fi
  done

  if [[ -n "$DETECTED_PI_BOOT_PART" ]]; then
    # 2) Root candidate: mountable Linux fs with /etc/os-release preferred.
    for part in "${parts[@]}"; do
      [[ "$part" == "$DETECTED_PI_BOOT_PART" ]] && continue
      [[ -b "$part" ]] || continue
      fs="$(partition_fstype_lc "$part")"
      case "$fs" in
        ext4|ext3|ext2|btrfs|xfs|f2fs) ;;
        *) continue ;;
      esac
      if mount -o ro "$part" "$probe_mnt" >/dev/null 2>&1; then
        mounted=1
        if [[ -f "$probe_mnt/etc/os-release" ]]; then
          DETECTED_PI_ROOT_PART="$part"
          DETECTED_PI_ROOT_FSTYPE="$fs"
          root_found=1
        fi
        umount "$probe_mnt" >/dev/null 2>&1 || true
        mounted=0
        (( root_found )) && break
      fi
    done

    if (( !root_found )); then
      for part in "${parts[@]}"; do
        [[ "$part" == "$DETECTED_PI_BOOT_PART" ]] && continue
        [[ -b "$part" ]] || continue
        fs="$(partition_fstype_lc "$part")"
        case "$fs" in
          ext4|ext3|ext2|btrfs|xfs|f2fs) ;;
          *) continue ;;
        esac
        if mount -o ro "$part" "$probe_mnt" >/dev/null 2>&1; then
          mounted=1
          if [[ -d "$probe_mnt/etc" ]]; then
            DETECTED_PI_ROOT_PART="$part"
            DETECTED_PI_ROOT_FSTYPE="$fs"
            root_found=1
          fi
          umount "$probe_mnt" >/dev/null 2>&1 || true
          mounted=0
          (( root_found )) && break
        fi
      done
    fi

    if (( root_found )); then
      rc=0
    fi
  fi

  trap - RETURN
  cleanup_probe_mount
  return "$rc"
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
  local helper="$root/usr/local/sbin/apply-usb-gadget.sh"
  local unit="$root/etc/systemd/system/apply-usb-gadget.service"

  mkdir -p "$root/usr/local/sbin" "$root/etc/systemd/system"

  cat >"$helper" <<'EOS'
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
  chmod 755 "$helper"
  summary_add_file "$helper"
  summary_add_line "$helper" "modprobe dwc2"
  summary_add_line "$helper" "modprobe g_ether"

  cat >"$unit" <<'EOS'
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
  summary_add_file "$unit"
  summary_add_line "$unit" "ExecStart=/usr/local/sbin/apply-usb-gadget.sh"

  chroot "$root" systemctl enable apply-usb-gadget.service >/dev/null 2>&1 || true
}

stage_usb0_network_config() {
  local root="${1:?}"
  local nm_dir="$root/etc/NetworkManager/system-connections"
  local nm_file="$nm_dir/usb-gadget.nmconnection"
  local ifd_file="$root/etc/network/interfaces.d/usb0"

  if root_has_networkmanager "$root"; then
    mkdir -p "$nm_dir"
    cat >"$nm_file" <<'EOF'
[connection]
id=usb-gadget
uuid=02d312ef-04a7-4f6f-9b8f-a4f6e7f7f0a0
type=ethernet
interface-name=usb0
autoconnect=true

[ipv4]
method=manual
address1=10.0.0.2/24,10.0.0.1

[ipv6]
method=ignore
EOF
    chown 0:0 "$nm_file" 2>/dev/null || true
    chmod 600 "$nm_file"
    SUMMARY_GADGET_NETWORK="NetworkManager static profile (usb0 -> 10.0.0.2/24)"
    summary_add_file "$nm_file"
    summary_add_line "$nm_file" "interface-name=usb0"
    summary_add_line "$nm_file" "address1=10.0.0.2/24,10.0.0.1"
  else
    mkdir -p "${ifd_file%/*}"
    cat >"$ifd_file" <<'EOF'
auto usb0
allow-hotplug usb0
iface usb0 inet static
    address 10.0.0.2
    netmask 255.255.255.0
EOF
    SUMMARY_GADGET_NETWORK="ifupdown static profile (usb0 -> 10.0.0.2/24)"
    summary_add_file "$ifd_file"
    summary_add_line "$ifd_file" "iface usb0 inet static"
    summary_add_line "$ifd_file" "address 10.0.0.2"
  fi
}

summary_add_file() {
  local path="${1:-}"
  path="$(summary_normalize_path "$path")"
  [[ -n "$path" ]] || return 0
  if [[ -z "${SUMMARY_FILE_SEEN[$path]+x}" ]]; then
    SUMMARY_FILE_SEEN["$path"]=1
    SUMMARY_FILES+=("$path")
  fi
}

summary_add_line() {
  local path="${1:-}"
  local line="${2:-}"
  path="$(summary_normalize_path "$path")"
  local key="${path}|${line}"
  [[ -n "$path" && -n "$line" ]] || return 0
  if [[ -z "${SUMMARY_LINE_SEEN[$key]+x}" ]]; then
    SUMMARY_LINE_SEEN["$key"]=1
    SUMMARY_LINES+=("$path :: $line")
  fi
}

summary_normalize_path() {
  local path="${1:-}"

  if [[ -n "${MNT_BOOT:-}" && "$path" == "$MNT_BOOT"* ]]; then
    printf 'bootfs%s' "${path#$MNT_BOOT}"
    return 0
  fi
  if [[ -n "${MNT_ROOT:-}" && "$path" == "$MNT_ROOT"* ]]; then
    printf 'rootfs%s' "${path#$MNT_ROOT}"
    return 0
  fi
  printf '%s' "$path"
}

config_has_dwc2_overlay() {
  local cfg="${1:?}"
  awk '
    BEGIN{sec=""; found=0}
    /^[[:space:]]*\[/{
      sec=$0
      gsub(/^[[:space:]]*\[/, "", sec)
      gsub(/\][[:space:]]*$/, "", sec)
      sec=tolower(sec)
      next
    }
    /^[[:space:]]*dtoverlay=dwc2([[:space:]]|,|$)/{
      if (sec=="" || sec=="all") found=1
    }
    END{exit(found ? 0 : 1)}
  ' "$cfg"
}

print_post_flash_summary() {
  say
  say "========== POST-FLASH SUMMARY =========="
  say "Layout:"
  say "  pi boot layout: ${SUMMARY_PI_LAYOUT}"
  say "  layout detail: ${SUMMARY_LAYOUT_DETAIL}"
  say "  boot config target: ${SUMMARY_BOOT_CFG}"
  say "  cmdline target: ${SUMMARY_CMDLINE}"
  say
  say "Staging checks:"
  say "  ssh trigger: ${SUMMARY_SSH_TRIGGER}"
  say "  wifi profile: ${SUMMARY_WIFI_PROFILE}"
  say "  country trigger: ${SUMMARY_COUNTRY_TRIGGER}"
  say "  firstboot user trigger: ${SUMMARY_USER_TRIGGER}"
  say "  wificountry service symlink: ${SUMMARY_WIFI_SYMLINKS}"
  say "  userconf service symlink: ${SUMMARY_USER_SYMLINKS}"
  say
  say "USB gadget:"
  say "  gadget mode: ${SUMMARY_GADGET_STATUS}"
  say "  usb0 network staging: ${SUMMARY_GADGET_NETWORK}"
  say "  usb0 addressing plan: Pi 10.0.0.2/24, host 10.0.0.1/24"
  if [[ "$SUMMARY_GADGET_STATUS" != "enabled" ]]; then
    warn "USB gadget not enabled: host will not see usb0; use Wi-Fi or reflash with gadget enabled."
  fi
  if [[ -n "$SUMMARY_GADGET_NOTE" ]]; then
    say "  note: ${SUMMARY_GADGET_NOTE}"
  fi
  say
  say "Modified targets:"
  if ((${#SUMMARY_FILES[@]} == 0)); then
    say "  (none recorded)"
  else
    for path in "${SUMMARY_FILES[@]}"; do
      say "  - ${path}"
    done
  fi
  say "Key lines inserted/verified (sanitized):"
  if ((${#SUMMARY_LINES[@]} == 0)); then
    say "  (none recorded)"
  else
    for line in "${SUMMARY_LINES[@]}"; do
      say "  - ${line}"
    done
  fi
}

discover_default_mounts() {
  local user_name="${SUDO_USER:-${USER:-}}"
  local -a bases=()
  if [[ -n "$user_name" ]]; then
    bases+=("/run/media/$user_name" "/media/$user_name")
  fi
  bases+=("/run/media")

  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue
    if [[ -d "$base/bootfs" && -d "$base/rootfs" ]]; then
      DIAG_BOOTFS="$base/bootfs"
      DIAG_ROOTFS="$base/rootfs"
      return 0
    fi
  done
  return 1
}

diagnose_mounts() {
  local boot_mount="${1:-}"
  local root_mount="${2:-}"
  local pi_layout_ok=0
  local nm_usb_file=""
  local ifd_usb_file=""

  if [[ -n "$boot_mount" && -z "$root_mount" ]]; then
    err "When using --diagnose-mounts with explicit paths, provide both bootfs and rootfs mount paths."
    return 1
  fi
  if [[ -z "$boot_mount" && -n "$root_mount" ]]; then
    err "When using --diagnose-mounts with explicit paths, provide both bootfs and rootfs mount paths."
    return 1
  fi

  if [[ -z "$boot_mount" && -z "$root_mount" ]]; then
    if ! discover_default_mounts; then
      err "Could not auto-detect mounted bootfs/rootfs. Pass explicit paths: --diagnose-mounts <bootfs_mount> <rootfs_mount>."
      return 1
    fi
    boot_mount="$DIAG_BOOTFS"
    root_mount="$DIAG_ROOTFS"
  fi

  if [[ ! -d "$boot_mount" ]]; then
    err "Boot mount path does not exist: $boot_mount"
    return 1
  fi
  if [[ ! -d "$root_mount" ]]; then
    err "Root mount path does not exist: $root_mount"
    return 1
  fi

  SUMMARY_LAYOUT_DETAIL="diagnose mode (bootfs=$boot_mount, rootfs=$root_mount)"
  SUMMARY_BOOT_CFG="not found"
  SUMMARY_CMDLINE="not found"
  SUMMARY_SSH_TRIGGER="no"
  SUMMARY_WIFI_PROFILE="no"
  SUMMARY_COUNTRY_TRIGGER="no"
  SUMMARY_USER_TRIGGER="no"
  SUMMARY_WIFI_SYMLINKS="unknown"
  SUMMARY_USER_SYMLINKS="unknown"
  SUMMARY_GADGET_STATUS="disabled"
  SUMMARY_GADGET_NETWORK="not found"
  SUMMARY_GADGET_NOTE=""

  SUMMARY_FILES=()
  SUMMARY_LINES=()
  SUMMARY_FILE_SEEN=()
  SUMMARY_LINE_SEEN=()

  if resolve_boot_paths "$boot_mount" "both"; then
    pi_layout_ok=1
    SUMMARY_PI_LAYOUT="yes"
    SUMMARY_LAYOUT_DETAIL="diagnose mode (bootfs=$boot_mount, rootfs=$root_mount, boot-layout=$BOOT_LAYOUT)"
    SUMMARY_BOOT_CFG="$BOOT_CONFIG"
    SUMMARY_CMDLINE="$BOOT_CMDLINE"
    summary_add_file "$BOOT_CONFIG"
    summary_add_file "$BOOT_CMDLINE"
  else
    SUMMARY_PI_LAYOUT="no"
  fi

  if [[ -f "$boot_mount/ssh" || -f "$boot_mount/firmware/ssh" ]]; then
    SUMMARY_SSH_TRIGGER="yes"
    [[ -f "$boot_mount/ssh" ]] && summary_add_file "$boot_mount/ssh"
    [[ -f "$boot_mount/firmware/ssh" ]] && summary_add_file "$boot_mount/firmware/ssh"
  fi

  if compgen -G "$root_mount/etc/NetworkManager/system-connections/wifi-*.nmconnection" >/dev/null; then
    SUMMARY_WIFI_PROFILE="yes"
  fi

  if [[ -f "$boot_mount/wificountry" || -f "$boot_mount/firmware/wificountry" ]]; then
    SUMMARY_COUNTRY_TRIGGER="yes"
    [[ -f "$boot_mount/wificountry" ]] && summary_add_file "$boot_mount/wificountry"
    [[ -f "$boot_mount/firmware/wificountry" ]] && summary_add_file "$boot_mount/firmware/wificountry"
  fi

  if [[ -f "$boot_mount/firstboot-user" || -f "$boot_mount/firmware/firstboot-user" ]]; then
    SUMMARY_USER_TRIGGER="yes"
    [[ -f "$boot_mount/firstboot-user" ]] && summary_add_file "$boot_mount/firstboot-user"
    [[ -f "$boot_mount/firmware/firstboot-user" ]] && summary_add_file "$boot_mount/firmware/firstboot-user"
  fi

  if [[ -f "$root_mount/etc/systemd/system/network-pre.target.wants/apply-wificountry.service" ]] \
    || [[ -f "$root_mount/etc/systemd/system/multi-user.target.wants/apply-wificountry.service" ]]; then
    SUMMARY_WIFI_SYMLINKS="yes"
  else
    SUMMARY_WIFI_SYMLINKS="no"
  fi

  if [[ -f "$root_mount/etc/systemd/system/multi-user.target.wants/apply-userconf.service" ]]; then
    SUMMARY_USER_SYMLINKS="yes"
  else
    SUMMARY_USER_SYMLINKS="no"
  fi

  if (( pi_layout_ok )) && [[ -r "$BOOT_CONFIG" ]] && config_has_dwc2_overlay "$BOOT_CONFIG"; then
    if [[ -r "$BOOT_CMDLINE" ]] && cmdline_has_gadget_modules "$BOOT_CMDLINE"; then
      SUMMARY_GADGET_STATUS="enabled"
      summary_add_line "$BOOT_CONFIG" "dtoverlay=dwc2"
      summary_add_line "$BOOT_CMDLINE" "modules-load=dwc2,g_ether"
    fi
  fi

  nm_usb_file="$root_mount/etc/NetworkManager/system-connections/usb-gadget.nmconnection"
  ifd_usb_file="$root_mount/etc/network/interfaces.d/usb0"
  if [[ -f "$nm_usb_file" ]]; then
    SUMMARY_GADGET_NETWORK="NetworkManager static profile (usb0 -> 10.0.0.2/24)"
    summary_add_file "$nm_usb_file"
    summary_add_line "$nm_usb_file" "interface-name=usb0"
    summary_add_line "$nm_usb_file" "address1=10.0.0.2/24,10.0.0.1"
  elif [[ -f "$ifd_usb_file" ]]; then
    SUMMARY_GADGET_NETWORK="ifupdown static profile (usb0 -> 10.0.0.2/24)"
    summary_add_file "$ifd_usb_file"
    summary_add_line "$ifd_usb_file" "iface usb0 inet static"
    summary_add_line "$ifd_usb_file" "address 10.0.0.2"
  fi

  if [[ ! -r "$boot_mount" || ! -x "$boot_mount" || ! -r "$root_mount" || ! -x "$root_mount" ]]; then
    SUMMARY_GADGET_NOTE="Some diagnostics may be incomplete due to permissions."
    warn "Read access is limited on one or more mount paths; diagnostics may be incomplete."
  fi

  print_post_flash_summary
  return 0
}

VERIFY=0; EXPAND=0
# Default is OFF for safety. Use --gadget to opt in.
GADGET=0
HEADLESS=0; SSID=""; PASSWORD=""; COUNTRY=""; HIDDEN=0
USER_NAME=""; USER_PASS=""
DIAGNOSE_MOUNTS=0
DIAG_BOOTFS=""
DIAG_ROOTFS=""
GADGET_FLAG_SET=0
SUMMARY_BOOT_CFG="not touched"
SUMMARY_CMDLINE="not touched"
SUMMARY_SSH_TRIGGER="not requested"
SUMMARY_WIFI_PROFILE="not requested"
SUMMARY_COUNTRY_TRIGGER="not requested"
SUMMARY_USER_TRIGGER="not requested"
SUMMARY_WIFI_SYMLINKS="not requested"
SUMMARY_USER_SYMLINKS="not requested"
SUMMARY_PI_LAYOUT="not checked"
SUMMARY_LAYOUT_DETAIL="not checked"
SUMMARY_GADGET_STATUS="disabled"
SUMMARY_GADGET_NETWORK="not staged"
SUMMARY_GADGET_NOTE=""
BOOT_CONFIG=""
BOOT_CMDLINE=""
BOOT_LAYOUT="unknown"
declare -a SUMMARY_FILES=()
declare -a SUMMARY_LINES=()
declare -A SUMMARY_FILE_SEEN=()
declare -A SUMMARY_LINE_SEEN=()
DETECTED_PI_LAYOUT=0
DETECTED_PI_BOOT_PART=""
DETECTED_PI_BOOT_FSTYPE=""
DETECTED_PI_ROOT_PART=""
DETECTED_PI_ROOT_FSTYPE=""
DETECTED_LINUX_PART=""
DETECTED_LINUX_FSTYPE=""
ORIG_ARGS=("$@")

# ---------- parse flags ----------
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)   VERIFY=1; shift ;;
    --expand)   EXPAND=1; shift ;;
    --gadget)   GADGET=1; GADGET_FLAG_SET=1; shift ;;
    --no-gadget) GADGET=0; GADGET_FLAG_SET=1; shift ;;
    --headless) HEADLESS=1; shift ;;
    --diagnose-mounts) DIAGNOSE_MOUNTS=1; shift ;;
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
Diagnose: flash --diagnose-mounts [bootfs_mount] [rootfs_mount]
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

if (( DIAGNOSE_MOUNTS )); then
  if (( $# > 2 )); then
    err "Usage: flash --diagnose-mounts [bootfs_mount] [rootfs_mount]"
    exit 64
  fi
  DIAG_BOOTFS="${1:-}"
  DIAG_ROOTFS="${2:-}"
  diagnose_mounts "$DIAG_BOOTFS" "$DIAG_ROOTFS"
  exit $?
fi

# self-sudo so users can run from their own dir
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  say "[flash] 🔐 Root access required; elevating via sudo..."
  exec sudo -E "$0" "${ORIG_ARGS[@]}"
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
DEV_TYPE="$(lsblk -no TYPE "$DEV" 2>/dev/null | head -n1 || true)"
if [[ "$DEV_TYPE" != "disk" ]]; then
  err "Target must be the WHOLE device (e.g., /dev/sdb), not a partition."
  exit 65
fi
RD="$(root_disk)"; [[ -n "$RD" && "/dev/$RD" == "$DEV" ]] && { err "Refusing to flash current root disk: $DEV"; exit 70; }

# ---------- confirmations ----------
say
say "=== Flash Plan ==="
say "Image : $IMG"
say "Device: $DEV"
say "Pre-state:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DEV" || true
say
read -rp "Type the device path to confirm (exact): " A
read -rp "Type it again to confirm (exact): " B
[[ "$A" == "$DEV" && "$B" == "$DEV" ]] || { err "Confirmation mismatch. Aborting."; exit 71; }
read -rp "FINAL WARNING: This will overwrite $DEV. Type YEAH to continue: " FINAL
[[ "$FINAL" == "YEAH" ]] || { err "Aborted."; exit 0; }

# interactive toggles if not provided
say "=== Optional Staging ==="
if (( EXPAND==0 )); then
  read -rp "Expand root partition to fill the device? [y/N]: " Y; [[ "$Y" =~ ^[Yy]$ ]] && EXPAND=1
fi
if (( HEADLESS==0 )); then
  read -rp "Configure Wi-Fi + enable SSH for headless boot? [y/N]: " Y; [[ "$Y" =~ ^[Yy]$ ]] && HEADLESS=1
fi
if (( GADGET_FLAG_SET==0 )); then
  say "Recommendation: enable USB gadget for direct USB SSH (Pi: 10.0.0.2/24, host: 10.0.0.1/24)."
  read -rp "Enable USB gadget networking (usb0) for easy SSH over USB? [y/N]: " Y
  [[ "$Y" =~ ^[Yy]$ ]] && GADGET=1
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
if [[ -n "$USER_NAME" || -n "$USER_PASS" ]]; then
  if [[ -z "$USER_NAME" || -z "$USER_PASS" ]]; then
    err "Use both --User and --UserPass (or neither)."
    exit 64
  fi
  if [[ "$USER_NAME" == *$'\n'* || "$USER_NAME" == *$'\r'* ]]; then
    err "Username contains a newline which is not supported."
    exit 64
  fi
  if [[ "$USER_PASS" == *$'\n'* || "$USER_PASS" == *$'\r'* ]]; then
    err "User password contains a newline which is not supported."
    exit 64
  fi
  if ! is_valid_unix_username "$USER_NAME"; then
    err "Invalid username '$USER_NAME' (use lowercase letters, digits, '_' or '-', max 32 chars)."
    exit 64
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
    *.iso)  cat "$IMG" ;;
    *.xz)   xz -dc --threads=0 "$IMG" ;;
    *.gz)   gzip -dc "$IMG" ;;
    *.bz2)  bzip2 -dc "$IMG" ;;
    *.zst)  zstd -dc "$IMG" ;;
    *)      err "Unsupported extension. Use .img, .iso, .xz, .gz, .bz2, or .zst"; return 1 ;;
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

if find_partitions_for_pi_staging "$DEV"; then
  DETECTED_PI_LAYOUT=1
  SUMMARY_PI_LAYOUT="yes"
  SUMMARY_LAYOUT_DETAIL="boot=${DETECTED_PI_BOOT_PART:-?} (${DETECTED_PI_BOOT_FSTYPE:-?}), root=${DETECTED_PI_ROOT_PART:-?} (${DETECTED_PI_ROOT_FSTYPE:-?})"
  ok "Detected Pi layout: yes (boot=${DETECTED_PI_BOOT_PART:-?}, root=${DETECTED_PI_ROOT_PART:-?})"
else
  DETECTED_PI_LAYOUT=0
  SUMMARY_PI_LAYOUT="no"
  SUMMARY_LAYOUT_DETAIL="Pi-style boot/root partitions not detected on $DEV"
  warn "Detected Pi layout: no"
fi

# ---------- expand rootfs ----------
if (( EXPAND )); then
  ok "Expanding root partition (when safe)…"
  EXPAND_PART=""
  EXPAND_FS=""

  if (( DETECTED_PI_LAYOUT )) && [[ -n "$DETECTED_PI_ROOT_PART" ]]; then
    EXPAND_PART="$DETECTED_PI_ROOT_PART"
    EXPAND_FS="$DETECTED_PI_ROOT_FSTYPE"
  elif find_largest_linux_fs_partition "$DEV"; then
    EXPAND_PART="$DETECTED_LINUX_PART"
    EXPAND_FS="$DETECTED_LINUX_FSTYPE"
  fi

  if [[ -z "$EXPAND_PART" ]]; then
    warn "No linux root-like partition found; skipping expand."
  elif [[ ! "$EXPAND_FS" =~ ^ext(2|3|4)$ ]]; then
    warn "Partition $EXPAND_PART is $EXPAND_FS; auto-expand supports ext2/3/4 only. Skipping."
  elif ! command -v growpart >/dev/null 2>&1; then
    warn "growpart not found; skipping expand (install cloud-guest-utils to enable)."
  else
    PART_NUM="$(partition_number_from_path "$EXPAND_PART" || true)"
    if [[ -z "$PART_NUM" ]]; then
      warn "Could not determine partition number for $EXPAND_PART; skipping expand."
    else
      run growpart "$DEV" "$PART_NUM"
      run e2fsck -f "$EXPAND_PART"
      run resize2fs "$EXPAND_PART"
      ok "Expanded $EXPAND_PART."
    fi
  fi
fi

# ---------- headless Wi-Fi + SSH ----------
if (( HEADLESS )); then
  if (( !DETECTED_PI_LAYOUT )); then
    warn "Headless staging requested, but target image does not look like a Raspberry Pi boot/root layout; skipping staging."
    SUMMARY_BOOT_CFG="skipped (non-Pi layout)"
    SUMMARY_CMDLINE="skipped (non-Pi layout)"
    SUMMARY_SSH_TRIGGER="skipped (non-Pi layout)"
    SUMMARY_WIFI_PROFILE="skipped (non-Pi layout)"
    SUMMARY_COUNTRY_TRIGGER="skipped (non-Pi layout)"
    SUMMARY_USER_TRIGGER="skipped (non-Pi layout)"
    SUMMARY_WIFI_SYMLINKS="skipped (non-Pi layout)"
    SUMMARY_USER_SYMLINKS="skipped (non-Pi layout)"
  else
  ok "Injecting SSH + Wi-Fi (SSID='$SSID', Country='$COUNTRY', Hidden=$HIDDEN)…"
  BOOT_PART="$DETECTED_PI_BOOT_PART"
  ROOT_PART="$DETECTED_PI_ROOT_PART"
  if [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]]; then
    warn "Detected Pi partitions are not block devices; skipping headless staging."
    SUMMARY_SSH_TRIGGER="skipped (invalid partitions)"
    SUMMARY_WIFI_PROFILE="skipped (invalid partitions)"
    SUMMARY_COUNTRY_TRIGGER="skipped (invalid partitions)"
    SUMMARY_USER_TRIGGER="skipped (invalid partitions)"
    SUMMARY_WIFI_SYMLINKS="skipped (invalid partitions)"
    SUMMARY_USER_SYMLINKS="skipped (invalid partitions)"
    SUMMARY_BOOT_CFG="skipped (invalid partitions)"
    SUMMARY_CMDLINE="skipped (invalid partitions)"
  else
  MNT_BOOT="/mnt/flash-boot.$$"; MNT_ROOT="/mnt/flash-root.$$"
  mkdir -p "$MNT_BOOT" "$MNT_ROOT"
  run mount "$BOOT_PART" "$MNT_BOOT"

  SPI_CFG=""
  if resolve_boot_paths "$MNT_BOOT" "config"; then
    SPI_CFG="$BOOT_CONFIG"
    [[ "$SUMMARY_BOOT_CFG" == "not touched" ]] && SUMMARY_BOOT_CFG="$BOOT_CONFIG"
    [[ -n "$BOOT_CMDLINE" && "$SUMMARY_CMDLINE" == "not touched" ]] && SUMMARY_CMDLINE="$BOOT_CMDLINE"
  else
    [[ "$SUMMARY_BOOT_CFG" == "not touched" ]] && SUMMARY_BOOT_CFG="not found"
  fi

  SSH_STAGED=0
  if touch "$MNT_BOOT/ssh"; then
    SSH_STAGED=1
    summary_add_file "$MNT_BOOT/ssh"
  fi
  if [[ -d "$MNT_BOOT/firmware" ]]; then
    if touch "$MNT_BOOT/firmware/ssh"; then
      SSH_STAGED=1
      summary_add_file "$MNT_BOOT/firmware/ssh"
    fi
  fi
  if (( SSH_STAGED )); then
    SUMMARY_SSH_TRIGGER="yes"
    ok "SSH trigger staged on boot partition"
  else
    SUMMARY_SSH_TRIGGER="no"
    warn "SSH trigger could not be staged"
  fi

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
  summary_add_file "$MNT_BOOT/wpa_supplicant.conf"
  summary_add_line "$MNT_BOOT/wpa_supplicant.conf" "country=$COUNTRY"
  summary_add_line "$MNT_BOOT/wpa_supplicant.conf" "ssid=<provided>"
  summary_add_line "$MNT_BOOT/wpa_supplicant.conf" "psk=<redacted>"

  # Enable SPI (best effort; safe to skip on non-Pi images).
  if [[ -n "$SPI_CFG" ]]; then
    summary_add_file "$SPI_CFG"
    if grep -qE '^[[:space:]]*dtparam=spi=on([[:space:]]|,|$)' "$SPI_CFG"; then
      ok "SPI already enabled (dtparam=spi=on)"
      summary_add_line "$SPI_CFG" "dtparam=spi=on"
    elif grep -qE '^[[:space:]]*dtparam=spi=' "$SPI_CFG"; then
      if sed -i -E 's/^[[:space:]]*dtparam=spi=.*/dtparam=spi=on/' "$SPI_CFG"; then
        ok "SPI enabled (dtparam=spi=on)"
        summary_add_line "$SPI_CFG" "dtparam=spi=on"
      else
        err "SPI enable failed while updating $SPI_CFG; continuing."
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
        summary_add_line "$SPI_CFG" "dtparam=spi=on"
      else
        err "SPI enable failed while updating $SPI_CFG; continuing."
      fi
      rm -f "$TMP_SPI"
    fi
  else
    ok "SPI config.txt not found under $MNT_BOOT (skipping SPI enable)"
  fi

  # Also seed NetworkManager so Kali definitely connects
  run mount "$ROOT_PART" "$MNT_ROOT"
  if is_raspbian_root "$MNT_ROOT"; then
    ok "Detected Raspberry Pi OS style rootfs; using firstboot-user service staging."
  fi
  # Persist regdom in rootfs (not just /boot).
  ensure_root_wpa_country "$MNT_ROOT" "$COUNTRY"
  ensure_root_crda_regdomain "$MNT_ROOT" "$COUNTRY"
  summary_add_file "$MNT_ROOT/etc/wpa_supplicant/wpa_supplicant.conf"
  summary_add_line "$MNT_ROOT/etc/wpa_supplicant/wpa_supplicant.conf" "country=$COUNTRY"
  if [[ -f "$MNT_ROOT/etc/default/crda" ]]; then
    summary_add_file "$MNT_ROOT/etc/default/crda"
    summary_add_line "$MNT_ROOT/etc/default/crda" "REGDOMAIN=$COUNTRY"
  fi

  # Stage a first-boot country/regdom applier (best effort; safe on non-systemd images).
  ok "Staging first-boot Wi-Fi country applier…"
  WIFI_TRIGGER_STAGED=0
  if {
    echo "COUNTRY=\"$COUNTRY\""
  } >"$MNT_BOOT/wificountry"; then
    WIFI_TRIGGER_STAGED=1
    summary_add_file "$MNT_BOOT/wificountry"
  fi
  if [[ -d "$MNT_BOOT/firmware" ]]; then
    if {
      echo "COUNTRY=\"$COUNTRY\""
    } >"$MNT_BOOT/firmware/wificountry"; then
      WIFI_TRIGGER_STAGED=1
      summary_add_file "$MNT_BOOT/firmware/wificountry"
    fi
  fi
  if (( WIFI_TRIGGER_STAGED )); then
    SUMMARY_COUNTRY_TRIGGER="yes"
    ok "Wi-Fi country trigger staged"
    if [[ -f "$MNT_BOOT/wificountry" ]]; then
      summary_add_line "$MNT_BOOT/wificountry" "COUNTRY=$COUNTRY"
    fi
    if [[ -f "$MNT_BOOT/firmware/wificountry" ]]; then
      summary_add_line "$MNT_BOOT/firmware/wificountry" "COUNTRY=$COUNTRY"
    fi
  else
    SUMMARY_COUNTRY_TRIGGER="no"
    warn "Wi-Fi country trigger could not be staged"
  fi
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
  summary_add_file "$MNT_ROOT/usr/local/sbin/apply-wificountry.sh"

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
  summary_add_file "$MNT_ROOT/etc/systemd/system/apply-wificountry.service"
  WIFI_SYMLINKS_OK=1
  if ! enable_service_offline "$MNT_ROOT" "apply-wificountry.service" "network-pre.target"; then
    WIFI_SYMLINKS_OK=0
  fi
  if ! enable_service_offline "$MNT_ROOT" "apply-wificountry.service" "multi-user.target"; then
    WIFI_SYMLINKS_OK=0
  fi
  if (( WIFI_SYMLINKS_OK )); then
    SUMMARY_WIFI_SYMLINKS="yes"
    ok "apply-wificountry.service symlink-enabled offline"
  else
    SUMMARY_WIFI_SYMLINKS="no"
    warn "apply-wificountry.service symlink fallback failed"
  fi
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
  chown 0:0 "$NM" 2>/dev/null || true
  chmod 600 "$NM"
  SUMMARY_WIFI_PROFILE="yes"
  summary_add_file "$NM"
  summary_add_line "$NM" "type=wifi"
  summary_add_line "$NM" "ssid=<provided>"
  summary_add_line "$NM" "psk=<redacted>"

  # ---------- first-boot user creation (optional) ----------
  if [[ -n "$USER_NAME" && -n "$USER_PASS" ]]; then
    ok "Seeding first-boot user creation for '$USER_NAME'…"
    # drop a one-shot service + script
    mkdir -p "$MNT_ROOT/usr/local/sbin" "$MNT_ROOT/etc/systemd/system"
    rm -f "$MNT_BOOT/failed_userconf" "$MNT_BOOT/firmware/failed_userconf" 2>/dev/null || true
    cat > "$MNT_ROOT/usr/local/sbin/apply-userconf.sh" <<'EOS'
#!/bin/bash
set -o pipefail

CONF=""
for p in /boot/firstboot-user /boot/firmware/firstboot-user; do
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

USER_NAME=""
USER_PASS=""
# shellcheck disable=SC1090
source "$CONF" >/dev/null 2>&1 || true
user="${USER_NAME:-}"
pass="${USER_PASS:-}"

if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  cleanup
  exit 0
fi

if command -v id >/dev/null 2>&1 && id "$user" >/dev/null 2>&1; then
  :
else
  if command -v useradd >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$user" >/dev/null 2>&1 || true
  elif command -v adduser >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$user" >/dev/null 2>&1 || true
  fi
fi

if [[ -n "$pass" ]] && command -v chpasswd >/dev/null 2>&1; then
  printf '%s:%s\n' "$user" "$pass" | chpasswd >/dev/null 2>&1 || true
fi

if command -v getent >/dev/null 2>&1 && getent group sudo >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
  usermod -aG sudo "$user" >/dev/null 2>&1 || true
fi
if command -v usermod >/dev/null 2>&1; then
  usermod -aG plugdev,adm,video,audio,netdev "$user" >/dev/null 2>&1 || true
fi
# enable ssh permanently (if image uses ssh service)
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable ssh >/dev/null 2>&1 || true
fi

cleanup
exit 0
EOS
    chmod 755 "$MNT_ROOT/usr/local/sbin/apply-userconf.sh"
    summary_add_file "$MNT_ROOT/usr/local/sbin/apply-userconf.sh"

    cat > "$MNT_ROOT/etc/systemd/system/apply-userconf.service" <<'EOS'
[Unit]
Description=Apply first-boot user configuration
After=local-fs.target
ConditionPathExists=|/boot/firstboot-user
ConditionPathExists=|/boot/firmware/firstboot-user

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-userconf.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOS
    summary_add_file "$MNT_ROOT/etc/systemd/system/apply-userconf.service"
    USER_TRIGGER_STAGED=0
    if {
      printf 'USER_NAME=%q\n' "$USER_NAME"
      printf 'USER_PASS=%q\n' "$USER_PASS"
    } > "$MNT_BOOT/firstboot-user"; then
      USER_TRIGGER_STAGED=1
      summary_add_file "$MNT_BOOT/firstboot-user"
    fi
    if [[ -d "$MNT_BOOT/firmware" ]]; then
      if {
        printf 'USER_NAME=%q\n' "$USER_NAME"
        printf 'USER_PASS=%q\n' "$USER_PASS"
      } > "$MNT_BOOT/firmware/firstboot-user"; then
        USER_TRIGGER_STAGED=1
        summary_add_file "$MNT_BOOT/firmware/firstboot-user"
      fi
    fi
    if (( USER_TRIGGER_STAGED )); then
      SUMMARY_USER_TRIGGER="yes"
      ok "First-boot user trigger staged"
      if [[ -f "$MNT_BOOT/firstboot-user" ]]; then
        summary_add_line "$MNT_BOOT/firstboot-user" "USER_NAME=$USER_NAME"
        summary_add_line "$MNT_BOOT/firstboot-user" "USER_PASS=<redacted>"
      fi
      if [[ -f "$MNT_BOOT/firmware/firstboot-user" ]]; then
        summary_add_line "$MNT_BOOT/firmware/firstboot-user" "USER_NAME=$USER_NAME"
        summary_add_line "$MNT_BOOT/firmware/firstboot-user" "USER_PASS=<redacted>"
      fi
    else
      SUMMARY_USER_TRIGGER="no"
      warn "First-boot user trigger could not be staged"
    fi
    if enable_service_offline "$MNT_ROOT" "apply-userconf.service" "multi-user.target"; then
      SUMMARY_USER_SYMLINKS="yes"
      ok "apply-userconf.service symlink-enabled offline"
    else
      SUMMARY_USER_SYMLINKS="no"
      warn "apply-userconf.service symlink fallback failed"
    fi
    chroot "$MNT_ROOT" systemctl enable apply-userconf.service >/dev/null 2>&1 || true
  else
    SUMMARY_USER_TRIGGER="not requested"
    SUMMARY_USER_SYMLINKS="not requested"
  fi

  sync
  run umount "$MNT_ROOT" || true
  run umount "$MNT_BOOT" || true
  rmdir "$MNT_ROOT" "$MNT_BOOT" || true
  ok "Headless + (optional) user setup staged."
fi
  fi
fi

# ---------- optional USB gadget mode ----------
if (( GADGET )); then
  if (( !DETECTED_PI_LAYOUT )); then
    warn "USB gadget staging requested, but target image does not look like a Raspberry Pi boot/root layout; skipping staging."
    SUMMARY_GADGET_STATUS="disabled (non-Pi layout)"
    SUMMARY_GADGET_NETWORK="not staged (non-Pi layout)"
    SUMMARY_GADGET_NOTE="gadget staging skipped because Pi boot/root partitions were not detected."
    [[ "$SUMMARY_BOOT_CFG" == "not touched" ]] && SUMMARY_BOOT_CFG="skipped (non-Pi layout)"
    [[ "$SUMMARY_CMDLINE" == "not touched" ]] && SUMMARY_CMDLINE="skipped (non-Pi layout)"
  else
    ok "Staging USB gadget mode (dwc2 + g_ether + usb0 static IP)…"
    BOOT_PART="$DETECTED_PI_BOOT_PART"
    ROOT_PART="$DETECTED_PI_ROOT_PART"
    if [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]]; then
      warn "Detected Pi partitions are not block devices; skipping gadget staging."
      SUMMARY_GADGET_STATUS="disabled (invalid partitions)"
      SUMMARY_GADGET_NETWORK="not staged (invalid partitions)"
      [[ "$SUMMARY_BOOT_CFG" == "not touched" ]] && SUMMARY_BOOT_CFG="skipped (invalid partitions)"
      [[ "$SUMMARY_CMDLINE" == "not touched" ]] && SUMMARY_CMDLINE="skipped (invalid partitions)"
    else
      MNT_BOOT="/mnt/flash-boot-gadget.$$"
      MNT_ROOT="/mnt/flash-root-gadget.$$"
      GADGET_CFG=""
      GADGET_CMDLINE=""
      NEED_GADGET_FALLBACK=0
      GADGET_READY=0

      mkdir -p "$MNT_BOOT" "$MNT_ROOT"
      run mount "$BOOT_PART" "$MNT_BOOT"

      if resolve_boot_paths "$MNT_BOOT" "both"; then
        GADGET_CFG="$BOOT_CONFIG"
        GADGET_CMDLINE="$BOOT_CMDLINE"
        SUMMARY_BOOT_CFG="$GADGET_CFG"
        SUMMARY_CMDLINE="$GADGET_CMDLINE"
        summary_add_file "$GADGET_CFG"
        summary_add_file "$GADGET_CMDLINE"
      else
        [[ "$SUMMARY_BOOT_CFG" == "not touched" ]] && SUMMARY_BOOT_CFG="not found"
        [[ "$SUMMARY_CMDLINE" == "not touched" ]] && SUMMARY_CMDLINE="not found"
        NEED_GADGET_FALLBACK=1
      fi

      if [[ -n "$GADGET_CFG" ]]; then
        if ensure_top_level_dwc2_overlay "$GADGET_CFG"; then
          ok "USB gadget overlay staged in $GADGET_CFG"
          summary_add_line "$GADGET_CFG" "dtoverlay=dwc2"
        else
          rc=$?
          if (( rc == 1 )); then
            ok "USB gadget overlay already present in $GADGET_CFG"
            summary_add_line "$GADGET_CFG" "dtoverlay=dwc2"
          else
            warn "Could not update USB gadget config: $GADGET_CFG"
            NEED_GADGET_FALLBACK=1
          fi
        fi
      fi

      if [[ -n "$GADGET_CMDLINE" ]]; then
        if ensure_cmdline_gadget_modules "$GADGET_CMDLINE"; then
          ok "USB gadget modules staged in $GADGET_CMDLINE"
          summary_add_line "$GADGET_CMDLINE" "modules-load=dwc2,g_ether"
        else
          ok "USB gadget modules already present in $GADGET_CMDLINE"
          summary_add_line "$GADGET_CMDLINE" "modules-load=dwc2,g_ether"
        fi
        if ! cmdline_has_gadget_modules "$GADGET_CMDLINE"; then
          NEED_GADGET_FALLBACK=1
        fi
      fi

      run mount "$ROOT_PART" "$MNT_ROOT"
      stage_usb0_network_config "$MNT_ROOT"

      if (( NEED_GADGET_FALLBACK )); then
        ok "Staging USB gadget fallback service…"
        stage_usb_gadget_fallback_service "$MNT_ROOT"
        SUMMARY_GADGET_NOTE="Fallback systemd service staged to modprobe dwc2/g_ether at first boot."
      fi

      if [[ -n "$GADGET_CFG" && -n "$GADGET_CMDLINE" ]] \
        && config_has_dwc2_overlay "$GADGET_CFG" \
        && cmdline_has_gadget_modules "$GADGET_CMDLINE"; then
        GADGET_READY=1
      fi

      if (( GADGET_READY )); then
        SUMMARY_GADGET_STATUS="enabled"
        ok "USB gadget enabled (dwc2 + g_ether)"
      else
        SUMMARY_GADGET_STATUS="disabled"
        warn "USB gadget staging incomplete; host usb0 detection may fail."
      fi

      sync
      run umount "$MNT_ROOT" || true
      run umount "$MNT_BOOT" || true
      rmdir "$MNT_ROOT" "$MNT_BOOT" || true
    fi
  fi
else
  SUMMARY_GADGET_STATUS="disabled"
  SUMMARY_GADGET_NETWORK="not staged (option disabled)"
fi

# ---------- optional quick verification ----------
if (( VERIFY )); then
  ok "Verifying first 16 MiB…"
  decompress | dd bs=1M count=16 status=none | sha256sum | awk '{print "[img:first16MiB] " $1}'
  dd if="$DEV" bs=1M count=16 status=none | sha256sum | awk '{print "[dev:first16MiB] " $1}'
fi

print_post_flash_summary

ok "sync + safe eject hint:"
say "  sync && eject $DEV"
say "[done]"
