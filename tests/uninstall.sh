#!/usr/bin/env bash
set -euo

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binman="${repo_root}/binman.sh"

tmp_home="$(mktemp -d)"
trap 'rm -rf "${tmp_home}"' EXIT

export TERM="${TERM:-xterm}"

bin_dir="${tmp_home}/.local/bin"
mkdir -p "$bin_dir"
touch "${bin_dir}/binman"
touch "${bin_dir}/binman.bak"

HOME="$tmp_home" "$binman" uninstall binman.bak >/dev/null 2>&1

if [[ -e "${bin_dir}/binman.bak" ]]; then
  echo "binman.bak still present after uninstall" >&2
  exit 1
fi

if [[ ! -e "${bin_dir}/binman" ]]; then
  echo "binman removed when uninstalling backup" >&2
  exit 1
fi

HOME="$tmp_home" "$binman" uninstall binman >/dev/null 2>&1

if [[ -e "${bin_dir}/binman" ]]; then
  echo "binman not removed on second uninstall" >&2
  exit 1
fi

exit 0
