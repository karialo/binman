#!/usr/bin/env bash
#
# wscan.sh - Portable wireless scanner (Bash Master style)
#
# Usage: ./wscan.sh [--interface IFACE] [--backend nmcli|iw|iwlist|auto]
#                   [--format table|csv|json] [--verbose] [--quiet] [--no-color]
#                   [--strict] [-h|--help]
#
# Behavior:
#  - Tries nmcli (no root usually), then iw (may require sudo), then iwlist.
#  - Runs as normal user; will prompt and elevate only the minimal scan step when required.
#  - Uses fzf for interactive interface selection if available, otherwise a simple menu.
#
set -Euo pipefail
IFS=$'\n\t'

# -------------------------
# Basic config & colors
# -------------------------
PROGNAME=$(basename "$0")
VERSION="1.0"
COLOR=true
VERBOSE=0
QUIET=0
STRICT=false
BACKEND="auto"
FORMAT="table"
IFACE=""
USE_FZF=true

# table column widths (adjust if you like)
W_SSID=24
W_BSSID=17
W_CH=3
W_FREQ=6
W_SIG=5
W_RATE=6
W_SEC=10

# -------------------------
# Error handling
# -------------------------
on_error() {
    local rc=$?
    local cmd="${BASH_COMMAND:-unknown}"
    local lineno="${1:-unknown}"
    echo
    printf 'ERROR: command [%s] failed with exit code %d at line %s\n' "$cmd" "$rc" "$lineno" >&2
    if [[ "$STRICT" == "true" ]]; then
        exit "$rc"
    else
        return "$rc"
    fi
}
trap 'on_error ${LINENO}' ERR

# -------------------------
# Helpers
# -------------------------
die() {
    echo "FATAL: $*" >&2
    exit 1
}

log() {
    (( VERBOSE )) && echo "[debug] $*" >&2
}

info() {
    (( QUIET )) || echo "$@"
}

warn() {
    printf '\e[33mWARN:\e[0m %s\n' "$*" >&2
}

# color wrappers
if ! command -v tput >/dev/null 2>&1; then
    COLOR=false
fi

c_reset() { (( COLOR )) && printf '\e[0m' || true; }
c_bold()  { (( COLOR )) && printf '\e[1m' || true; }
c_green() { (( COLOR )) && printf '\e[32m' || true; }
c_cyan()  { (( COLOR )) && printf '\e[36m' || true; }

color_wrap() {
    local col="$1"; shift
    if [[ "$COLOR" == true ]]; then
        case "$col" in
            green) printf '\e[32m%s\e[0m' "$*";;
            cyan)  printf '\e[36m%s\e[0m' "$*";;
            bold)  printf '\e[1m%s\e[0m' "$*";;
            *) printf '%s' "$*";;
        esac
    else
        printf '%s' "$*"
    fi
}

# safe run to check commands
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# convert dBm to percent (approx)
dbm_to_pct() {
    # clamp -100..-30 -> 0..100
    local dbm=${1%%.*}
    if [[ -z "$dbm" ]]; then echo "0"; return; fi
    if (( dbm <= -100 )); then echo 0; return; fi
    if (( dbm >= -30 )); then echo 100; return; fi
    # linear map
    local pct=$(( (dbm + 100) * 100 / 70 ))
    echo "$pct"
}

