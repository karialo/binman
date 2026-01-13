#!/usr/bin/env bash
# Description: Cross-distro package installer wrapper (apt/dnf/pacman/zypper/rpm-ostree)
VERSION="0.1.0"
set -Eeuo pipefail

APP="install"

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage:
  install [options] <package> [more packages...]

Options:
  -s, --search        Search for a package name (best effort)
  -n, --dry-run       Show what would run, don’t run it
  -y, --yes           Assume yes where supported (apt/dnf/zypper)
  -h, --help          Show help
  --version           Show version

Examples:
  install ripgrep fd
  install --search neovim
  install -n go git
EOF
}

SEARCH=0
DRYRUN=0
YES=0
PKGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--search) SEARCH=1; shift ;;
    -n|--dry-run) DRYRUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) say "$APP v$VERSION"; exit 0 ;;
    --) shift; break ;;
    -*) err "$APP: unknown option: $1"; err "Try: $APP --help"; exit 2 ;;
    *) PKGS+=("$1"); shift ;;
  esac
done
if [[ $# -gt 0 ]]; then PKGS+=("$@"); fi

if [[ ${#PKGS[@]} -lt 1 ]]; then
  usage
  exit 2
fi

# Detect distro-ish info
ID=""
ID_LIKE=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  ID="${ID:-}"
  ID_LIKE="${ID_LIKE:-}"
fi

have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ "$DRYRUN" -eq 1 ]]; then
    say "[dry-run] $*"
  else
    eval "$@"
  fi
}

is_atomic() {
  # rpm-ostree presence is the true tell
  have rpm-ostree
}

pkgtool() {
  # Prefer rpm-ostree if available (Atomic / Bazzite etc)
  if is_atomic; then echo "rpm-ostree"; return 0; fi
  if have apt-get; then echo "apt"; return 0; fi
  if have dnf; then echo "dnf"; return 0; fi
  if have pacman; then echo "pacman"; return 0; fi
  if have zypper; then echo "zypper"; return 0; fi
  echo "unknown"
}

TOOL="$(pkgtool)"

# Best-effort “search”
do_search() {
  local q="${PKGS[*]}"
  case "$TOOL" in
    rpm-ostree)
      # rpm-ostree doesn't really "search" nicely; fallback to rpm if present
      if have rpm; then
        err "$APP: rpm-ostree has limited search; trying: rpm -qa | grep -i"
        run "rpm -qa | grep -i -- \"$(printf %q "$q")\" || true"
      else
        err "$APP: no good search method available here."
        exit 2
      fi
      ;;
    apt)
      if have apt-cache; then
        run "apt-cache search -- \"$(printf %q "$q")\""
      else
        run "apt search -- \"$(printf %q "$q")\""
      fi
      ;;
    dnf)
      run "dnf search -- \"$(printf %q "$q")\""
      ;;
    pacman)
      run "pacman -Ss -- \"$(printf %q "$q")\""
      ;;
    zypper)
      run "zypper search -- \"$(printf %q "$q")\""
      ;;
    *)
      err "$APP: no supported package manager found."
      exit 2
      ;;
  esac
}

# Install
do_install() {
  case "$TOOL" in
    rpm-ostree)
      say "Detected Atomic (rpm-ostree). Layering: ${PKGS[*]}"
      run "sudo rpm-ostree install ${PKGS[*]@Q}"
      say "Note: changes apply after reboot."
      ;;
    apt)
      local y=""
      [[ "$YES" -eq 1 ]] && y="-y"
      run "sudo apt-get update"
      run "sudo apt-get install $y ${PKGS[*]@Q}"
      ;;
    dnf)
      local y=""
      [[ "$YES" -eq 1 ]] && y="-y"
      run "sudo dnf install $y ${PKGS[*]@Q}"
      ;;
    pacman)
      # pacman uses --noconfirm
      local y=""
      [[ "$YES" -eq 1 ]] && y="--noconfirm"
      run "sudo pacman -S --needed $y ${PKGS[*]@Q}"
      ;;
    zypper)
      local y=""
      [[ "$YES" -eq 1 ]] && y="-y"
      run "sudo zypper install $y ${PKGS[*]@Q}"
      ;;
    *)
      err "$APP: unsupported system. ID=$ID ID_LIKE=$ID_LIKE"
      err "$APP: found no known package manager (apt/dnf/pacman/zypper/rpm-ostree)."
      exit 2
      ;;
  esac
}

if [[ "$SEARCH" -eq 1 ]]; then
  do_search
else
  do_install
fi
