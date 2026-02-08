#!/usr/bin/env bash
# refresh-ssh.sh — refresh SSH known_hosts entries (and optionally reconnect)
# v0.1.1
#
# Usage:
#   refresh-ssh.sh 10.0.0.2
#   refresh-ssh.sh kali@10.0.0.2
#   refresh-ssh.sh pwnagotchi
#   refresh-ssh.sh --connect kali@10.0.0.2
#   refresh-ssh.sh --all --connect pi@10.0.0.2
#   refresh-ssh.sh --file ~/.ssh/known_hosts --connect pwnagotchi
#
# Notes:
# - Uses ssh-keygen -R under the hood (safe + standard)
# - --all will also remove [host]:port variants, if present
# - Does NOT disable StrictHostKeyChecking (we’re not savages)
# - If --connect is used and user@host is NOT provided, will prompt for SSH user.

VERSION="0.1.1"
set -Eeuo pipefail

# -------------------------
# Pretty output helpers
# -------------------------
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"
else
  BOLD=""; DIM=""; RESET=""
  RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

log()  { echo "${BLUE}>>>${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }

die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
${BOLD}refresh-ssh v$VERSION${RESET} — clean stale SSH host keys like a responsible gremlin.

${BOLD}Usage${RESET}
  refresh-ssh.sh [options] <host|ip|user@host>

${BOLD}Options${RESET}
  -c, --connect        Connect via ssh after refreshing (will prompt for user if not provided)
  -a, --all            Also remove [host]:port variants (helpful for gadgets + forwarded ports)
  -f, --file PATH      Use a specific known_hosts file (default: ~/.ssh/known_hosts)
  -p, --port PORT      When connecting, use this port (default: 22)
  -q, --quiet          Less chatter
  -h, --help           Show this help

${BOLD}Examples${RESET}
  refresh-ssh.sh 10.0.0.2
  refresh-ssh.sh --connect kali@10.0.0.2
  refresh-ssh.sh --connect 10.0.0.2        # prompts for user
  refresh-ssh.sh --all --connect pi@10.0.0.2
  refresh-ssh.sh --file ~/.ssh/known_hosts --connect pwnagotchi

EOF
}

prompt_user() {
  local u
  while true; do
    read -rp "SSH user: " u
    [[ -n "$u" ]] && echo "$u" && return
  done
}

# -------------------------
# Args
# -------------------------
CONNECT=0
ALL=0
QUIET=0
PORT="22"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--connect) CONNECT=1; shift ;;
    -a|--all) ALL=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -p|--port)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      PORT="$2"; shift 2 ;;
    -f|--file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      KNOWN_HOSTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *) break ;;
  esac
done

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { usage; exit 1; }

[[ $QUIET -eq 1 ]] || echo "${BOLD}refresh-ssh v$VERSION${RESET} — hello (bash)"

# -------------------------
# Validate env
# -------------------------
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found (install openssh-client)."
command -v ssh >/dev/null 2>&1 || warn "ssh not found; --connect will fail."

mkdir -p "$(dirname "$KNOWN_HOSTS")"

# Create known_hosts if missing (ssh-keygen -R expects a file)
if [[ ! -f "$KNOWN_HOSTS" ]]; then
  [[ $QUIET -eq 1 ]] || warn "known_hosts not found — creating: $KNOWN_HOSTS"
  : > "$KNOWN_HOSTS"
  chmod 600 "$KNOWN_HOSTS" || true
fi

# -------------------------
# Parse target into:
#   SSH_USER (optional)
#   SSH_HOST
# -------------------------
SSH_USER=""
SSH_HOST="$TARGET"

if [[ "$TARGET" == *@* ]]; then
  SSH_USER="${TARGET%@*}"
  SSH_HOST="${TARGET#*@}"
fi

[[ -n "$SSH_HOST" ]] || die "Could not parse host from: $TARGET"

# -------------------------
# Remove stale key(s)
# -------------------------
run_remove() {
  local host="$1"
  local label="$2"

  if [[ $QUIET -eq 0 ]]; then
    log "Removing known_hosts entry: ${BOLD}${host}${RESET} ${DIM}($label)${RESET}"
  fi

  # ssh-keygen -R prints to stderr/stdout depending; capture and show cleanly
  local out
  if out="$(ssh-keygen -f "$KNOWN_HOSTS" -R "$host" 2>&1)"; then
    # If nothing removed, ssh-keygen says "not found in ..."
    if grep -qi "not found in" <<<"$out"; then
      [[ $QUIET -eq 1 ]] || warn "No entry found for $host"
    else
      [[ $QUIET -eq 1 ]] || echo "$out"
      ok "Refreshed: $host"
    fi
  else
    # ssh-keygen returns nonzero sometimes even when it did work — still show output
    [[ $QUIET -eq 1 ]] || echo "$out" >&2
    warn "ssh-keygen reported an issue for $host (often harmless)."
  fi
}

run_remove "$SSH_HOST" "primary"

if [[ $ALL -eq 1 ]]; then
  # Also attempt common bracketed port format used in known_hosts: [host]:port
  run_remove "[${SSH_HOST}]:${PORT}" "bracketed-port"
  # Also try the default 22 bracketed just in case caller uses --port later
  if [[ "$PORT" != "22" ]]; then
    run_remove "[${SSH_HOST}]:22" "bracketed-22"
  fi
fi

# -------------------------
# Optionally connect
# -------------------------
if [[ $CONNECT -eq 1 ]]; then
  command -v ssh >/dev/null 2>&1 || die "ssh not found; cannot --connect."

  if [[ -z "$SSH_USER" ]]; then
    SSH_USER="$(prompt_user)"
  fi

  local_dest="${SSH_USER}@${SSH_HOST}"

  [[ $QUIET -eq 1 ]] || log "Connecting: ${BOLD}${local_dest}${RESET} ${DIM}(port $PORT)${RESET}"
  exec ssh -p "$PORT" "$local_dest"
fi

[[ $QUIET -eq 1 ]] || ok "Done."
