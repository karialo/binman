#!/usr/bin/env bash
# sysclean — cross-distro system janitor for BinMan
# v1.0.1 — human-readable Top N, aligned, colored; --raw to show bytes
# Safe-by-default: dry-run unless --yes is passed.

set -Eeuo pipefail
VERSION="1.0.1"

# ──────────────────────────────────────────────────────────────────────────────
# Pretty
BOLD="$(tput bold 2>/dev/null || echo)"
DIM="$(tput dim 2>/dev/null || echo)"
RESET="$(tput sgr0 2>/dev/null || echo)"
# colors (best-effort)
C_INFO="$(tput setaf 6 2>/dev/null || echo)"     # cyan
C_OK="$(tput setaf 2 2>/dev/null || echo)"       # green
C_WARN="$(tput setaf 3 2>/dev/null || echo)"     # yellow
C_ERR="$(tput setaf 1 2>/dev/null || echo)"      # red
C_PATH="$(tput setaf 4 2>/dev/null || echo)"     # blue

say()  { printf "%s\n" "$*"; }
info() { printf "%s[i]%s %s%s%s\n" "$DIM" "$RESET" "$C_INFO" "$*" "$RESET"; }
ok()   { printf "%s[✓]%s %s%s%s\n" "$BOLD" "$RESET" "$C_OK" "$*" "$RESET"; }
warn() { printf "%s[!]%s %s%s%s\n" "$BOLD" "$RESET" "$C_WARN" "$*" "$RESET"; }
err()  { printf "%s[✗]%s %s%s%s\n" "$BOLD" "$RESET" "$C_ERR" "$*" "$RESET" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# CLI
DRY_RUN=1
ASSUME_YES=0
DEEP=0
SHOW_ONLY=0
TOP_N=10
NO_PKG=0
NO_STEAM=0
HUMAN=1    # default pretty sizes; use --raw to force bytes

usage() {
  cat <<EOF
sysclean v$VERSION — cross-distro janitor

Usage: sysclean [options]
  --yes              Actually perform actions (disable dry-run)
  --dry-run          Force dry-run (default)
  --deep             Include deeper cleanups (package caches, journals, dev caches)
  --show-only        Only report; don't prompt for deletions
  --top N            Show top N files (default $TOP_N)
  --no-pkg           Skip package cache/orphan cleanups
  --no-steam         Skip Steam/Heroic/Lutris scan
  --raw              Show raw bytes instead of human-readable sizes
  --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) DRY_RUN=0; ASSUME_YES=1; shift;;
    --dry-run) DRY_RUN=1; ASSUME_YES=0; shift;;
    --deep) DEEP=1; shift;;
    --show-only) SHOW_ONLY=1; shift;;
    --top) TOP_N="${2:-10}"; shift 2;;
    --no-pkg) NO_PKG=1; shift;;
    --no-steam) NO_STEAM=1; shift;;
    --raw) HUMAN=0; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 2;;
  esac
done

confirm() {
  local prompt="$1"
  (( SHOW_ONLY )) && return 1
  (( ASSUME_YES )) && return 0
  read -r -p "$prompt [y/N]: " r
  [[ "${r,,}" == "y" || "${r,,}" == "yes" ]]
}

run() {
  if (( DRY_RUN )); then
    info "(dry-run) $*"
  else
    eval "$@"
  fi
}

need_sudo() { [[ $EUID -ne 0 ]] && echo "sudo" || true; }

# ──────────────────────────────────────────────────────────────────────────────
# Helpers: sizes
have_numfmt() { command -v numfmt >/dev/null 2>&1; }

humanize() {
  # $1=bytes → pretty (e.g., 15G)
  if have_numfmt; then
    numfmt --to=iec --suffix=B --format="%.1f" "$1" 2>/dev/null | sed 's/\.0B/B/'
  else
    # awk fallback (IEC-ish)
    awk -v b="$1" 'function hr(x){s="BKMGTPE";i=0;while(x>=1024 && i<6){x/=1024;i++}printf("%.1f%s",x,substr(s,i+1,1))} BEGIN{hr(b)}'
  fi
}

