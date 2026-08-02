#!/usr/bin/env bash
# Description: Safely remove the current local Git repository, optionally deleting its GitHub remote.
# App: gitremove
# Title: Git Remove
# Version: 0.1.0
# Usage: gitremove [PATH] [--remote] [--yes]

VERSION="0.1.0"
set -Eeuo pipefail

REMOTE_DELETE=0
YES=0
TARGET="."

say(){ printf '%s\n' "$*"; }
ok(){ printf '\e[32m%s\e[0m\n' "$*"; }
warn(){ printf '\e[33m%s\e[0m\n' "$*" >&2; }
err(){ printf '\e[31m%s\e[0m\n' "$*" >&2; exit 1; }

usage(){
  cat <<USAGE
gitremove v${VERSION}
Remove a local Git repository, with optional GitHub deletion.

Usage:
  gitremove [PATH] [--remote] [--yes]

Options:
  --remote   Also delete the GitHub repository behind origin.
  --yes      Skip confirmations (required for non-interactive use).
  -h, --help Show this help.

PATH defaults to the current directory. Default behavior removes only the local repository directory.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE_DELETE=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) err "Unknown option: $1" ;;
    *)
      [[ "$TARGET" == "." ]] || err "Only one repository path may be supplied."
      TARGET="$1"
      shift
      ;;
  esac
done

command -v git >/dev/null 2>&1 || err "git is required."

[[ -d "$TARGET" ]] || err "Repository path does not exist: $TARGET"
ROOT="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" && -d "$ROOT" ]] || err "The current directory is not inside a Git repository."

ROOT="$(realpath "$ROOT")"
NAME="$(basename "$ROOT")"
ORIGIN="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
GITHUB_SLUG=""

case "$ORIGIN" in
  git@github.com:*)
    GITHUB_SLUG="${ORIGIN#git@github.com:}"
    ;;
  https://github.com/*|http://github.com/*|ssh://git@github.com/*)
    GITHUB_SLUG="${ORIGIN#*github.com/}"
    ;;
esac
GITHUB_SLUG="${GITHUB_SLUG%.git}"

say "Repository: $NAME"
say "Local path: $ROOT"
if [[ -n "$ORIGIN" ]]; then
  say "Origin:     $ORIGIN"
else
  say "Origin:     (none)"
fi

if (( REMOTE_DELETE )); then
  [[ -n "$GITHUB_SLUG" ]] || err "--remote requires an origin hosted on GitHub."
  command -v gh >/dev/null 2>&1 || err "gh is required for remote deletion."
  gh auth status >/dev/null 2>&1 || err "gh is not authenticated. Run: gh auth login"
  warn "This will permanently delete GitHub repository: $GITHUB_SLUG"
fi

if (( ! YES )); then
  printf 'Type the repository name to confirm local deletion: '
  IFS= read -r confirmation
  [[ "$confirmation" == "$NAME" ]] || err "Confirmation did not match; nothing was removed."

  if (( REMOTE_DELETE )); then
    printf 'Type DELETE to confirm GitHub deletion too: '
    IFS= read -r remote_confirmation
    [[ "$remote_confirmation" == "DELETE" ]] || err "Remote deletion was not confirmed; nothing was removed."
  fi
fi

if (( REMOTE_DELETE )); then
  gh repo delete "$GITHUB_SLUG" --yes || err "GitHub deletion failed; local repository was preserved."
  ok "Deleted GitHub repository: $GITHUB_SLUG"
fi

cd /tmp
rm -rf -- "$ROOT"
ok "Deleted local repository: $ROOT"