# pad/trim a field to width
fmt_field() {
    local val="$1"; local width="$2"
    # replace newlines and trim
    val="${val//$'\n'/ }"
    if (( ${#val} > width )); then
        printf '%s' "${val:0:width-1}…"
    else
        printf '%-*s' "$width" "$val"
    fi
}

# -------------------------
# CLI parsing
# -------------------------
print_help() {
    cat <<EOF
$PROGNAME $VERSION
Portable wireless scanner.

Usage: $PROGNAME [options]

Options:
  -i, --interface IFACE     Use interface IFACE (e.g. wlan0)
  -b, --backend BACKEND     Backend: nmcli | iw | iwlist | auto (default auto)
  -f, --format FORMAT       Output: table | csv | json (default table)
      --no-color            Disable color output
      --verbose             Verbose debug logging
      --quiet               Minimal output (no header)
      --strict              Fail-fast on errors
  -h, --help                Show this help and exit

Examples:
  $PROGNAME
  $PROGNAME --interface wlan0 --backend iw
  $PROGNAME --format json --no-color
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) print_help ;;
        --version) echo "$VERSION"; exit 0 ;;
        -i|--interface) IFACE="${2:-}"; shift 2 ;;
        --interface=*) IFACE="${1#*=}"; shift ;;
        -b|--backend) BACKEND="${2:-}"; shift 2 ;;
        --backend=*) BACKEND="${1#*=}"; shift ;;
        -f|--format) FORMAT="${2:-}"; shift 2 ;;
        --format=*) FORMAT="${1#*=}"; shift ;;
        --no-color) COLOR=false; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --strict) STRICT=true; shift ;;
        --no-fzf) USE_FZF=false; shift ;;
        *) die "Unknown arg: $1";;
    esac
done

# -------------------------
# Dependency hints (for user when missing)
# -------------------------
pkg_hint() {
    local pkg="$1"
    cat <<EOF
Install hint for: $pkg

Common packages per distro:
  Debian/Ubuntu: sudo apt install $pkg
  Fedora:        sudo dnf install $pkg
  Arch:          sudo pacman -S $pkg
  openSUSE:      sudo zypper in $pkg
  Alpine:        sudo apk add $pkg
  macOS (brew):  brew install $pkg

EOF
}