padleft() {
  # pad string $1 to width $2
  local s="$1" w="$2"
  printf "%*s" "$w" "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# Detect pkg manager
PM=""
OS="$(uname -s)"
detect_pm() {
  if command -v pacman >/dev/null 2>&1; then PM="pacman"
  elif command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then PM="apt"
  elif command -v dnf >/dev/null 2>&1; then PM="dnf"
  elif command -v zypper >/dev/null 2>&1; then PM="zypper"
  elif command -v apk >/dev/null 2>&1; then PM="apk"
  elif [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then PM="brew"
  else PM=""; fi
}
detect_pm

# ──────────────────────────────────────────────────────────────────────────────
disk_report() {
  say "${BOLD}=== Disk Free ===${RESET}"
  df -hT 2>/dev/null || df -h
  echo
}

largest_files() {
  local root="/"
  say "${BOLD}=== Top $TOP_N Biggest Files (root: $root) ===${RESET}"

  sudo -n true 2>/dev/null && SUDO="sudo" || SUDO=""
  # Collect <bytes>\t<path>, excluding virtual FS
  mapfile -t lines < <(
    $SUDO find "$root" -xdev \
      \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /snap -o -path /var/lib/snapd \) -prune -o \
      -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n "$TOP_N"
  ) || true

  if ((${#lines[@]}==0)); then
    warn "No files found (permissions?)"
    echo; return
  fi

  # Build pretty table (human or raw)
  local sizes=() paths=() pretty=() maxw=0
  for L in "${lines[@]}"; do
    sizes+=("${L%%$'\t'*}")
    paths+=("${L#*$'\t'}")
  done

  if (( HUMAN )); then
    for s in "${sizes[@]}"; do
      p="$(humanize "$s")"
      pretty+=("$p")
      ((${#p} > maxw)) && maxw=${#p}
    done
  else
    for s in "${sizes[@]}"; do
      pretty+=("$s")
      ((${#s} > maxw)) && maxw=${#s}
    done
  fi

  printf "%s  %s\n" "$(padleft "SIZE" "$maxw")" "PATH"
  printf "%s  %s\n" "$(padleft "----" "$maxw")" "----"
  local i
  for ((i=0;i<${#paths[@]};i++)); do
    printf "%s  %s%s%s\n" "$(padleft "${pretty[$i]}" "$maxw")" "$C_PATH" "${paths[$i]}" "$RESET"
  done
  echo
}

offer_remove_largest() {
  (( SHOW_ONLY )) && return 0
  say "${BOLD}Delete any of the listed big files?${RESET}"
  say "Paste full path(s) separated by space (or leave blank to skip)."
  read -r -p "> " paths || true
  [[ -z "${paths:-}" ]] && { info "Skip file deletions."; return 0; }

  for p in $paths; do
    if [[ -e "$p" ]]; then
      if confirm "Remove '$p'?"; then
        run "$(need_sudo) rm -f -- '$(printf "%q" "$p")'"
        ok "Removed: $p"
      else
        info "Skipped: $p"
      fi
    else
      warn "Not found: $p"
    fi
  done
  echo
}

steam_report() {
  (( NO_STEAM )) && return 0
  say "${BOLD}=== Games / Launchers Footprint ===${RESET}"

  declare -a CANDIDATES=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
    "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl"
    "$HOME/.local/share/lutris"
    "/Library/Application Support/Steam"
  )

  local found=0
  for d in "${CANDIDATES[@]}"; do
    if [[ -d "$d" ]]; then
      found=1
      s=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
      say "• ${BOLD}$d${RESET} = ${BOLD}$s${RESET}"
      if [[ -f "$d/steamapps/libraryfolders.vdf" ]]; then
        info "Steam library folders:"
        grep -Eo '"path"[[:space:]]*"[^"]+"' "$d/steamapps/libraryfolders.vdf" 2>/dev/null | \
          sed -E 's/.*"path"[[:space:]]*"([^"]+)".*/\1/' | while read -r lib; do
            [[ -d "$lib/steamapps/common" ]] || continue
            s2=$(du -sh "$lib/steamapps/common" 2>/dev/null | awk '{print $1}')
            say "   - $lib/steamapps/common = $s2"
          done
      fi
    fi
  done
  (( found )) || info "No known game launcher dirs found."
  echo
}

list_cleanup_targets() {
  say "${BOLD}=== Cleanup Candidates ===${RESET}"
  declare -a TARGETS=(
    "$HOME/.cache"
    "$HOME/.cache/thumbnails"
    "/tmp"
    "/var/tmp"
  )
  case "$PM" in
    pacman) TARGETS+=("/var/cache/pacman/pkg");;
    apt)    TARGETS+=("/var/cache/apt/archives");;
    dnf)    TARGETS+=("/var/cache/dnf");;
    zypper) TARGETS+=("/var/cache/zypp");;
    apk)    TARGETS+=("/var/cache/apk");;
    brew)   TARGETS+=("$HOME/Library/Caches/Homebrew");;
  esac
  TARGETS+=("$HOME/.cache/flatpak")
  [[ -d "/var/lib/flatpak" ]] && TARGETS+=("/var/lib/flatpak/.removed")
  [[ -d "/var/lib/snapd" ]] && TARGETS+=("/var/lib/snapd/cached")

  local line size
  for t in "${TARGETS[@]}"; do
    [[ -e "$t" ]] || continue
    size=$(du -sh "$t" 2>/dev/null | awk '{print $1}')
    printf "%-55s %10s\n" "$t" "$size"
  done
  echo

  (( SHOW_ONLY )) && return 0
  say "${BOLD}Select paths to clean (space-separated), or leave blank to skip.${RESET}"
  read -r -p "> " picks || true
  [[ -z "${picks:-}" ]] && { info "Skip generic cleanup."; return 0; }

  for p in $picks; do
    if [[ -d "$p" ]]; then
      if confirm "Delete contents of directory '$p'?"; then
        run "$(need_sudo) find '$(printf "%q" "$p")' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
        ok "Cleaned: $p"
      else
        info "Skipped: $p"
      fi
    elif [[ -f "$p" ]]; then
      if confirm "Remove file '$p'?"; then
        run "$(need_sudo) rm -f -- '$(printf "%q" "$p")'"
        ok "Removed: $p"
      else
        info "Skipped: $p"
      fi
    else
      warn "Not found: $p"
    fi
  done
  echo
}

pkg_cleanup() {
  (( NO_PKG )) && return 0
  say "${BOLD}=== Package / Journal Cleanup (optional) ===${RESET}"
  if (( DEEP )); then
    case "$PM" in
      pacman)
        confirm "pacman: remove orphan packages?" && run "$(need_sudo) pacman -Qtdq 2>/dev/null | xargs -r $(need_sudo) pacman -Rns --noconfirm"
        confirm "pacman: clear package cache (keep 3 versions)?" && run "$(need_sudo) paccache -rk3 2>/dev/null || $(need_sudo) pacman -Scc"
        ;;
      apt)
        confirm "apt: autoremove?" && run "$(need_sudo) apt-get -y autoremove"
        confirm "apt: clean caches?" && run "$(need_sudo) apt-get -y clean && $(need_sudo) apt-get -y autoclean"
        ;;
      dnf)
        confirm "dnf: remove old kernels/caches?" && run "$(need_sudo) dnf -y autoremove && $(need_sudo) dnf -y clean all"
        ;;
      zypper)
        confirm "zypper: clean caches?" && run "$(need_sudo) zypper clean --all"
        ;;
      apk)
        confirm "apk: clean cache?" && run "$(need_sudo) rm -rf /var/cache/apk/*"
        ;;
      brew)
        confirm "brew: cleanup?" && run "brew cleanup -s"
        ;;
      *) info "No package manager cleanup available.";;
    esac
    if command -v journalctl >/dev/null 2>&1; then
      confirm "Vacuum journald to 200M?" && run "$(need_sudo) journalctl --vacuum-size=200M"
    fi
  else
    info "Deep clean disabled. Use --deep to include package/journal cleanup."
  fi
  echo
}

