#!/usr/bin/env bash
# finder — recursive name finder (CWD or system-wide)
# Author: K.A.R.I. for Daddy
# Version: 1.0.0

set -Eeuo pipefail

usage() {
  cat <<USAGE
finder — search for files or directories by name

USAGE:
  finder [--all] [--tags] <pattern>

Options:
  --all     Search system-wide (requires sudo)
  --tags    Enable tag-based search (future feature placeholder)
  -h, --help Show this help

Examples:
  finder binman
  finder --all binman
USAGE
  exit 0
}

err(){ printf "\e[31m[ERR]\e[0m %s\n" "$*" >&2; exit 1; }
say(){ printf "\e[36m[finder]\e[0m %s\n" "$*"; }

SEARCH_ALL=0
PATTERN=""
USE_TAGS=0

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) SEARCH_ALL=1; shift ;;
    --tags) USE_TAGS=1; shift ;;
    -h|--help) usage ;;
    *) PATTERN="$1"; shift ;;
  esac
done

[[ -z "$PATTERN" ]] && usage

# --- search function ---
do_search() {
  local base="$1"
  say "Searching in: $base"
  find "$base" -iname "*${PATTERN}*" 2>/dev/null | sort
}

# --- main ---
if [[ $SEARCH_ALL -eq 1 ]]; then
  if [[ $EUID -ne 0 ]]; then
    say "Elevating to sudo for system-wide search..."
    exec sudo "$0" --all ${USE_TAGS:+--tags} "$PATTERN"
  fi
  do_search "/"
else
  do_search "$PWD"
fi