# -------------------------
# Detect interfaces
# -------------------------
list_wireless_ifaces() {
    local -a ifs=()
    local line iface path

    if has_cmd ip; then
        while IFS= read -r line; do
            iface=${line#*: }
            iface=${iface%%:*}
            iface=${iface%%@*}
            [[ -n "$iface" ]] || continue
            if [[ -d "/sys/class/net/$iface/wireless" || -d "/sys/class/net/$iface/phy80211" ]]; then
                ifs+=("$iface")
            fi
        done < <(ip -o link show 2>/dev/null)
    fi

    if (( ${#ifs[@]} == 0 )); then
        for path in /sys/class/net/*; do
            [[ -e "$path" ]] || continue
            iface=${path##*/}
            [[ -n "$iface" ]] || continue
            if [[ -d "$path/wireless" || -d "$path/phy80211" ]]; then
                ifs+=("$iface")
            fi
        done
    fi

    if (( ${#ifs[@]} )); then
        local -A seen=()
        for iface in "${ifs[@]}"; do
            [[ -n "$iface" ]] || continue
            if [[ -z "${seen[$iface]+x}" ]]; then
                seen[$iface]=1
                printf '%s\n' "$iface"
            fi
        done
    fi
}

# interactive selection
choose_interface() {
    local ifs
    mapfile -t ifs < <(list_wireless_ifaces)
    if (( ${#ifs[@]} == 0 )); then
        printf '%s\n' "No wireless interfaces detected." >&2
        exit 1
    fi

    if [[ -n "$IFACE" ]]; then
        for i in "${ifs[@]}"; do
            if [[ "$i" == "$IFACE" ]]; then
                printf '%s' "$IFACE"
                return
            fi
        done
        warn "Interface '$IFACE' not found among: ${ifs[*]}. Will still try if present."
        printf '%s' "$IFACE"
        return
    fi

    if (( ${#ifs[@]} == 1 )); then
        printf '%s' "${ifs[0]}"
        return
    fi

    if $USE_FZF && has_cmd fzf; then
        local selection
        selection=$(printf '%s\n' "${ifs[@]}" | fzf --prompt="Select wireless interface> " --height=10 --exit-0 2>/dev/null) || true
        selection=${selection//$'\r'/}
        selection=${selection%%$'\n'*}
        if [[ -n "$selection" ]]; then
            printf '%s' "$selection"
            return
        fi
    fi

    echo "Available wireless interfaces:"
    local idx=1
    for i in "${ifs[@]}"; do
        printf "  %2d) %s\n" "$idx" "$i"
        ((idx++))
    done
    printf "Choose [1-%d]: " "${#ifs[@]}"
    read -r choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ifs[@]} )); then
        die "Invalid selection"
    fi
    printf '%s' "${ifs[choice-1]}"
}

# -------------------------
# Backend probes & scanner impl
# -------------------------
# nmcli scanner (preferred if available)
scan_with_nmcli() {
    local iface="$1"
    local raw
    info "$(color_wrap cyan 'Using nmcli backend')"
    if ! has_cmd nmcli; then
        return 2
    fi

    # nmcli can list wifi without sudo
    # format fields: SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY,RATE
    # RATE may not be present everywhere; we'll include it if nmcli supports it.
    # Use terse output
    if ! raw=$(nmcli -f SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname "$iface" 2>/dev/null); then
        # sometimes nmcli requires root to show all scan results depending on NM config
        return 3
    fi

    # parse header-aware: skip header line, then parse whitespace separated columns
    # nmcli prints aligned columns, so use awk to extract columns by position.
    # We'll be conservative and parse via regex per-line.
    local lines
    mapfile -t lines < <(printf '%s\n' "$raw" | sed '/^$/d' | sed '1d')
    local out=()
    for ln in "${lines[@]}"; do
        # collapse multiple spaces, then split - but SSID may contain spaces; nmcli aligns columns.
        # Approach: use cut by columns based on header positions.
        # Extract by positions from header
        # Fallback: try nmcli -t (colon separated)
        :
    done

    # Better: use nmcli -t (colon-separated) for robust parsing
    if ! raw=$(nmcli -t -f SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname "$iface" 2>/dev/null); then
        return 3
    fi

    # lines like: SSID:BSSID:CHAN:FREQ:SIGNAL:SECURITY
    local -a rows=()
    while IFS= read -r line; do
        # skip empty or header-like lines
        [[ -z "$line" ]] && continue
        # handle fields safely
        IFS=':' read -r ssid bssid chan freq signal security <<< "$line"
        ssid="${ssid:-<hidden>}"
        bssid="${bssid:-00:00:00:00:00:00}"
        chan="${chan:-?}"
        freq="${freq:-?}"
        signal="${signal:-0}"
        # nmcli doesn't provide rate in -t output reliably; leave blank
        rate=""
        rows+=("$ssid|$bssid|$chan|$freq|$signal|$rate|$security")
    done <<< "$raw"

    printf '%s\n' "${rows[@]}"
    return 0
}

# iw scanner (requires sudo for scan in many setups)
scan_with_iw() {
    local iface="$1"
    info "$(color_wrap cyan 'Using iw backend')"
    if ! has_cmd iw; then
        return 2
    fi

    # test if we can scan without root by running a small read
    local scan_cmd=("iw" "dev" "$iface" "scan")
    local raw
    if ! raw=$("${scan_cmd[@]}" 2>/dev/null); then
        # try with sudo (only elevate the scan action)
        info "Elevated scan required. Will prompt for sudo to run: ${scan_cmd[*]}"
        if has_cmd sudo; then
            if ! raw=$(sudo "${scan_cmd[@]}" 2>/dev/null); then
                return 3
            fi
        else
            die "sudo not found; cannot perform privileged 'iw' scan. Install sudo or run as root."
        fi
    fi

    # Parse iw output. Blocks start with "BSS <mac> ...", followed by lines with SSID:, signal:, freq:
    # We'll iterate lines and capture entries.
    local mac="" ssid="" signal="" freq="" chan="" maxrate="" security=""
    local -a rows=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^BSS\ ([0-9a-fA-F:]{17})\ .* ]]; then
            # flush previous if any
            if [[ -n "$mac" ]]; then
                rows+=("$ssid|$mac|$chan|$freq|$signal|$maxrate|$security")
            fi
            mac="${BASH_REMATCH[1]}"
            ssid=""
            signal=""
            freq=""
            chan=""
            maxrate=""
            security=""
            continue
        fi
        # trim leading spaces
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            SSID:\ *)
                ssid="${line#SSID: }"
                ;;
            signal:\ *)
                # e.g. signal: -51.00 dBm
                signal_val=$(awk '{printf "%d", $2}' <<< "${line}")
                signal="$signal_val"
                ;;
            freq:\ *)
                freq="${line#freq: }"
                ;;
            primary\ channel\ *)
                chan="${line#primary channel }"
                ;;
            *RSN:*|*WPA:*|IE:*)
                # try to detect security indicators
                if [[ "$line" =~ WPA|RSN|WPA2|WPA3 ]]; then
                    security="WPA"
                fi
                ;;
            *bitrate*|*tx\ bitrate*|*tx\ bitrate:* )
                # e.g. tx bitrate: 6.0 MBit/s
                if [[ "$line" =~ ([0-9]+(\.[0-9]+)?)\ MBit/s ]]; then
                    maxrate="${BASH_REMATCH[1]}M"
                fi
                ;;
        esac
    done <<< "$raw"

    # flush last
    if [[ -n "$mac" ]]; then
        rows+=("$ssid|$mac|$chan|$freq|$signal|$maxrate|$security")
    fi

    # fallback: if no rows, signal a failure
    if (( ${#rows[@]} == 0 )); then
        return 4
    fi

    printf '%s\n' "${rows[@]}"
    return 0
}

# iwlist scanner (older tool)
scan_with_iwlist() {
    local iface="$1"
    info "$(color_wrap cyan 'Using iwlist backend')"
    if ! has_cmd iwlist; then
        return 2
    fi

    local raw
    if ! raw=$(iwlist "$iface" scanning 2>/dev/null); then
        # try sudo
        if has_cmd sudo; then
            info "Elevated scan required. Will prompt for sudo to run iwlist."
            if ! raw=$(sudo iwlist "$iface" scanning 2>/dev/null); then
                return 3
            fi
        else
            die "sudo required for iwlist scanning but not available."
        fi
    fi

    # parse: look for "Cell XX - Address: <mac>" and then lines with ESSID, Frequency, Quality
    local -a rows=()
    local mac ssid freq sig quality security
    mac=""; ssid=""; freq=""; sig=""; quality=""; security=""
    while IFS= read -r line; do
        if [[ "$line" =~ Address:\ ([0-9A-Fa-f:]{17}) ]]; then
            if [[ -n "$mac" ]]; then
                rows+=("$ssid|$mac|${freq:-?}|${freq:-?}|${sig:-?}| |${security:-}")
            fi
            mac="${BASH_REMATCH[1]}"
            ssid=""; freq=""; sig=""; quality=""; security=""
            continue
        fi
        if [[ "$line" =~ ESSID:\"(.*)\" ]]; then
            ssid="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ Frequency:([0-9.]+)\ GHz ]]; then
            # convert GHz to MHz
            freq_mhz=$(awk "BEGIN{printf \"%d\", ${BASH_REMATCH[1]}*1000}")
            freq="$freq_mhz"
            continue
        fi
        if [[ "$line" =~ Quality=([0-9]+)/([0-9]+) ]]; then
            local q="${BASH_REMATCH[1]}"; local qmax="${BASH_REMATCH[2]}"
            sig=$(( q * 100 / qmax ))
            continue
        fi
        if [[ "$line" =~ Encryption\ key:off ]]; then
            security="OPEN"
        elif [[ "$line" =~ WPA|WPA2|WEP ]]; then
            security="WPA"
        fi
    done <<< "$raw"

    if [[ -n "$mac" ]]; then
        rows+=("$ssid|$mac|${freq:-?}|${freq:-?}|${sig:-?}| |${security:-}")
    fi

    if (( ${#rows[@]} == 0 )); then
        return 4
    fi

    printf '%s\n' "${rows[@]}"
    return 0
}

# -------------------------
# Formatters
# -------------------------
print_table() {
    local -a rows=("$@")
    local count=${#rows[@]}

    # header box
    if (( QUIET == 0 )); then
        local header="| Interface: ${IFACE:-?} | Backend: ${BACKEND_USED:-?} | Found: ${count} networks |"
        local border_len=${#header}
        printf '%s\n' "$(printf '+%0.s-' $(seq 1 $((border_len-2))))"
        printf '%s\n' "$header"
        printf '%s\n' "$(printf '+%0.s-' $(seq 1 $((border_len-2))))"
        echo
    fi

    # table heading
    printf '+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+\n' \
        "$(printf '%0.s-' $(seq 1 $W_SSID))" \
        "$(printf '%0.s-' $(seq 1 $W_BSSID))" \
        "$(printf '%0.s-' $(seq 1 $W_CH))" \
        "$(printf '%0.s-' $(seq 1 $W_FREQ))" \
        "$(printf '%0.s-' $(seq 1 $W_SIG))" \
        "$(printf '%0.s-' $(seq 1 $W_RATE))" \
        "$(printf '%0.s-' $(seq 1 $W_SEC))"
    printf '| %-'"$W_SSID"'s | %-'"$W_BSSID"'s | %'"$W_CH"'s | %'"$W_FREQ"'s | %'"$W_SIG"'s | %'"$W_RATE"'s | %-'"$W_SEC"'s |\n' \
        "SSID" "BSSID" "CH" "FREQ" "SIG%" "RATE" "SEC"
    printf '+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+\n' \
        "$(printf '%0.s-' $(seq 1 $W_SSID))" \
        "$(printf '%0.s-' $(seq 1 $W_BSSID))" \
        "$(printf '%0.s-' $(seq 1 $W_CH))" \
        "$(printf '%0.s-' $(seq 1 $W_FREQ))" \
        "$(printf '%0.s-' $(seq 1 $W_SIG))" \
        "$(printf '%0.s-' $(seq 1 $W_RATE))" \
        "$(printf '%0.s-' $(seq 1 $W_SEC))"

    # rows
    for r in "${rows[@]}"; do
        IFS='|' read -r ssid bssid chan freq signal rate security <<< "$r"
        # normalize values
        ssid="${ssid:-<hidden>}"
        bssid="${bssid:-00:00:00:00:00:00}"
        chan="${chan:-?}"
        freq="${freq:-?}"
        signal="${signal:-0}"
        # if signal looks like dBm (neg), convert to pct
        if [[ "$signal" =~ ^-?[0-9]+$ ]] && (( signal < 0 )); then
            signal=$(dbm_to_pct "$signal")
        fi
        rate="${rate:-}"
        security="${security:-OPEN}"

        printf '| %-'"$W_SSID"'s | %-'"$W_BSSID"'s | %'"$W_CH"'s | %'"$W_FREQ"'s | %'"$W_SIG"'s | %'"$W_RATE"'s | %-'"$W_SEC"'s |\n' \
            "$(fmt_field "$ssid" "$W_SSID")" "$bssid" "$chan" "$freq" "$signal" "$rate" "$security"
    done

    printf '+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+-%s-+\n' \
        "$(printf '%0.s-' $(seq 1 $W_SSID))" \
        "$(printf '%0.s-' $(seq 1 $W_BSSID))" \
        "$(printf '%0.s-' $(seq 1 $W_CH))" \
        "$(printf '%0.s-' $(seq 1 $W_FREQ))" \
        "$(printf '%0.s-' $(seq 1 $W_SIG))" \
        "$(printf '%0.s-' $(seq 1 $W_RATE))" \
        "$(printf '%0.s-' $(seq 1 $W_SEC))"
}

print_csv() {
    local -a rows=("$@")
    echo "SSID,BSSID,CHAN,FREQ,SIGNAL,RATE,SECURITY"
    for r in "${rows[@]}"; do
        IFS='|' read -r ssid bssid chan freq signal rate security <<< "$r"
        printf '"%s","%s","%s","%s","%s","%s","%s"\n' "$ssid" "$bssid" "$chan" "$freq" "$signal" "$rate" "$security"
    done
}

print_json() {
    local -a rows=("$@")
    printf '{ "interface": "%s", "backend": "%s", "networks": [' "$IFACE" "$BACKEND_USED"
    local first=true
    for r in "${rows[@]}"; do
        IFS='|' read -r ssid bssid chan freq signal rate security <<< "$r"
        if $first; then first=false; else printf ','; fi
        printf '\n  {"ssid":%s,"bssid":%s,"chan":%s,"freq":%s,"signal":%s,"rate":%s,"security":%s}' \
            "$(jq -R <<< "$ssid")" "$(jq -R <<< "$bssid")" "$(jq -R <<< "$chan")" "$(jq -R <<< "$freq")" "$(jq -R <<< "$signal")" "$(jq -R <<< "$rate")" "$(jq -R <<< "$security")"
    done
    printf '\n] }\n'
}

# -------------------------
# Main
# -------------------------
main() {
    # choose iface
    IFACE="$(choose_interface)"
    [[ -z "$IFACE" ]] && die "No interface selected."

    # backend selection
    BACKEND_USED="$BACKEND"
    if [[ "$BACKEND" == "auto" ]]; then
        if has_cmd nmcli; then
            BACKEND_USED="nmcli"
        elif has_cmd iw; then
            BACKEND_USED="iw"
        elif has_cmd iwlist; then
            BACKEND_USED="iwlist"
        else
            die "No supported backend found. Install nmcli (NetworkManager), iw, or wireless-tools (iwlist)."
        fi
    fi

    local -a rows=()
    case "$BACKEND_USED" in
        nmcli)
            if out=$(scan_with_nmcli "$IFACE"); then
                mapfile -t rows < <(printf '%s\n' "$out")
            else
                warn "nmcli scan failed, falling back to iw..."
                BACKEND_USED="iw"
                if out=$(scan_with_iw "$IFACE"); then
                    mapfile -t rows < <(printf '%s\n' "$out")
                fi
            fi
            ;;
        iw)
            if out=$(scan_with_iw "$IFACE"); then
                mapfile -t rows < <(printf '%s\n' "$out")
            else
                warn "iw scan failed, trying iwlist..."
                if out=$(scan_with_iwlist "$IFACE"); then
                    mapfile -t rows < <(printf '%s\n' "$out")
                    BACKEND_USED="iwlist"
                fi
            fi
            ;;
        iwlist)
            if out=$(scan_with_iwlist "$IFACE"); then
                mapfile -t rows < <(printf '%s\n' "$out")
            else
                die "iwlist scan failed."
            fi
            ;;
        *)
            die "Unknown backend: $BACKEND_USED"
            ;;
    esac

    # output
    if [[ "${FORMAT}" == "csv" ]]; then
        print_csv "${rows[@]}"
        return
    elif [[ "${FORMAT}" == "json" ]]; then
        if ! has_cmd jq; then
            warn "jq not found; attempting minimal JSON (strings escaped). Install 'jq' for nicer JSON output."
        fi
        # print JSON using simple method if jq absent
        if has_cmd jq; then
            # Use jq to build JSON properly
            local tmp=$(mktemp)
            printf '%s\n' "${rows[@]}" | awk -F'|' '
                BEGIN { print "[" }
                {
                    gsub(/"/, "\\\"", $1)
                    printf "%s{\"ssid\":\"%s\",\"bssid\":\"%s\",\"chan\":\"%s\",\"freq\":\"%s\",\"signal\":\"%s\",\"rate\":\"%s\",\"security\":\"%s\"}", (NR==1?"":",\n"), $1,$2,$3,$4,$5,$6,$7
                }
                END { print "\n]" }' >"$tmp"
            printf '{ "interface":"%s","backend":"%s","networks":' "$IFACE" "$BACKEND_USED"
            cat "$tmp"
            printf ' }\n'
            rm -f "$tmp"
            return
        else
            print_json "${rows[@]}"
            return
        fi
    else
        print_table "${rows[@]}"
    fi
}

main

exit 0