dev_caches() {
  (( DEEP )) || { info "Dev cache sweep disabled (use --deep)."; echo; return 0; }
  say "${BOLD}=== Dev Cache Sweep (optional) ===${RESET}"
  declare -a DEV=(
    "$HOME/.cache/pip" "$HOME/.cache/pip/http" "$HOME/.cache/pip/wheels"
    "$HOME/.cache/npm" "$HOME/.npm" "$HOME/.cache/yarn"
    "$HOME/.cache/pipenv" "$HOME/.cache/pypoetry"
    "$HOME/.cache/Code/Cache" "$HOME/.cache/Code/CachedData"
    "$HOME/.cache/chromium/Default/Cache" "$HOME/.cache/google-chrome/Default/Cache"
  )
  for d in "${DEV[@]}"; do
    [[ -d "$d" ]] || continue
    s=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    printf "%-55s %10s\n" "$d" "$s"
  done
  echo
  (( SHOW_ONLY )) && return 0
  if confirm "Clear the above dev caches?"; then
    for d in "${DEV[@]}"; do
      [[ -d "$d" ]] || continue
      run "find '$(printf "%q" "$d")' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
    done
    ok "Dev caches cleared."
  else
    info "Skipped dev caches."
  fi
  echo
}

main() {
  say "${BOLD}sysclean v$VERSION${RESET} — $( [[ $DRY_RUN -eq 1 ]] && echo 'dry-run' || echo 'live' ) mode"
  info "Detected package manager: ${PM:-none}"
  echo

  disk_report
  largest_files
  offer_remove_largest
  steam_report
  list_cleanup_targets
  pkg_cleanup
  dev_caches

  ok "Done. Tidy system, happy K.A.R.I. ✨"
}

main "$@"
