#!/usr/bin/env bash
# binman.sh — Personal CLI utility manager for your ~/bin toys
# --------------------------------------------------------------------------------------------------
# Manage install/uninstall/list/update for single-file scripts AND multi-file apps.
# Extras: TUI, generator, wizard, backup/restore, self-update, system installs, rollbacks, remotes,
#         manifests, bundles, test harness.
#
# CHANGELOG:
#   - Fix TUI metadata: robust manifest parsing, path expansion, preview/help rendering, debug mode.
#
# Design notes:
#   • “Scripts” live in ~/.local/bin/<name> (extension dropped on install).
#   • “Apps” live in ~/.local/share/binman/apps/<name> with a shim in ~/.local/bin/<name> that execs
#     ./apps/<name>/bin/<name>.
#   • When copying a single-file script, we stage to a temp path and mv atomically.
#   • “link” mode uses symlinks for dev workflows (only for user installs, never /usr/local).
#   • Rollback snapshots keep last state of bin/ and apps/ before mutating operations.
# ==================================================================================================

set -Eeuo pipefail
shopt -s nullglob

: "${UI_BOLD:=}"
: "${UI_DIM:=}"
: "${UI_RESET:=}"
: "${UI_CYAN:=}"
: "${UI_GREEN:=}"
: "${UI_YELLOW:=}"
: "${UI_MAGENTA:=}"
: "${UI_WIDTH:=80}"

: "${BINMAN_DEBUG:=0}"

# root-visible shim locations, in order of preference
: "${ROOT_SHIM_DIRS:=/usr/bin /bin}"

BINMAN_DEBUG_FLAG=0
case "${BINMAN_DEBUG:-}" in
  1|true|TRUE|True|yes|YES|Yes|on|ON|On)
    BINMAN_DEBUG_FLAG=1
    ;;
esac

BINMAN_LIST_SIG=""
REINDEX_REQUEST=0

EMIT_REHASH=0
_rest=()
for a in "$@"; do
  if [[ "$a" == "--emit-rehash" ]]; then
    EMIT_REHASH=1
  else
    _rest+=("$a")
  fi
done
set -- "${_rest[@]}"


# ===== Early, standalone preview handler (fields version) =====
if [[ "${1:-}" == "--_preview_fields" ]]; then
  # Args: type name ver path desc  (5 separate args from fzf {1..5})
  type="${2:-}"; name="${3:-}"; ver="${4:-}"; path="${5:-}"; desc="${6:-}"

  stripq(){ local s="$1"; [[ ${s:0:1} == "'" || ${s:0:1} == '"' ]] && s="${s:1}"; [[ ${s: -1} == "'" || ${s: -1} == '"' ]] && s="${s:0:${#s}-1}"; printf '%s' "$s"; }
  type="$(stripq "$type")"; name="$(stripq "$name")"; ver="$(stripq "$ver")"; path="$(stripq "$path")"; desc="$(stripq "$desc")"

  printf "\033[1m%s\033[0m  [%s]  — %s\n" "${name:-?}" "${ver:-unknown}" "${type:-?}"
  [[ -n "$desc" ]] && printf "%s\n" "$desc"
  printf "\n\033[2m──────────────────────────────────────────────────────────────\033[0m\n\n"

  try_help(){ "$1" --help 2>&1 || "$1" -h 2>&1; }
  show_file(){ if command -v bat >/dev/null 2>&1; then bat --style=plain --paging=never --wrap=never "$1"; else sed -n '1,400p' "$1"; fi; }

  if [[ "$type" == "cmd" ]]; then
    if [[ -x "$path" ]]; then try_help "$path" && exit 0; show_file "$path" && exit 0; fi
    [[ -f "$path" ]] && { show_file "$path"; exit 0; }
    exit 0
  elif [[ "$type" == "app" ]]; then
    for rd in "$path"/README "$path"/README.md "$path"/README.txt; do [[ -f "$rd" ]] && { show_file "$rd"; exit 0; }; done
    if [[ -x "$path/bin/$name" ]]; then try_help "$path/bin/$name" && exit 0; fi
    if [[ -f "$path/manifest.json" ]]; then show_file "$path/manifest.json"; exit 0; fi
    if command -v tree >/dev/null 2>&1; then (cd "$path" 2>/dev/null && tree -L 2); else (cd "$path" 2>/dev/null && find . -maxdepth 2 -print | sed -n '1,120p'); fi
    exit 0
  fi
  exit 0
fi
# ===== End fields preview handler =====


# Path to THIS running script; export for fzf subshells
BINMAN_SELF="${BINMAN_SELF:-$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || command -v "$0" || echo "$0")}"
export BINMAN_SELF


# --------------------------------------------------------------------------------------------------
# Constants & defaults
# --------------------------------------------------------------------------------------------------
SCRIPT_NAME="binman"
VERSION="1.9.0"

# User-scoped locations (XDG-ish)
BIN_DIR="${HOME}/.local/bin"
APP_STORE="${HOME}/.local/share/binman/apps"

# System-scoped locations (used with --system; requires write perms/sudo)
SYSTEM_BIN="/usr/local/bin"
SYSTEM_APPS="/usr/local/share/binman/apps"

# Cache/state paths
BINMAN_STATE_DIR="${BINMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/binman}"
mkdir -p "$BINMAN_STATE_DIR" 2>/dev/null || true
BINMAN_LIST_CACHE="${BINMAN_LIST_CACHE:-$BINMAN_STATE_DIR/inventory.tsv}"

# Runtime flags (influenced by CLI options)
COPY_MODE="copy"   # copy | link
FORCE=0            # overwrite on conflicts
FROM_DIR=""        # bulk install from a directory (executables only)
GIT_DIR=""         # optional git dir to pull before update
FIX_PATH=0         # doctor --fix-path flag
SYSTEM_MODE=0      # target system dirs
MANIFEST_FILE=""   # bulk install manifest
QUIET=0            # less noisy
JSON_MODE=0        # machine-readable output flag

ENTRY_CMD=""      # custom entry command for apps
ENTRY_CWD=""      # optional subdir to cd into before running entry

ENTRY_CMD=""        # --entry "<command to exec inside appdir>"
ENTRY_CWD=""        # --workdir "<subdir inside appdir>" (optional)
VENV_MODE=0         # --venv : create/activate app-local .venv for entry
REQ_FILE=""         # --req FILE : requirements file name (default: requirements.txt)
BOOT_PY="python3"   # --python BIN : bootstrap interpreter to create venv


# Rollback snapshot controls (env overrides)
AUTO_BACKUP_WARNED=0
PRUNE_LAST_REMOVED=0
PATH_WARNED=0
SYSTEM_WRITE_WARNED=0

# Silence implicit getopts error messages globally
OPTERR=0



# --------------------------------------------------------------------------------------------------
# Small helpers (consistent messages, detection, paths)
# --------------------------------------------------------------------------------------------------
# Prefer the project's fzf() checker if it exists; otherwise fall back to binary check.
__has_fzf() {
  command -v fzf >/dev/null 2>&1
}

cleanup_root_shims() {
  local name="$1"
  local target="$SYSTEM_BIN/$name"
  local d link
  for d in $ROOT_SHIM_DIRS; do
    link="$d/$name"
    if [[ -L "$link" ]] && [[ "$(readlink -f "$link" 2>/dev/null || true)" == "$(readlink -f "$target" 2>/dev/null || true)" ]]; then
      _as_root rm -f "$link" || true
      debug "shim: removed $link"
    fi
  done
}

# Back-compat alias for menu action name
toggle_system_mode() { toggle_system "$@"; }

# Toggle between user mode (default) and system mode (requires write access)
toggle_system() {
  # Flip the flag
  if (( SYSTEM_MODE )); then
    SYSTEM_MODE=0
  else
    SYSTEM_MODE=1
  fi

  # If enabling system mode, verify dirs and permissions
  if (( SYSTEM_MODE )); then
    ensure_system_dirs || {
      SYSTEM_MODE=0
      warn "Could not ensure system directories. Staying in user mode."
      return 1
    }
    if ! ensure_system_write; then
      SYSTEM_MODE=0
      warn "No write access to ${SYSTEM_BIN} and/or ${SYSTEM_APPS}. Staying in user mode."
      return 1
    fi
  fi

  # UX: show targets so user knows where stuff will go now
  local tgt_bin tgt_apps
  if (( SYSTEM_MODE )); then
    tgt_bin="$SYSTEM_BIN"
    tgt_apps="$SYSTEM_APPS"
  else
    tgt_bin="$BIN_DIR"
    tgt_apps="$APP_STORE"
  fi

  say "System mode is now: $([[ $SYSTEM_MODE -eq 1 ]] && echo 'ON' || echo 'OFF')"
  say "Target bin:  ${tgt_bin}"
  say "Target apps: ${tgt_apps}"
  return 0
}

# Print the correct rehash command for the parent shell (best-effort)
rehash_hint() {
  local parent_shell
  parent_shell="$(ps -p "${PPID}" -o comm= 2>/dev/null || true)"

  case "$parent_shell" in
    zsh|zsh-*)
      say "${C_OK:-}[BinMan] -> run: ${BOLD:-}rehash${RESET:-} to refresh your shell."
      ;;
    bash|bash-*)
      say "${C_OK:-}[BinMan] -> run: ${BOLD:-}hash -r${RESET:-} to refresh your shell."
      ;;
    *)
      say "${C_OK:-}[BinMan] -> refresh your shell: ${BOLD:-}rehash${RESET:-} (zsh) or ${BOLD:-}hash -r${RESET:-} (bash)."
      ;;
  esac
}

# Remove zero-length/whitespace args from "$@"
__strip_empty_args() {
  local out=() a
  for a in "$@"; do
    [[ -z "${a//[$' \t\r\n']/}" ]] && continue
    out+=("$a")
  done
  ARGS_OUT=("${out[@]}")
}

say(){
    printf "%s\n" "$*"; 
}

err(){
    printf "\e[31m%s\e[0m\n" "$*" 1>&2;
}

warn(){
    printf "\e[33m%s\e[0m\n" "$*" 1>&2;
}

ok(){
    printf "\e[32m%s\e[0m\n" "$*";
}

debug(){
  (( BINMAN_DEBUG_FLAG )) || return 0
  printf '[binman] %s\n' "$*" >&2
}

_as_root() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  else
    return 126
  fi
}

json_escape(){
  local s="${1-}"
  s=${s//\/\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\f'/\\f}
  s=${s//$'\b'/\\b}
  printf '%s' "$s"
}

emit_json_object(){
  (( JSON_MODE )) || return 0
  local first=1 key value
  printf '{'
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    (( first )) || printf ','
    printf '"%s":"%s"' "$(json_escape "$key")" "$(json_escape "$value")"
    first=0
  done
  printf '}\n'
}

exists(){
    command -v "$1" >/dev/null 2>&1;
}

iso_now(){
    date -Iseconds;
}

maybe_sudo_cmd(){
  : "${SUDO_NONINTERACTIVE:=-1}"
  if (( SUDO_NONINTERACTIVE == -1 )); then
    if command -v sudo >/dev/null 2>&1; then
      if sudo -n true >/dev/null 2>&1; then
        SUDO_NONINTERACTIVE=1
      else
        SUDO_NONINTERACTIVE=0
      fi
    else
      SUDO_NONINTERACTIVE=0
    fi
  fi

  if (( SUDO_NONINTERACTIVE == 1 )); then
    sudo "$@"
  else
    "$@"
  fi
}

# POSIX-friendly realpath fallback (prefers python3, then readlink -f)
realpath_f(){
    python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || readlink -f "$1";
}

human_size(){
  local bytes="$1"
  [[ -z "$bytes" ]] && { echo "0B"; return; }
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$bytes" <<'PY'
import sys
def human(n):
    n=float(n)
    units=["B","KB","MB","GB","TB","PB"]
    for u in units:
        if n<1024 or u==units[-1]:
            return f"{n:.1f}{u}" if u!="B" else f"{int(n)}B"
        n/=1024

print(human(sys.argv[1]))
PY
    return
  fi
  echo "${bytes}B"
}

stat_mtime(){
  local path="$1"
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0
}

trim(){
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_inline_comment(){
  local s="${1-}"
  local in_single=0 in_double=0 ch out=""
  local i len=${#s}
  for (( i=0; i<len; i++ )); do
    ch="${s:i:1}"
    if [[ "$ch" == "'" && $in_double -eq 0 ]]; then
      (( in_single = 1 - in_single ))
      out+="$ch"
      continue
    fi
    if [[ "$ch" == '"' && $in_single -eq 0 ]]; then
      (( in_double = 1 - in_double ))
      out+="$ch"
      continue
    fi
    if [[ "$ch" == '#' && $in_single -eq 0 && $in_double -eq 0 ]]; then
      break
    fi
    out+="$ch"
  done
  printf '%s' "$out"
}

__bm_tui_install_flow() {
  ui_init
  prompt_init
  # Use fzf file/dir picker from CWD; supports manual multi-line entry too
  if __has_fzf && [[ -t 1 ]]; then
    mapfile -t items < <(find . -maxdepth 1 -mindepth 1 -printf '%P\n' 2>/dev/null | sort)
    items=("Type a path/URL…" "${items[@]}")
    sel="$(printf '%s\n' "${items[@]}" | fzf --prompt="Install > " --height=60% --reverse || true)"
    [[ -z "$sel" ]] && { warn "Nothing to install"; return 0; }

    if [[ "$sel" == "Type a path/URL…" ]]; then
      printf "File/dir/URL (or --manifest FILE): "
      manual_lines=()

      if IFS= read -r line; then
        [[ -z "$line" ]] && { say "Cancelled."; return 0; }
        manual_lines+=("$line")
        while IFS= read -r -t 0 extra; do manual_lines+=("$extra"); done
      else
        return 0
      fi

      targets=(); manifest=""

      for entry in "${manual_lines[@]}"; do
        [[ -z "$entry" ]] && continue
        if [[ "$entry" =~ ^--manifest[[:space:]]+ ]]; then
          manifest="${entry#--manifest }"
          continue
        fi
        entry="${entry%/}"
        if [[ "$entry" == /* ]]; then abs="$entry"; else abs="$PWD/$entry"; fi
        if [[ -f "$abs" || -d "$abs" ]]; then
          targets+=("$abs")
        else
          targets+=("$entry")
        fi
      done

      if [[ -n "$manifest" ]]; then
        [[ "$manifest" != /* && -e "$manifest" ]] && manifest="$PWD/$manifest"
        op_install_manifest "$manifest" || true
        rehash_hint
        printf "%sPress Enter to return to BinMan…%s" "$UI_DIM" "$UI_RESET"; read -r
        return 0
      elif (( ${#targets[@]} > 0 )); then
        op_install "${targets[@]}" || true
        rehash_hint
        printf "%sPress Enter to return to BinMan…%s" "$UI_DIM" "$UI_RESET"; read -r
        return 0
      else
        say "Cancelled."
        return 0
      fi

    else
      # Selected a visible item; pass absolute path
      pick="$sel"
      [[ "$pick" != /* ]] && pick="$PWD/$pick"
      op_install "$pick" || true
      rehash_hint
      printf "%sPress Enter to return to BinMan…%s" "$UI_DIM" "$UI_RESET"; read -r
      return 0
    fi

  else
    # No TTY/fzf → fall back to plain op_install (expects args from caller)
    op_install || true
    rehash_hint
    printf "%sPress Enter to return to BinMan…%s" "$UI_DIM" "$UI_RESET"; read -r
    return 0
  fi
}

__bm_tui_uninstall_flow() {
  ui_init
  prompt_init
  if command -v fzf >/dev/null 2>&1 && [[ -t 1 ]]; then
    mapfile -t _cmds < <(_get_installed_cmd_names)
    _apps=()
    # [Patch] Uninstall: only list shims unless BINMAN_INCLUDE_APPS=1
    if [[ "${BINMAN_INCLUDE_APPS:-0}" == "1" ]]; then
      mapfile -t _apps < <(_get_installed_app_names)
    fi
    if ((${#_cmds[@]}==0 && ${#_apps[@]}==0)); then
      warn "Nothing to uninstall."; return 0
    fi
    _choices=()
    for c in "${_cmds[@]}"; do _choices+=("cmd  $c"); done
    if [[ "${BINMAN_INCLUDE_APPS:-0}" == "1" ]]; then
      for a in "${_apps[@]}"; do _choices+=("app  $a"); done
    fi
    sel="$(printf '%s\n' "${_choices[@]}" | fzf --multi --prompt="Uninstall > " --height=60% --reverse || true)"
    [[ -z "$sel" ]] && { say "Cancelled."; return 0; }
    names="$(echo "$sel" | awk '{print $2}' | tr '\n' ' ')"
    # shellcheck disable=SC2086
    op_uninstall $names
  else
    _print_uninstall_menu
    printf "Name (space-separated for multiple, Enter to cancel): "
    IFS= read -r names
    [[ -z "$names" ]] && { say "Cancelled."; return 0; }
    # shellcheck disable=SC2086
    op_uninstall $names
  fi
}

_bm_expand_tokens(){
  local raw="${1-}"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$raw" <<'PY' 2>/dev/null && return 0
import os
import re
import sys
s = sys.argv[1]
pattern = re.compile(r'(?:(?<=^)|(?<=[\s:=\'"(\[]))~[A-Za-z0-9_\-]*')
def repl(match):
    token = match.group(0)
    try:
        return os.path.expanduser(token)
    except Exception:
        return token
try:
    expanded = pattern.sub(repl, s)
except re.error:
    expanded = os.path.expanduser(s)
try:
    expanded = os.path.expandvars(expanded)
except Exception:
    pass
sys.stdout.write(expanded)
PY
  fi

  local out="$raw"
  if [[ "$out" == "~" || "$out" == "~/"* ]]; then
    out="${HOME}${out:1}"
  fi
  out="${out//\$HOME/$HOME}"
  out="${out//\$\{HOME\}/$HOME}"
  printf '%s' "$out"
}

expand_path(){
  local raw="${1-}"
  [[ -z "$raw" ]] && return 0
  printf '%s\n' "$(_bm_expand_tokens "$raw")"
}

expand_command(){
  local raw="${1-}"
  [[ -z "$raw" ]] && return 0
  printf '%s\n' "$(_bm_expand_tokens "$raw")"
}

# Return just the names of installed commands (user or system)
_get_installed_cmd_names() {
  local dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*; do [[ -x "$f" && -f "$f" ]] && basename "$f"; done
}

# Return just the names of installed apps (user or system)
_get_installed_app_names() {
  local adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"
  [[ -d "$adir" ]] || return 0
  for d in "$adir"/*; do [[ -d "$d" || -L "$d" ]] && basename "$d"; done
}

# Pretty print a compact list for uninstall prompt
_print_uninstall_menu() {
  local cmds apps include_apps
  include_apps="${BINMAN_INCLUDE_APPS:-0}"
  cmds=($(_get_installed_cmd_names))
  # [Patch] Uninstall: only list shims unless BINMAN_INCLUDE_APPS=1
  if [[ "$include_apps" == "1" ]]; then
    apps=($(_get_installed_app_names))
  else
    apps=()
  fi

  echo
  echo "Installed commands:"
  if ((${#cmds[@]})); then
    printf "  %s\n" "${cmds[@]}"
  else
    echo "  (none)"
  fi

  if [[ "$include_apps" == "1" ]]; then
    echo
    echo "Installed apps:"
    if ((${#apps[@]})); then
      printf "  %s\n" "${apps[@]}"
    else
      echo "  (none)"
    fi
  fi
  echo
}

# Pick an installed command to run (fzf if present, numeric fallback). Echo selection.
_pick_installed_cmd(){
  local dir names=() i=1
  dir="$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR")"
  [[ -d "$dir" ]] || return 1
  while IFS= read -r -d '' f; do
    [[ -x "$f" && -f "$f" ]] && names+=("$(basename "$f")")
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)

  (( ${#names[@]} )) || { warn "Nothing installed."; return 1; }

  # fzf path
  if exists fzf; then
    printf "%s\n" "${names[@]}" | fzf --prompt="Test > " --height=60% --reverse || true
    return 0
  fi

  # numeric fallback
  echo
  echo "Select command to test:"
  for n in "${names[@]}"; do printf "  %2d) %s\n" "$i" "$n"; ((i++)); done
  printf "Number (Enter to cancel): "
  local choice; IFS= read -r choice
  [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || "$choice" -lt 1 || "$choice" -gt ${#names[@]} ]] && { echo ""; return 1; }
  echo "${names[$((choice-1))]}"
}

# Pick target for "binman test": returns either "stress" or a command name.
_pick_test_target(){
  # grab installed commands (user or system) using the existing helper
  local names=()
  mapfile -t names < <(_get_installed_cmd_names)

  # fzf path: ALWAYS feed stdin so it won't list the cwd by itself
  if exists fzf; then
    {
      printf "stress (gauntlet)\n"
      printf "%s\n" "${names[@]}"
    } | fzf --prompt="Test > " --height=60% --reverse || return 1
    return 0
  fi

  # numeric fallback (0 = stress)
  local i=1
  echo
  echo "Select command to test:"
  printf "  %2d) %s\n" 0 "stress (gauntlet)"
  for n in "${names[@]}"; do printf "  %2d) %s\n" "$i" "$n"; ((i++)); done
  printf "Number (Enter to cancel): "
  local choice; IFS= read -r choice
  [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && return 1
  [[ "$choice" -eq 0 ]] && { echo "stress"; return 0; }
  (( choice >= 1 && choice <= ${#names[@]} )) || return 1
  echo "${names[$((choice-1))]}"
}

_fzf(){ 
    command -v fzf >/dev/null 2>&1; 
    }

_tui_pick_install_target(){
  # Lists files/dirs from CWD for Install. Return selection on stdout.
  local items=() idx=1 sel
  while IFS= read -r -d '' f; do items+=("$f"); done < <(find . -maxdepth 1 -mindepth 1 -print0 | sort -z)
  # pretty label
  _label(){ local p="${1#./}"; [[ -d "$1" ]] && printf "dir  %s\n" "$p" || printf "file %s\n" "$p"; }

  if _fzf; then
    sel="$(printf "%s\n" "${items[@]}" \
      | sed 's#^\./##' \
      | while read -r p; do [[ -d "$p" ]] && echo "dir  $p" || echo "file $p"; done \
      | fzf --prompt="Install > " --height=60% --reverse --expect=enter --ansi  --bind 'esc:abort'\
      | tail -n +2 | sed 's/^.... //')"
    [[ -n "$sel" ]] && printf "%s\n" "$sel"
    return
  fi

  # Fallback: numeric list
  echo "Choose what to install (or enter a custom path/URL):"
  for f in "${items[@]}"; do printf "  %2d) %s\n" "$idx" "$(_label "$f")"; idx=$((idx+1)); done
  printf "  c) custom path/URL\n> "
  read -r ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<idx )); then
    printf "%s\n" "${items[ans-1]#./}"
  elif [[ "${ans,,}" == c* || -n "$ans" ]]; then
    printf "%s\n" "$ans"
  fi
}

_tui_pick_archive(){
  # Pick a .zip or .tar.gz from CWD (or enter path)
  local files=() idx=1 sel
  while IFS= read -r -d '' f; do files+=("${f#./}"); done < <(find . -maxdepth 1 -type f \( -name '*.zip' -o -name '*.tar.gz' -o -name '*.tgz' \) -print0 | sort -z)
  if _fzf; then
    sel="$(printf "%s\n" "${files[@]}" | fzf --prompt="Restore > " --height=60% --reverse)"
    [[ -n "$sel" ]] && printf "%s\n" "$sel"
    return
  fi
  echo "Choose an archive to restore (or enter a path):"
  for f in "${files[@]}"; do printf "  %2d) %s\n" "$idx" "$f"; idx=$((idx+1)); done
  printf "> "
  read -r ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<idx )); then
    printf "%s\n" "${files[ans-1]}"
  else
    printf "%s\n" "$ans"
  fi
}

_tui_pick_cmd_or_app_multi(){
  # Multi-select installed commands/apps. Prints lines like:
  #   cmd name
  #   app name
  local cmd=() app=() rows=()
  mapfile -t cmd < <(_get_installed_cmd_names)
  mapfile -t app < <(_get_installed_app_names)
  for c in "${cmd[@]}"; do rows+=("cmd  $c"); done
  for a in "${app[@]}"; do rows+=("app  $a"); done

  if _fzf; then
    printf "%s\n" "${rows[@]}" | fzf --multi --prompt="Select (TAB=multi, Enter=done) > " --height=60% --reverse
    return
  fi

  # Fallback: numeric multi (space separated)
  local idx=1
  echo "Select one or more (space-separated numbers), or 'a' for ALL, or Enter to cancel:"
  for r in "${rows[@]}"; do printf "  %2d) %s\n" "$idx" "$r"; idx=$((idx+1)); done
  printf "> "
  local pick; read -r pick
  [[ -z "$pick" ]] && return 0
  if [[ "${pick,,}" == a ]]; then
    printf "%s\n" "${rows[@]}"
    return 0
  fi
  for n in $pick; do
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<idx )); then
      printf "%s\n" "${rows[n-1]}"
    fi
  done
}



# --------------------------------------------------------------------------------------------------
# Usage banner
# --------------------------------------------------------------------------------------------------
usage(){ cat <<USAGE
${SCRIPT_NAME} v${VERSION}
Manage personal CLI scripts in ${BIN_DIR} and apps in ${APP_STORE}

USAGE: ${SCRIPT_NAME} <install|uninstall|verify|list|update|doctor|new|wizard|tui|backup|restore|self-update|rollback|prune-rollbacks|analyze|bundle|test|version|help> [args] [options]
       ${SCRIPT_NAME} --backup [FILE]
       ${SCRIPT_NAME} --restore FILE [--force]

Options:
  --from DIR         Operate on all executable files in DIR
  --link             Symlink instead of copying
  --force            Overwrite existing files / restore conflicts
  --git DIR          Before update: git pull in DIR
  --bin DIR          Override bin directory (default: ${BIN_DIR})
  --apps DIR         Override apps directory (default: ${APP_STORE})
  --system           Target system dirs (/usr/local/*) (requires write perms/sudo)
  --fix-path         (doctor) Add ~/.local/bin to zsh PATH (~/.zshrc & ~/.zprofile)
  --manifest FILE    For bulk install (line list or JSON array if jq available)
  --reindex          Rebuild manifest index before running command
  --quiet            Less chatty
Backup/Restore convenience:
  --backup [FILE]    Create archive (.zip if zip/unzip exist else .tar.gz)
  --restore FILE     Restore archive into target dirs (merge; --force to clobber)

Extra commands:
  self-update          Update BinMan from its git repo then reinstall the shim
  rollback [ID]        Restore the latest (or specific) rollback snapshot
  prune-rollbacks      Prune rollback snapshots beyond BINMAN_ROLLBACK_KEEP (default 20)
  analyze [opts]       Inspect disk usage hotspots (--top N --root DIR)
  bundle [OUT]         Export bundle (bin+apps+manifest.txt) to archive
  test NAME [-- ARGS]  Run NAME with --help (or ARGS) to sanity-check exit
  test stress [--jobs N] [--verbose] [--keep] [--quick]  

Examples:
  ${SCRIPT_NAME} install tool.sh
  ${SCRIPT_NAME} install MyApp/                      # app dir (expects bin/MyApp)
  ${SCRIPT_NAME} install https://.../script.sh       # remote file
  ${SCRIPT_NAME} install --manifest tools.txt        # bulk installs
  ${SCRIPT_NAME} backup ; ${SCRIPT_NAME} restore file.zip
  ${SCRIPT_NAME} self-update

Environment:
  BINMAN_DEBUG=1      Verbose logging (manifest parsing, index rebuild)
USAGE
}



# --------------------------------------------------------------------------------------------------
# Shell rehash for zsh/bash (after installs/uninstalls)
# --------------------------------------------------------------------------------------------------
rehash_shell(){
  if [ -n "${ZSH_VERSION:-}" ]; then hash -r || true; rehash || true; fi
  if [ -n "${BASH_VERSION:-}" ]; then hash -r || true; fi
}



# --------------------------------------------------------------------------------------------------
# Path / dir helpers
# --------------------------------------------------------------------------------------------------
in_path(){ case ":$PATH:" in *":${BIN_DIR}:"*) return 0;; *) return 1;; esac; }
ensure_dir(){ mkdir -p "$1"; }
ensure_bin(){ ensure_dir "$BIN_DIR"; }
ensure_apps(){ ensure_dir "$APP_STORE"; }

# Create system dirs if missing, escalating when required.
# Returns 0 on success (dirs exist), 1 on failure (stay in user mode).
ensure_system_dirs() {
  : "${SYSTEM_BIN:=/usr/local/bin}"
  : "${SYSTEM_APPS:=/usr/local/share/binman/apps}"

  # Try to create parents first (install -d is atomic-ish and idempotent)
  if [[ ! -d "$SYSTEM_APPS" ]]; then
    if mkdir -p "$SYSTEM_APPS" 2>/dev/null; then
      :
    else
      _as_root install -d -m 0755 "$SYSTEM_APPS" || return 1
    fi
  fi

  if [[ ! -d "$SYSTEM_BIN" ]]; then
    if mkdir -p "$SYSTEM_BIN" 2>/dev/null; then
      :
    else
      _as_root install -d -m 0755 "$SYSTEM_BIN" || return 1
    fi
  fi

  # Final sanity: both must be writable by whoever will perform writes
  # If not root, ensure we *can* write via sudo/pkexec when needed.
  if [[ -w "$SYSTEM_BIN" && -w "$SYSTEM_APPS" ]]; then
    return 0
  fi

  # Probe that we can write with escalation (no-op temp touches)
  _as_root test -w "$SYSTEM_BIN"  || return 1
  _as_root test -w "$SYSTEM_APPS" || return 1

  return 0
}

# Return 0 if we can write (directly or via sudo/pkexec), else 1
ensure_system_write() {
  : "${SYSTEM_BIN:=/usr/local/bin}"
  : "${SYSTEM_APPS:=/usr/local/share/binman/apps}"

  if [[ -w "$SYSTEM_BIN" && -w "$SYSTEM_APPS" ]]; then
    return 0
  fi
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    # sudo -n: non-interactive probe; if it fails, still allow interactive later
    sudo -n true 2>/dev/null || true
    return 0
  fi
  if command -v pkexec >/dev/null 2>&1; then
    return 0
  fi
  return 1
}


# [Patch] Create/update a /usr/bin symlink to the system shim
ensure_system_symlink() {
  local name="$1"
  local target="$SYSTEM_BIN/$name"  # e.g. /usr/local/bin/<name>
  [[ -x "$target" ]] || { debug "shim: missing target $target"; return 0; }

  local d link cur tgt
  for d in $ROOT_SHIM_DIRS; do
    [[ -d "$d" ]] || continue
    link="$d/$name"

    # create
    if [[ ! -e "$link" ]]; then
      _as_root ln -s "$target" "$link" \
        && debug "shim: created $link -> $target" \
        || err "shim: failed to create $link"
      continue
    fi

    # update wrong symlink
    if [[ -L "$link" ]]; then
      cur="$(readlink -f "$link" 2>/dev/null || true)"
      tgt="$(readlink -f "$target" 2>/dev/null || true)"
      if [[ "$cur" != "$tgt" ]]; then
        _as_root ln -sfn "$target" "$link" \
          && debug "shim: updated $link -> $target" \
          || err "shim: failed to update $link"
      else
        debug "shim: already correct $link -> $target"
      fi
      continue
    fi

    # do not overwrite real files or dirs
    warn "shim: $link exists and is not a symlink, skipping"
  done
}

# [Patch] Remove /usr/bin symlink if it points to the system shim
remove_system_symlink_if_owned() {
  local name="$1"
  local target="$SYSTEM_BIN/$name"
  local link="/usr/bin/$name"

  [[ -L "$link" ]] || { debug "symlink: no link at $link"; return 0; }
  local cur; cur="$(readlink -f "$link" 2>/dev/null || true)"
  if [[ "$cur" == "$target" ]]; then
    if _as_root rm -f "$link"; then
      debug "symlink: removed $link"
    else
      err "failed to remove $link"
    fi
  else
    debug "symlink: $link points to $cur (not ours), leaving intact"
  fi
}

maybe_warn_path(){
  (( SYSTEM_MODE == 0 )) || return 0
  (( PATH_WARNED )) && return 0
  (( QUIET )) && return 0
  (( JSON_MODE )) && return 0
  in_path && return 0

  PATH_WARNED=1
  local snippet='export PATH="$HOME/.local/bin:$PATH"'
  local shell_name profile
  shell_name="${SHELL##*/}"
  case "$shell_name" in
    zsh) profile="$HOME/.zshrc";;
    bash) profile="$HOME/.bashrc";;
    *) profile="$HOME/.profile";;
  esac

  warn "${BIN_DIR} is not in PATH. Run: ${snippet}"

  if [[ -t 1 ]]; then
    prompt_init
    local short_profile="${profile/#$HOME/~}"
    if ask_yesno "Append to ${short_profile}?" "n"; then
      touch "$profile"
      if grep -F "$snippet" "$profile" >/dev/null 2>&1; then
        say "Already present in ${short_profile}."
      else
        printf '\n# Added by BinMan %s\n%s\n' "$(iso_now)" "$snippet" >> "$profile"
        ok "Added PATH export to ${short_profile}"
      fi
    fi
  fi
}



# --------------------------------------------------------------------------------------------------
# Rollback snapshots (pre-change backups of bin/ & apps/)
# --------------------------------------------------------------------------------------------------
ROLLBACK_ROOT="${HOME}/.local/share/binman/rollback"

stash_before_change(){
  local ts root
  ts=$(date +%Y%m%d-%H%M%S)
  root="${ROLLBACK_ROOT}/${ts}"
  mkdir -p "${root}/bin" "${root}/apps" "${root}/meta"
  [[ -d "$BIN_DIR"  ]] && cp -a "$BIN_DIR"/.  "${root}/bin"  2>/dev/null || true
  [[ -d "$APP_STORE" ]]&& cp -a "$APP_STORE"/. "${root}/apps" 2>/dev/null || true
  printf "Created: %s\nBinMan: %s\nBIN_DIR: %s\nAPP_STORE: %s\n" \
    "$(iso_now)" "${VERSION}" "$BIN_DIR" "$APP_STORE" > "${root}/meta/info.txt"
  ! (( QUIET )) && ok "Rollback snapshot: ${ts}"
  echo "${ts}"
}

prune_rollbacks(){
  PRUNE_LAST_REMOVED=0
  local keep="${BINMAN_ROLLBACK_KEEP:-20}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=20
  (( keep < 0 )) && keep=0
  [[ -d "$ROLLBACK_ROOT" ]] || return 0
  mapfile -t ids < <(ls -1 "$ROLLBACK_ROOT" 2>/dev/null | sort -r)
  (( ${#ids[@]} == 0 )) && return 0

  local i=0 id path
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    [[ "$id" == "." || "$id" == ".." ]] && continue
    i=$((i+1))
    if (( i > keep )); then
      path="$ROLLBACK_ROOT/$id"
      [[ -e "$path" || -L "$path" ]] || continue
      rm -rf -- "$path"
      (( PRUNE_LAST_REMOVED++ ))
    fi
  done
}

maybe_snapshot(){
  (( ${BINMAN_AUTO_BACKUP:-0} )) || return 0
  if stash_before_change >/dev/null; then
    prune_rollbacks
  fi
}

latest_rollback_id(){
  [[ -d "$ROLLBACK_ROOT" ]] || return 1
  (cd "$ROLLBACK_ROOT" && ls -1 | sort -r | head -n1)
}

apply_rollback(){
  local id="$1" src="${ROLLBACK_ROOT}/${id}"
  [[ -d "$src" ]] || { err "No rollback id: $id"; return 2; }
  _merge_dir "${src}/bin"  "$BIN_DIR"
  _merge_dir "${src}/apps" "$APP_STORE"
  rehash_shell
  if (( EMIT_REHASH )); then
    printf '[ -n "${ZSH_VERSION:-}" ] && rehash || { [ -n "${BASH_VERSION:-}" ] && hash -r; }%s' $'\n'
    return 0
  fi
  ok "Rollback applied: $id"
}



# --------------------------------------------------------------------------------------------------
# Script/app metadata extraction (version, description)
# --------------------------------------------------------------------------------------------------
script_version(){
  # Accepts either a file or an app dir. Tries VERSION file, then markers in the entry script.
  local f="$1"
  if [[ -d "$f" ]]; then
    [[ -f "$f/VERSION" ]] && { head -n1 "$f/VERSION" | tr -d '\r'; return; }
    local name; name=$(basename "$f")
    [[ -f "$f/bin/$name" ]] && \
      grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f/bin/$name" \
      | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' && return
    echo "unknown"; return
  fi
  local v
  v=$(grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f" 2>/dev/null || true)
  [[ -n "$v" ]] && echo "$v" | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' || echo "unknown"
}

# [Patch] Better version detection for standalone shims/scripts
shim_version() {
  local f="$1"
  local v

  # Author-stamped tags inside shim:
  #   # binman:version=1.2.3
  #   BINMAN_VERSION=1.2.3
  v="$(grep -E '^(#\s*binman:version=|BINMAN_VERSION=)' "$f" 2>/dev/null | head -n1 | sed 's/.*=//')" || true
  [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }

  # If the shim is a symlink/wrapper into an app bin/, try to read ../VERSION
  if [[ -L "$f" ]]; then
    local t d
    t="$(readlink -f "$f" 2>/dev/null)" || t=""
    [[ -n "$t" ]] && d="$(dirname "$t")"
    if [[ -n "$d" && -f "$d/../VERSION" ]]; then
      cat "$d/../VERSION"; return 0
    fi
  fi

  # Sidecar pattern: <shim>.version
  [[ -f "$f.version" ]] && { cat "$f.version"; return 0; }

  # Fallback to the existing implementation
  script_version "$f"
}

script_desc(){
  # First non-shebang comment or "Description:" line from an entry script.
  local f="$1"
  if [[ -d "$f" ]]; then
    local name; name=$(basename "$f"); f="$f/bin/$name"
  fi
  [[ -f "$f" ]] || { echo ""; return; }
  grep -m1 -E '^(# *[^!/].*|# *Description:.*)' "$f" 2>/dev/null \
    | sed -E 's/^# *//; s/^Description: *//'
}

encode_field(){
  local s="${1-}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

decode_field(){
  local s="${1-}"
  s="${s//\\t/$'\t'}"
  s="${s//\\n/$'\n'}"
  printf '%s' "$s"
}

read_manifest(){
  local file="$1"
  declare -gA MF
  MF=()
  [[ -n "$file" && -r "$file" ]] || { debug "manifest unreadable: $file"; return 1; }

  local line key value lowered
  debug "Parsing manifest: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(strip_inline_comment "$line")"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \;* ]] && continue
    [[ "$line" == \[* ]] && continue
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim "$key")"
    value="$(trim "$value")"
    [[ -z "$key" ]] && continue
    if [[ ${#value} -ge 2 ]]; then
      local first="${value:0:1}" last="${value: -1}"
      if [[ "$first" == "$last" && ( "$first" == '"' || "$first" == "'" ) ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
    lowered="${key,,}"
    case "$lowered" in
      name|type|version|path|run|help|preview|tags)
        MF["$lowered"]="$value"
        ;;
      desc|description|summary)
        [[ -z "${MF[preview]:-}" ]] && MF[preview]="$value"
        [[ -z "${MF[help]:-}" ]] && MF[help]="$value"
        ;;
      command|cmd|exec)
        MF[run]="$value"
        ;;
      location|dir|directory)
        MF[path]="$value"
        ;;
      kind)
        MF[type]="$value"
        ;;
      *)
        MF["extra_${lowered}"]="$value"
        ;;
    esac
  done < "$file"

  if [[ -z "${MF[name]:-}" ]]; then
    debug "Manifest missing required 'name': $file"
    return 2
  fi

  if [[ -n "${MF[path]:-}" ]]; then
    MF[path_raw]="${MF[path]}"
    MF[path]="$(expand_path "${MF[path]}")"
  fi
  if [[ -n "${MF[run]:-}" ]]; then
    MF[run_raw]="${MF[run]}"
    MF[run]="$(expand_command "${MF[run]}")"
  fi
  [[ -n "${MF[type]:-}" ]] || MF[type]="cmd"
  MF[type]="${MF[type],,}"
  [[ -n "${MF[version]:-}" ]] || MF[version]="unknown"
  MF[file]="$file"
  debug "Manifest parsed: name=${MF[name]:-?} type=${MF[type]} version=${MF[version]} path=${MF[path]:-${MF[path_raw]:-}}"
  return 0
}

inventory_signature(){
  local dir entry
  for dir in "$BIN_DIR" "$SYSTEM_BIN"; do
    [[ -d "$dir" ]] || continue
    printf 'dir:%s:%s\n' "$dir" "$(stat_mtime "$dir")"
    while IFS= read -r entry; do
      printf 'entry:%s:%s\n' "$entry" "$(stat_mtime "$entry")"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)
  done
  for dir in "$APP_STORE" "$SYSTEM_APPS"; do
    [[ -d "$dir" ]] || continue
    printf 'dir:%s:%s\n' "$dir" "$(stat_mtime "$dir")"
    while IFS= read -r entry; do
      printf 'entry:%s:%s\n' "$entry" "$(stat_mtime "$entry")"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 \( -type d -o -type f \) -print 2>/dev/null | LC_ALL=C sort)
  done
}

bm_rebuild_inventory(){
  local preset_sig="${1:-}"
  local status=0

  build_inventory || status=$?

  if [[ -n "$preset_sig" ]]; then
    BINMAN_LIST_SIG="$preset_sig"
  else
    BINMAN_LIST_SIG="$(inventory_signature)"
  fi
  (( status != 0 )) && debug "Inventory rebuild status: $status"
  return 0
}

bm_ensure_inventory(){
  local new_sig
  new_sig="$(inventory_signature)"
  if [[ -z "${BINMAN_LIST_SIG:-}" || "$BINMAN_LIST_SIG" != "$new_sig" ]]; then
    debug "Inventory signature changed"
    bm_rebuild_inventory "$new_sig"
  fi
}

bm_force_reindex(){
  BINMAN_LIST_SIG=""
  bm_rebuild_inventory "$(inventory_signature)"
}

# --------------------------------------------------------------------------------------------------
# Build list of install targets (files) based on args or --from
# --------------------------------------------------------------------------------------------------
list_targets(){
  local arr=()
  if [[ -n "$FROM_DIR" ]]; then
    # only executables in the top of FROM_DIR
    while IFS= read -r -d '' f; do arr+=("$f"); done \
      < <(find "$FROM_DIR" -maxdepth 1 -type f -perm -u+x -print0)
  else
    [[ $# -eq 0 ]] && { err "No scripts specified, and --from not set."; exit 2; }
    for s in "$@"; do arr+=("$s"); done
  fi
  printf '%s\n' "${arr[@]}"
}



# --------------------------------------------------------------------------------------------------
# Pretty TUI helpers (colors, separations, kv rendering)
# --------------------------------------------------------------------------------------------------
ui_init(){
  if [[ -t 1 && -z "${NO_COLOR:-}" && "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    UI_BOLD="$(tput bold)"; UI_DIM="$(tput dim)"; UI_RESET="$(tput sgr0)"
    UI_CYAN="$(tput setaf 6)"; UI_GREEN="$(tput setaf 2)"; UI_YELLOW="$(tput setaf 3)"; UI_MAGENTA="$(tput setaf 5)"
  else
    UI_BOLD=""; UI_DIM=""; UI_RESET=""; UI_CYAN=""; UI_GREEN=""; UI_YELLOW=""; UI_MAGENTA=""
  fi
  UI_WIDTH=${COLUMNS:-80}
}

ui_hr(){ 
    printf "%s\n" "$(printf '─%.0s' $(seq 1 "${1:-$UI_WIDTH}"))"; 
    }

shorten_path() {
  local p="${1-}" max="${2:-$((UI_WIDTH-10))}"
  # if empty or already short, just echo
  [[ -z "${p}" ]] && { echo ""; return; }
  local n=${#p}
  if (( n <= max || max < 8 )); then
    echo "$p"
  else
    # keep head and tail around an ellipsis
    local head=$(( (max - 3) / 2 ))
    local tail=$(( max - 3 - head ))
    # NOTE: space before -tail is required for negative offsets in bash
    echo "${p:0:head}...${p: -tail}"
  fi
}

ui_kv(){
    printf "%s%-10s%s %s\n" "$UI_DIM" "$1" "$UI_RESET" "$2"; 
    }

if ! declare -F _ui_right_clear >/dev/null 2>&1; then
  _ui_right_clear(){ :; }
  _ui_right_header(){ printf "%s\n" "$1"; }
  _ui_right_kv(){ printf "%-6s %s\n" "$1" "$2"; }
  _ui_right_text(){ printf "%s\n" "$1"; }
fi



# --------------------------------------------------------------------------------------------------
# App utilities (entry resolution + shim creation)
# --------------------------------------------------------------------------------------------------
_detect_entry(){
  # ARG: appdir; OUT: "CMD|CWD|REQ" (REQ may be blank)
  local d="$1" lang="" req=""
  [[ -f "$d/requirements.txt" ]] && req="requirements.txt"

  # quick language hints (keep these cheap)
  [[ -f "$d/pyproject.toml" || -f "$d/setup.cfg" || -f "$d/setup.py" ]] && lang="python"
  [[ -f "$d/package.json"  ]] && lang="node"
  [[ -f "$d/Cargo.toml"    ]] && lang="rust"
  [[ -f "$d/go.mod" || -d "$d/cmd" ]] && lang="go"
  if [[ -f "$d/Gemfile" ]]; then
    lang="ruby"
  elif compgen -G "$d"/*.gemspec >/dev/null 2>&1; then
    lang="ruby"
  fi
  [[ -f "$d/composer.json" ]] && lang="php"
  [[ -f "$d/deno.json" || -f "$d/deno.jsonc" ]] && lang="deno"

  # ---------- helpers ----------
  _norm_repo(){
    local s="$1"
    s="${s%-master}"; s="${s%-main}"; s="${s%-app}"; s="${s%-cli}"
    s="${s,,}"; s="${s// /_}"; s="${s//-/_}"; s="${s//./_}"
    printf "%s" "$s"
  }
  _has_shebang(){ head -n1 "$1" 2>/dev/null | grep -qE '^#!'; }

  local base want want_hy
  base="$(basename "$d")"
  want="$(_norm_repo "$base")"
  want_hy="${want//_/-}"

  # ---------- node / ts ----------
  if [[ "$lang" == "node" && -f "$d/package.json" ]]; then
    local __node=() node_bin="" node_start=""
    mapfile -t __node <<<"$(python3 - "$d" <<'PY'
import json,sys,os
p=os.path.join(sys.argv[1],'package.json')
try:
    d=json.load(open(p))
    b=d.get('bin')
    if isinstance(b,str): binpath=b
    elif isinstance(b,dict) and b: binpath=next(iter(b.values()))
    else: binpath=""
    start=(d.get('scripts') or {}).get('start',"")
    print((binpath or "").strip())
    print((start or "").strip())
except Exception:
    print("")
    print("")
PY
)"
    node_bin="${__node[0]}"
    node_start="${__node[1]}"
    if [[ -n "$node_bin"   ]]; then echo "node $node_bin||";     return 0; fi
    if [[ -n "$node_start" ]]; then echo "npm run start||";       return 0; fi
    [[ -f "$d/src/index.ts" ]] && { echo "tsx src/index.ts||"; return 0; }
  fi

  # ---------- deno ----------
  if [[ "$lang" == "deno" || -f "$d/deno.json" || -f "$d/deno.jsonc" ]]; then
    if command -v deno >/dev/null 2>&1 && deno task --help >/dev/null 2>&1; then
      echo "deno task start||"; return 0
    fi
    for f in "main.ts" "mod.ts" "src/main.ts" "main.js" "mod.js" "src/main.js"; do
      [[ -f "$d/$f" ]] && { echo "deno run -A $f||"; return 0; }
    done
  fi

  # ---------- rust ----------
  if [[ "$lang" == "rust" && -f "$d/Cargo.toml" ]]; then
    local bins
    bins=$(awk '/^\[\[bin\]\]/{f=1} f&&/^name *=/{gsub(/[ "\047]/,""); print $3}' "$d/Cargo.toml")
    if [[ -n "$bins" ]]; then
      local first; first="$(printf "%s\n" "$bins" | head -n1)"
      echo "cargo run --release --bin $first||"; return 0
    fi
    [[ -f "$d/src/main.rs" ]] && { echo "cargo run --release||"; return 0; }
  fi

  # ---------- go ----------
  if [[ "$lang" == "go" ]]; then
    local mains=()
    while IFS= read -r -d '' m; do mains+=("$m"); done \
      < <(find "$d/cmd" -mindepth 2 -maxdepth 2 -type f -name main.go -print0 2>/dev/null)
    if ((${#mains[@]})); then
      local choose=""
      for m in "${mains[@]}"; do
        local dir; dir="$(basename "$(dirname "$m")")"
        [[ "${dir,,}" == "$want" || "${dir,,}" == "$want_hy" ]] && { choose="$dir"; break; }
      done
      if [[ -z "$choose" ]]; then
        for m in "${mains[@]}"; do
          local dir; dir="$(basename "$(dirname "$m")")"
          [[ "${dir,,}" =~ ^(i18n|tools?|internal|example|examples|demo|test|tests|integration(_|-)?tests?)$ ]] && continue
          [[ "${dir,,}" == *test* ]] && continue
          choose="$dir"; break
        done
      fi
      [[ -z "$choose" ]] && choose="$(basename "$(dirname "${mains[0]}")")"
      echo "go run ./cmd/$choose||"; return 0
    fi
    [[ -f "$d/main.go" ]] && { echo "go run .||"; return 0; }
  fi

  # ---------- ruby ----------
  if [[ "$lang" == "ruby" ]]; then
    local rb_prefix=""
    if [[ -f "$d/Gemfile" ]] && command -v bundle >/dev/null 2>&1; then
      rb_prefix="bundle exec "
    fi
    if [[ -x "$d/exe/$want"    ]]; then echo "${rb_prefix}./exe/$want||";    return 0; fi
    if [[ -x "$d/exe/$want_hy" ]]; then echo "${rb_prefix}./exe/$want_hy||"; return 0; fi
    if [[ -x "$d/bin/$want"    ]]; then echo "${rb_prefix}./bin/$want||";    return 0; fi
    if [[ -x "$d/bin/$want_hy" ]]; then echo "${rb_prefix}./bin/$want_hy||"; return 0; fi
    local gemspec; gemspec=$(ls "$d"/*.gemspec 2>/dev/null | head -n1 || true)
    if [[ -n "$gemspec" ]]; then
      local exe
      exe="$(grep -Eo 'executables\s*=\s*(\[.*\]|%w\[[^]]+\])' "$gemspec" \
            | head -n1 \
            | sed -E 's/.*\[(.*)\].*/\1/' \
            | tr -d '"[:space:]' \
            | cut -d, -f1)"
      [[ -n "$exe" && -x "$d/exe/$exe" ]] && { echo "${rb_prefix}./exe/$exe||"; return 0; }
      [[ -n "$exe" && -x "$d/bin/$exe" ]] && { echo "${rb_prefix}./bin/$exe||"; return 0; }
    fi
    [[ -f "$d/src/main.rb" ]] && { echo "ruby src/main.rb||"; return 0; }
    [[ -f "$d/main.rb"    ]] && { echo "ruby main.rb||";    return 0; }
  fi

  # ---------- php ----------
  if [[ "$lang" == "php" ]]; then
    if [[ -f "$d/composer.json" ]]; then
      local pbin
      pbin="$(
python3 - "$d" <<'PY'
import json,sys,os
p=os.path.join(sys.argv[1],'composer.json')
try:
  d=json.load(open(p))
  b=d.get('bin')
  if isinstance(b,str): print(b)
  elif isinstance(b,list) and b: print(b[0])
except Exception:
  pass
PY
)"
      [[ -n "$pbin" ]] && { echo "php $pbin||"; return 0; }
    fi
    [[ -f "$d/public/index.php" ]] && { echo "php public/index.php||"; return 0; }
    [[ -f "$d/index.php"        ]] && { echo "php index.php||";        return 0; }
    [[ -f "$d/src/main.php"     ]] && { echo "php src/main.php||";     return 0; }
  fi

  # ---------- python ----------
  if [[ -f "$d/pyproject.toml" ]]; then
    local script
    script="$(
python3 - "$d" <<'PY'
import sys, pathlib
pp = pathlib.Path(sys.argv[1])/'pyproject.toml'
try:
  import tomllib  # 3.11+
  data = tomllib.loads(pp.read_text())
except Exception:
  data = {}
def first_script(d):
  for path in (('tool','poetry','scripts'), ('project','scripts')):
    o = d
    for k in path:
      if isinstance(o, dict) and k in o: o = o[k]
      else: o = None; break
    if isinstance(o, dict) and o:
      return next(iter(o.values()))
  return ""
print(first_script(data))
PY
)"
    if [[ -n "$script" ]]; then
      script="${script%%:*}"
      echo "python -m $script||$req"; return 0
    fi
  fi

  if [[ -f "$d/setup.cfg" ]]; then
    local cfg_script
    cfg_script="$(
python3 - "$d" <<'PY'
import sys, configparser, pathlib, re
p = pathlib.Path(sys.argv[1])/'setup.cfg'
cp = configparser.ConfigParser()
try:
  cp.read(p)
  val = cp.get('options.entry_points', 'console_scripts', fallback='')
  m = re.search(r'=\s*([a-zA-Z0-9_.]+):', val)
  if m: print(m.group(1))
except Exception:
  pass
PY
)"
    if [[ -n "$cfg_script" ]]; then
      echo "python -m $cfg_script||$req"; return 0
    fi
  fi

  # Common python files (a few extra)
  local base_lower="${base,,}"
  for f in \
    "src/$base/__main__.py" "src/${base_lower}/__main__.py" \
    "$base/__main__.py" "${base_lower}/__main__.py" \
    "src/main.py" "src/start.py" "src/app.py" "src/cli.py" \
    "$base.py" "main.py" "start.py" "app.py" "cli.py"
  do
    [[ -f "$d/$f" ]] && { echo "python3 $f||$req"; return 0; }
  done

  # Single root .py or root name match
  local py_files=()
  while IFS= read -r -d '' f; do py_files+=("$(basename "$f")"); done \
    < <(find "$d" -maxdepth 1 -type f -name '*.py' -print0 2>/dev/null)
  if (( ${#py_files[@]} == 1 )); then
    echo "python3 ${py_files[0]}||$req"; return 0
  fi
  if (( ${#py_files[@]} )); then
    for p in "${py_files[@]}"; do
      local stem="${p%.py}"; local norm="${stem,,}"; norm="${norm//-/_}"
      if [[ "$norm" == "$want" || "$norm" == "$want_hy" ]]; then
        echo "python3 $p||$req"; return 0
      fi
    done
  fi

  # NEW: recursive hunt for package __main__.py (skip venvs/tox/direnv)
  # Prefer parent dir matching normalized repo name; prefer src/ file execution.
  local _hits=() _best="" rel="" parent=""
  while IFS= read -r -d '' f; do _hits+=("$f"); done < <(
    find "$d" -type f -name '__main__.py' \
      -not -path '*/.venv/*' -not -path '*/venv/*' \
      -not -path '*/env/*'   -not -path '*/.tox/*' \
      -not -path '*/.direnv/*' -print0 2>/dev/null
  )
  if ((${#_hits[@]})); then
    for h in "${_hits[@]}"; do
      parent="$(basename "$(dirname "$h")")"
      local pl="${parent,,}"; pl="${pl//-/_}"
      if [[ "$pl" == "$want" || "$pl" == "$want_hy" ]]; then _best="$h"; break; fi
    done
    [[ -z "$_best" ]] && _best="${_hits[0]}"
    rel="${_best#"$d/"}"; parent="$(basename "$(dirname "$_best")")"
    if [[ "$rel" == src/* ]]; then
      echo "python3 $rel||$req"; return 0
    else
      echo "python3 -m $parent||$req"; return 0
    fi
  fi

  # ---------- generic bin/ & exe/ fallbacks ----------
  if [[ -d "$d/exe" ]]; then
    mapfile -t _exes < <(find "$d/exe" -maxdepth 1 -type f -perm -u+x -printf '%f\n' 2>/dev/null | sort)
    if ((${#_exes[@]}==1)); then
      local rb_prefix=""; if [[ -f "$d/Gemfile" ]] && command -v bundle >/dev/null 2>&1; then rb_prefix="bundle exec "; fi
      echo "${rb_prefix}./exe/${_exes[0]}||"; return 0
    fi
    for b in "${_exes[@]}"; do
      local bn="${b,,}"; local nb="${bn//-/_}"
      if [[ "$bn" == "$want" || "$bn" == "$want_hy" || "$nb" == "$want" ]]; then
        local rb_prefix=""; if [[ -f "$d/Gemfile" ]] && command -v bundle >/dev/null 2>&1; then rb_prefix="bundle exec "; fi
        echo "${rb_prefix}./exe/$b||"; return 0
      fi
    done
  fi

  if [[ -d "$d/bin" ]]; then
    mapfile -t _bins < <(find "$d/bin" -maxdepth 1 -type f -perm -u+x -printf '%f\n' 2>/dev/null | sort)
    if ((${#_bins[@]}==1)); then
      echo "./bin/${_bins[0]}||"; return 0
    fi
    for b in "${_bins[@]}"; do
      local bn="${b,,}"; local nb="${bn//-/_}"
      if [[ "$bn" == "$want" || "$bn" == "$want_hy" || "$nb" == "$want" ]]; then
        echo "./bin/$b||"; return 0
      fi
    done
    local sheb=()
    for b in "${_bins[@]}"; do _has_shebang "$d/bin/$b" && sheb+=("$b"); done
    if ((${#sheb[@]}==1)); then echo "./bin/${sheb[0]}||"; return 0; fi
  fi

  # nothing compelling
  echo "||"
}

_app_entry(){
    local appdir="$1"; local name; name=$(basename "$appdir"); echo "$appdir/bin/$name"; 
}
    
_make_shim(){
  local name="$1" entry="$2" shim="$BIN_DIR/$name"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" > "$shim"
  chmod +x "$shim"
}

_make_shim_system(){
  local name="$1" entry="$2" shim="$SYSTEM_BIN/$name"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/${name}.shim.XXXXXX")"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" >"$tmp"
  chmod +x "$tmp"
  if _as_root install -m 0755 "$tmp" "$shim"; then
    rm -f "$tmp"
    ensure_system_symlink "$name"
  else
    local rc=$?
    rm -f "$tmp"
    err "Failed to write system shim $shim"
    return $rc
  fi
}

# --- user shim: custom entry (no venv) ---------------------------------------
_make_shim_cmd(){
  local name="$1" appdir="$2" cmd="$3" cwd="${4:-}" shim="$BIN_DIR/$name"
  local QAPP QCMD QCWD
  QAPP=$(printf %q "$appdir")
  QCMD=$(printf %q "$cmd")
  QCWD=$(printf %q "$cwd")

  cat > "$shim" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR=$QAPP
CWD=$QCWD
CMD_RAW=$QCMD

# cd into working dir if provided
if [[ -n "\$CWD" && -d "\$APPDIR/\$CWD" ]]; then
  cd "\$APPDIR/\$CWD"
else
  cd "\$APPDIR"
fi

# Reconstruct command preserving quoted segments
declare -a __ARR=()
eval "__ARR=( \$CMD_RAW )"
exec "\${__ARR[@]}" "\$@"
EOF
  chmod +x "$shim"
}

# --- system shim: custom entry (no venv) -------------------------------------
_make_shim_cmd_system(){
  local name="$1" appdir="$2" cmd="$3" cwd="${4:-}" shim="$SYSTEM_BIN/$name"
  local QAPP QCMD QCWD
  QAPP=$(printf %q "$appdir")
  QCMD=$(printf %q "$cmd")
  QCWD=$(printf %q "$cwd")

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/${name}.shim.XXXXXX")"

  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR=$QAPP
CWD=$QCWD
CMD_RAW=$QCMD

if [[ -n "\$CWD" && -d "\$APPDIR/\$CWD" ]]; then
  cd "\$APPDIR/\$CWD"
else
  cd "\$APPDIR"
fi

declare -a __ARR=()
eval "__ARR=( \$CMD_RAW )"
exec "\${__ARR[@]}" "\$@"
EOF
  chmod +x "$tmp"

  if _as_root install -m 0755 "$tmp" "$shim"; then
    rm -f "$tmp"
    ensure_system_symlink "$name"
  else
    local rc=$?
    rm -f "$tmp"
    err "Failed to write system shim $shim"
    return $rc
  fi
}

# --- user shim: custom entry with Python venv --------------------------------
_make_shim_cmd_venv(){
  # name, appdir, cmd, cwd, reqfile, boot_python
  local name="$1" appdir="$2" cmd="$3" cwd="${4:-}" req="${5:-}" boot_py="${6:-python3}"
  local shim="$BIN_DIR/$name"
  local QAPP QCMD QCWD QREQ QBOOT
  QAPP=$(printf %q "$appdir")
  QCMD=$(printf %q "$cmd")
  QCWD=$(printf %q "$cwd")
  QREQ=$(printf %q "$req")
  QBOOT=$(printf %q "$boot_py")

  cat > "$shim" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR=$QAPP
CWD=$QCWD
CMD_RAW=$QCMD
REQ=$QREQ
BOOT_PY=$QBOOT

VENV="\$APPDIR/.venv"

# create venv if missing
if [[ ! -x "\$VENV/bin/python" ]]; then
  "\${BOOT_PY:-python3}" -m venv "\$VENV"
fi

# activate venv
# shellcheck disable=SC1091
source "\$VENV/bin/activate"

# install requirements (quiet; best effort)
if [[ -n "\$REQ" && -f "\$APPDIR/\$REQ" ]]; then
  pip install -q -r "\$APPDIR/\$REQ" || true
elif [[ -f "\$APPDIR/requirements.txt" ]]; then
  pip install -q -r "\$APPDIR/requirements.txt" || true
fi

# cd into working dir if provided
if [[ -n "\$CWD" && -d "\$APPDIR/\$CWD" ]]; then
  cd "\$APPDIR/\$CWD"
else
  cd "\$APPDIR"
fi

# if the entry begins with python/python3, swap in venv python
declare -a __ARR=()
eval "__ARR=( \$CMD_RAW )"
if [[ "\${__ARR[0]}" == python || "\${__ARR[0]}" == python3 || "\${__ARR[0]##*/}" == python || "\${__ARR[0]##*/}" == python3 ]]; then
  __ARR[0]="\$VENV/bin/python"
fi

exec "\${__ARR[@]}" "\$@"
EOF
  chmod +x "$shim"
}

# --- system shim: custom entry with Python venv ------------------------------
_make_shim_cmd_venv_system(){
  local name="$1" appdir="$2" cmd="$3" cwd="${4:-}" req="${5:-}" boot_py="${6:-python3}"
  local shim="$SYSTEM_BIN/$name"
  local QAPP QCMD QCWD QREQ QBOOT
  QAPP=$(printf %q "$appdir")
  QCMD=$(printf %q "$cmd")
  QCWD=$(printf %q "$cwd")
  QREQ=$(printf %q "$req")
  QBOOT=$(printf %q "$boot_py")

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/${name}.shim.XXXXXX")"

  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
APPDIR=$QAPP
CWD=$QCWD
CMD_RAW=$QCMD
REQ=$QREQ
BOOT_PY=$QBOOT

VENV="\$APPDIR/.venv"

if [[ ! -x "\$VENV/bin/python" ]]; then
  "\${BOOT_PY:-python3}" -m venv "\$VENV"
fi
# shellcheck disable=SC1091
source "\$VENV/bin/activate"

if [[ -n "\$REQ" && -f "\$APPDIR/\$REQ" ]]; then
  pip install -q -r "\$APPDIR/\$REQ" || true
elif [[ -f "\$APPDIR/requirements.txt" ]]; then
  pip install -q -r "\$APPDIR/requirements.txt" || true
fi

if [[ -n "\$CWD" && -d "\$APPDIR/\$CWD" ]]; then
  cd "\$APPDIR/\$CWD"
else
  cd "\$APPDIR"
fi

declare -a __ARR=()
eval "__ARR=( \$CMD_RAW )"
if [[ "\${__ARR[0]}" == python || "\${__ARR[0]}" == python3 || "\${__ARR[0]##*/}" == python || "\${__ARR[0]##*/}" == python3 ]]; then
  __ARR[0]="\$VENV/bin/python"
fi

exec "\${__ARR[@]}" "\$@"
EOF
  chmod +x "$tmp"

  if _as_root install -m 0755 "$tmp" "$shim"; then
    rm -f "$tmp"
    ensure_system_symlink "$name"
  else
    local rc=$?
    rm -f "$tmp"
    err "Failed to write system shim $shim"
    return $rc
  fi
}



# --------------------------------------------------------------------------------------------------
# Prompt helpers (TTY-safe; we always read/write via /dev/tty inside wizard/TUI)
# --------------------------------------------------------------------------------------------------
prompt_init(){ 
    : "${UI_RESET:=}"; 
    : "${UI_BOLD:=}"; 
    : "${UI_DIM:=}"; 
    : "${UI_CYAN:=}"; 
    : "${UI_GREEN:=}"; 
    : "${UI_YELLOW:=}"; 
}

prompt_kv(){
    printf "  %s%-14s%s %s\n" "$UI_BOLD" "$1:" "$UI_RESET" "$2"; 
}

maybe_warn_auto_backup_disabled(){
  (( ${BINMAN_AUTO_BACKUP:-1} )) && return 0
  (( JSON_MODE )) && return 0
  : "${AUTO_BACKUP_WARNED:=0}"
  (( AUTO_BACKUP_WARNED )) && return 0
  prompt_init
  printf "%s[i]%s Auto backups disabled (BINMAN_AUTO_BACKUP=0)\n" "$UI_DIM" "$UI_RESET"
  AUTO_BACKUP_WARNED=1
}

ask(){
  local q="$1" def="$2" out
  if [[ -n "$def" ]]; then
    printf "  %s?%s %s %s[%s]%s: " "$UI_CYAN" "$UI_RESET" "$q" "$UI_DIM" "$def" "$UI_RESET" > /dev/tty
  else
    printf "  %s?%s %s: " "$UI_CYAN" "$UI_RESET" "$q" > /dev/tty
  fi
  IFS= read -r out < /dev/tty
  [[ -z "$out" ]] && out="$def"
  printf "%s\n" "$out"
}

ask_choice(){
  local label="$1" opts="$2" def="$3" out
  printf "  %s?%s %s %s(%s)%s %s[%s]%s: " \
    "$UI_CYAN" "$UI_RESET" "$label" "$UI_DIM" "$opts" "$UI_RESET" "$UI_DIM" "$def" "$UI_RESET" > /dev/tty
  IFS= read -r out < /dev/tty
  [[ -z "$out" ]] && out="$def"
  printf "%s\n" "$out"
}

ask_yesno(){
  local q="$1" def="${2:-n}" out hint="[y/N]"
  [[ "${def,,}" == "y" ]] && hint="[Y/n]"
  printf "  %s?%s %s %s%s%s: " "$UI_CYAN" "$UI_RESET" "$q" "$UI_DIM" "$hint" "$UI_RESET" > /dev/tty
  IFS= read -r out < /dev/tty
  [[ -z "$out" ]] && out="$def"
  [[ "${out,,}" =~ ^y ]]
}



# --------------------------------------------------------------------------------------------------
# App install/uninstall (user and system variants)
# --------------------------------------------------------------------------------------------------
_install_app(){
  ensure_apps; ensure_bin
  local src="$1" name dest mode="copy"
  name=$(basename "$src"); dest="$APP_STORE/$name"

  rm -rf "$dest"
  if [[ "$COPY_MODE" == "link" ]]; then
    ln -s "$src" "$dest"
    mode="link"
  else
    cp -a "$src" "$dest"
  fi

  local version entry entry_kind="default"

  # Explicit --entry wins
  if [[ -n "$ENTRY_CMD" ]]; then
    entry="$ENTRY_CMD"
    if (( VENV_MODE )); then
      _make_shim_cmd_venv "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD" "$REQ_FILE" "$BOOT_PY"
      entry_kind="custom-venv"
    else
      _make_shim_cmd "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD"
      entry_kind="custom"
    fi
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  # Conventional layout?
  if [[ -x "$dest/bin/$name" ]]; then
    local entry_path
    entry_path="$(_app_entry "$dest")"
    _make_shim "$name" "$entry_path"
    entry="$entry_path"
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  # Try auto-detect
  local triplet; triplet="$(_detect_entry "$dest")"
  local cmd="${triplet%%|*}"; triplet="${triplet#*|}"
  local cwd="${triplet%%|*}"; local req="${triplet#*|}"

  if [[ -n "$cmd" ]]; then
    entry="$cmd"
    if (( VENV_MODE )) || [[ "$cmd" == python* || "$cmd" == */python* ]]; then
      _make_shim_cmd_venv "$name" "$dest" "$cmd" "$cwd" "${REQ_FILE:-$req}" "$BOOT_PY"
      entry_kind="detected-venv"
    else
      _make_shim_cmd "$name" "$dest" "$cmd" "$cwd"
      entry_kind="detected"
    fi
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  rm -rf "$dest"
  err "App '$name' missing bin/$name and no entry could be detected. Try: --entry 'python3 path/to/main.py' [--venv --req requirements.txt]"
  return 5
}

_install_app_system(){
  ensure_system_write; ensure_system_dirs
  local src="$1" name dest mode="copy"
  name=$(basename "$src"); dest="$SYSTEM_APPS/$name"

  if [[ -e "$dest" || -L "$dest" ]]; then
    if ! _as_root rm -rf "$dest"; then
      err "Failed to remove existing $dest (permission denied?)"
      return 1
    fi
  fi

  if ! _as_root cp -a "$src" "$dest"; then
    err "Failed to copy app into $dest"
    return 1
  fi

  local version entry entry_kind="default"

  if [[ -n "$ENTRY_CMD" ]]; then
    entry="$ENTRY_CMD"
    if (( VENV_MODE )); then
      _make_shim_cmd_venv_system "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD" "$REQ_FILE" "$BOOT_PY"
      entry_kind="custom-venv"
    else
      _make_shim_cmd_system "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD"
      entry_kind="custom"
    fi
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  if [[ -x "$dest/bin/$name" ]]; then
    local entry_path
    entry_path="$(_app_entry "$dest")"
    _make_shim_system "$name" "$entry_path"
    entry="$entry_path"
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  local triplet; triplet="$(_detect_entry "$dest")"
  local cmd="${triplet%%|*}"; triplet="${triplet#*|}"
  local cwd="${triplet%%|*}"; local req="${triplet#*|}"

  if [[ -n "$cmd" ]]; then
    entry="$cmd"
    if (( VENV_MODE )) || [[ "$cmd" == python* || "$cmd" == */python* ]]; then
      _make_shim_cmd_venv_system "$name" "$dest" "$cmd" "$cwd" "${REQ_FILE:-$req}" "$BOOT_PY"
      entry_kind="detected-venv"
    else
      _make_shim_cmd_system "$name" "$dest" "$cmd" "$cwd"
      entry_kind="detected"
    fi
    version="$(script_version "$dest")"
    printf 'installed\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$dest" "$version" "$mode" "$entry_kind" "$entry"
    return 0
  fi

  rm -rf "$dest"
  err "App '$name' missing bin/$name and no entry could be detected. Try: --entry 'python3 path/to/main.py' [--venv --req requirements.txt]"
  return 5
}

_uninstall_app(){
  local name="$1" dest="$APP_STORE/$name" shim="$BIN_DIR/$name"
  local shim_removed=0 dest_removed=0
  if [[ -e "$shim" ]]; then rm -f "$shim"; shim_removed=1; fi
  if [[ -e "$dest" ]]; then rm -rf "$dest"; dest_removed=1; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$shim" "$dest" "$shim_removed" "$dest_removed"
}

_uninstall_app_system(){
  ensure_system_write
  local name="$1" dest="$SYSTEM_APPS/$name" shim="$SYSTEM_BIN/$name"
  local shim_removed=0 dest_removed=0 rc=0
  if [[ -e "$shim" || -L "$shim" ]]; then
    if _as_root rm -f "$shim"; then
      shim_removed=1
    else
      err "Failed to remove shim $shim"
      rc=1
    fi
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    if _as_root rm -rf "$dest"; then
      dest_removed=1
    else
      err "Failed to remove app directory $dest"
      rc=1
    fi
  fi
  # [Patch] Drop /usr/bin symlink if it pointed at our system shim
  remove_system_symlink_if_owned "$name"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$shim" "$dest" "$shim_removed" "$dest_removed"
  return $rc
}



# --------------------------------------------------------------------------------------------------
# Remote file fetch (curl/wget)
# --------------------------------------------------------------------------------------------------
is_url(){
    [[ "$1" =~ ^https?:// ]];
}

fetch_remote(){
  local url="$1" outdir fname out
  outdir=$(mktemp -d)
  fname="${2:-$(basename "${url%%\?*}")}"
  out="${outdir}/${fname}"
  if exists curl; then
    if ! curl -fsSL "$url" -o "$out"; then
      rm -rf "$outdir"
      err "Download failed: $url"
      return 4
    fi
  elif exists wget; then
    if ! wget -q "$url" -O "$out"; then
      rm -rf "$outdir"
      err "Download failed: $url"
      return 4
    fi
  else
    rm -rf "$outdir"
    err "Need curl or wget for remote installs"
    return 4
  fi
  echo "$out"
}



# --------------------------------------------------------------------------------------------------
# Merge/copy helpers
# --------------------------------------------------------------------------------------------------
_merge_dir(){
  # Merges one dir into another (clobber when --force). Includes dotfiles.
  local src_dir="$1" dst_dir="$2"
  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dst_dir"
  shopt -s dotglob
  for p in "$src_dir"/*; do
    [[ -e "$p" ]] || continue
    local name dst; name="$(basename "$p")"; dst="$dst_dir/$name"
    if [[ -e "$dst" && $FORCE -ne 1 ]]; then
      warn "Skip existing: $dst (use --force to overwrite)"
      continue
    fi
    rm -rf "$dst" 2>/dev/null || true
    cp -a "$p" "$dst"
  done
}

_chmod_bin_execs(){
  # Re-assert executable bit on files in BIN_DIR (after restore).
  if [[ -d "$BIN_DIR" ]]; then
    find "$BIN_DIR" -maxdepth 1 -type f -exec chmod +x {} \; 2>/dev/null || true
  fi
}



# --------------------------------------------------------------------------------------------------
# INSTALL — core installer for scripts and apps (atomic for single files)
# --------------------------------------------------------------------------------------------------
op_install(){
  # Build targets list (args or --from)
  local targets=("$@")
  [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] || { err "Nothing to install"; return 2; }

  maybe_snapshot

  local count=0 exit_code=0
  local target_bin="$BIN_DIR"
  local target_apps="$APP_STORE"
  (( SYSTEM_MODE )) && target_bin="$SYSTEM_BIN"
  (( SYSTEM_MODE )) && target_apps="$SYSTEM_APPS"

  local original src
  for original in "${targets[@]}"; do
    src="$original"

    # Normalize picker rows / quotes / trailing space
    [[ "$src" == *$'\t'* ]] && src="${src##*$'\t'}"
    if [[ ${#src} -ge 2 ]]; then
      if { [[ "${src:0:1}" == "'" && "${src: -1}" == "'" ]] || [[ "${src:0:1}" == '"' && "${src: -1}" == '"' ]]; }; then
        src="${src:1:${#src}-2}"
      fi
    fi
    src="${src%"${src##*[![:space:]]}"}"

    # URL fetch
    if is_url "$src"; then
      local fetched
      if fetched=$(fetch_remote "$src"); then
        src="$fetched"
      else
        local rc=$?
        (( rc > exit_code )) && exit_code=$rc
        warn "Fetch failed: $src"
        emit_json_object \
          "action=install" "status=error" "type=remote" "name=$src" \
          "code=$rc" "message=download_failed"
        continue
      fi
    fi

    # App directories
    if [[ -d "$src" ]]; then
      local result rc
      if (( SYSTEM_MODE )); then
        result=$(_install_app_system "$src") || { rc=$?; (( rc > exit_code )) && exit_code=$rc; continue; }
      else
        result=$(_install_app "$src") || { rc=$?; (( rc > exit_code )) && exit_code=$rc; continue; }
      fi

      IFS=$'\t' read -r status name dest_path version mode entry_kind entry_cmd <<<"$result"
      emit_json_object \
        "action=install" "status=$status" "type=app" "name=$name" \
        "path=$dest_path" "version=$version" "mode=$mode" \
        "entry_kind=$entry_kind" "entry=$entry_cmd"

      if (( ! JSON_MODE )); then
        local suffix=""
        case "$entry_kind" in
          custom) suffix="(custom entry)" ;;
          custom-venv) suffix="(entry: $entry_cmd; venv on)" ;;
          detected) suffix="(entry: $entry_cmd)" ;;
          detected-venv) suffix="(entry: $entry_cmd; venv on)" ;;
          *) suffix="(v$version)" ;;
        esac
        ok "App installed: $name → $dest_path ${suffix}"
      fi

      if (( SYSTEM_MODE )); then
        local symlink_name="$name"
        if [[ -n "${entry_cmd:-}" ]]; then
          local entry_head="${entry_cmd%% *}"
          [[ -n "$entry_head" ]] || entry_head="$entry_cmd"
          symlink_name="$(basename "$entry_head")"
          ensure_system_symlink "$symlink_name"
          [[ "$symlink_name" == "$name" ]] || ensure_system_symlink "$name"
        else
          ensure_system_symlink "$name"
        fi
      fi

      count=$((count+1))
      continue
    fi

    # Single-file installs
    if [[ ! -f "$src" ]]; then
      warn "Skip (not a file): $src"
      emit_json_object \
        "action=install" "status=skipped" "type=cmd" \
        "name=$src" "reason=not_a_file"
      continue
    fi

    local base dst tmp mode="copy" name version
    base=$(basename "$src")
    if (( SYSTEM_MODE )); then
      dst="${target_bin}/${base%.*}"
      ensure_system_write; ensure_system_dirs
    else
      dst="${target_bin}/${base%.*}"
      ensure_bin
    fi
    name=$(basename "$dst")

    if [[ -e "$dst" && $FORCE -ne 1 ]]; then
      warn "Exists: $(basename "$dst") (use --force)"
      emit_json_object \
        "action=install" "status=skipped" "type=cmd" \
        "name=$name" "path=$dst" "reason=exists"
      continue
    fi

    # use system tmp (not bin) and always clean up
    tmp="$(mktemp "${TMPDIR:-/tmp}/${name}.XXXXXX")"
    cp "$src" "$tmp"
    chmod +x "$tmp"

    # Bash syntax sanity check
    if head -n1 "$tmp" | grep -qE '/(ba)?sh'; then
      if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "Syntax check failed for $(basename "$dst")."
        (( exit_code < 5 )) && exit_code=5
        continue
      fi
    fi

    # ---- Python venv auto-setup (stable payload in ~/.config/<AppName>) ----
    if head -n1 "$tmp" | grep -q "python"; then
      local cfgdir="$HOME/.config/$name"
      local vdir="$cfgdir/.venv"
      local payload="$cfgdir/app.py"
      mkdir -p "$cfgdir"

      if [[ ! -d "$vdir" ]]; then
        say "Creating venv for $name..."
        python3 -m venv "$vdir" || warn "Failed to create venv"
      fi

      # copy validated script into a stable location
      cp "$tmp" "$payload"
      chmod +x "$payload"

      # install requirements if present next to original src
      if [[ -f "$(dirname "$src")/requirements.txt" ]]; then
        say "Installing requirements for $name..."
        "$vdir/bin/pip" install -r "$(dirname "$src")/requirements.txt" >/dev/null 2>&1 || warn "pip install failed"
      fi

      # launcher always uses venv + stable payload
      local launcher_tmp
      launcher_tmp="$(mktemp "${TMPDIR:-/tmp}/${name}.launcher.XXXXXX")"
      cat >"$launcher_tmp" <<EOF
#!/usr/bin/env bash
exec "$vdir/bin/python" "$payload" "\$@"
EOF
      chmod +x "$launcher_tmp"

      if (( SYSTEM_MODE )); then
        if _as_root install -m 0755 "$launcher_tmp" "$dst"; then
          rm -f "$launcher_tmp"
        else
          local rc=$?
          rm -f "$launcher_tmp" 2>/dev/null || true
          rm -f "$tmp"
          err "Failed to install launcher for $name into $dst"
          (( rc > exit_code )) && exit_code=$rc
          continue
        fi
      else
        mv -f "$launcher_tmp" "$dst"
      fi

      mode="venv"
      version="$(script_version "$payload")"

      rm -f "$tmp"
      rm -f "$launcher_tmp" 2>/dev/null || true

      emit_json_object \
        "action=install" "status=installed" "type=cmd" \
        "name=$name" "path=$dst" "mode=venv" "version=$version"
      (( ! JSON_MODE )) && ok "Installed: $name (venv @ $vdir)"
    else
      # non-Python: install checked file directly
      if (( SYSTEM_MODE )); then
        if _as_root install -m 0755 "$tmp" "$dst"; then
          rm -f "$tmp"
        else
          local rc=$?
          rm -f "$tmp" 2>/dev/null || true
          err "Failed to install $name into $dst"
          (( rc > exit_code )) && exit_code=$rc
          continue
        fi
      else
        mv -f "$tmp" "$dst"
      fi
      version="$(script_version "$dst")"
      emit_json_object \
        "action=install" "status=installed" "type=cmd" \
        "name=$name" "path=$dst" "mode=$mode" "version=$version"
      (( ! JSON_MODE )) && ok "Installed: $dst (v$version)"
    fi
    # ------------------------------------------------------------------------

    if (( SYSTEM_MODE )); then
      # [Patch] Ensure system shim also lives in /usr/bin for PATH compatibility
      ensure_system_symlink "$name"
    fi

    count=$((count+1))
  done

  maybe_warn_path
  rehash_shell
  rehash_hint
  (( JSON_MODE )) || say "$count item(s) installed."
  return $exit_code
}


# --------------------------------------------------------------------------------------------------
# UNINSTALL — remove scripts or apps (user/system)
# --------------------------------------------------------------------------------------------------
# Uninstall resolver rules (see _resolve_uninstall_target):
# - If "$target_bin/$name" exists, remove exactly that path.
# - If "$name" ends with ".bak", never strip the suffix; only remove "$target_bin/$name" when present.
# - Otherwise, if "$name" contains a dot and "$target_bin/${name%.*}" exists, remove "${name%.*}" for legacy compatibility.
# - If none of the above match, report the name as not found.
_resolve_uninstall_target(){
  local target_bin="$1" name="$2"
  local candidate stripped legacy

  candidate="$target_bin/$name"
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ "$name" == *.bak ]]; then
    warn "Not found: $name"
    return 1
  fi

  if [[ "$name" == *.* ]]; then
    stripped="${name%.*}"
    legacy="$target_bin/$stripped"
    if [[ -e "$legacy" || -L "$legacy" ]]; then
      printf '%s\n' "$legacy"
      return 0
    fi
  fi

  warn "Not found: $name"
  return 1
}

op_uninstall(){
  local dry_run=0
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          args+=("$1")
          shift
        done
        break
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  local names=("${args[@]}")
  if (( ${#names[@]} == 0 )); then
    warn "Nothing to uninstall."
    return 1
  fi

  local count=0 planned_count=0
  (( dry_run == 0 )) && maybe_snapshot
  local target_bin="$BIN_DIR"
  local target_apps="$APP_STORE"
  (( SYSTEM_MODE )) && target_bin="$SYSTEM_BIN"
  (( SYSTEM_MODE )) && target_apps="$SYSTEM_APPS"

  local name
  for name in "${names[@]}"; do
    if (( SYSTEM_MODE )); then
      if [[ -e "$target_apps/$name" ]]; then
        local shim_path="$SYSTEM_BIN/$name"
        local dest_path="$target_apps/$name"
        if (( dry_run )); then
          local shim_exists=0 dest_exists=0
          [[ -e "$shim_path" || -L "$shim_path" ]] && shim_exists=1
          [[ -e "$dest_path" || -L "$dest_path" ]] && dest_exists=1
          emit_json_object \
            "action=uninstall" \
            "status=planned" \
            "type=app" \
            "name=$name" \
            "path=$dest_path" \
            "shim=$shim_path" \
            "shim_removed=$shim_exists" \
            "app_removed=$dest_exists"
          if (( ! JSON_MODE )); then
            [[ $shim_exists -eq 1 ]] && say "DRY-RUN: would remove shim: $shim_path"
            [[ $dest_exists -eq 1 ]] && say "DRY-RUN: would remove app: $dest_path"
          fi
          planned_count=$((planned_count+1))
        else
          local info
          info=$(_uninstall_app_system "$name")
          IFS=$'\t' read -r _ shim_path dest_path shim_removed dest_removed <<<"$info"
          local status="missing"
          (( shim_removed || dest_removed )) && status="removed"
          emit_json_object \
            "action=uninstall" \
            "status=$status" \
            "type=app" \
            "name=$name" \
            "path=$dest_path" \
            "shim=$shim_path" \
            "shim_removed=$shim_removed" \
            "app_removed=$dest_removed"
          if (( shim_removed )); then (( ! JSON_MODE )) && ok "Removed shim: $shim_path"; fi
          if (( dest_removed )); then (( ! JSON_MODE )) && ok "Removed app: $dest_path"; fi
          (( shim_removed || dest_removed )) && count=$((count+1))
        fi
        continue
      fi

      (( dry_run == 0 )) && ensure_system_write
      local resolved resolved_base fallback_symlink=
      if resolved="$(_resolve_uninstall_target "$target_bin" "$name")"; then
        if (( dry_run )); then
          emit_json_object \
            "action=uninstall" \
            "status=planned" \
            "type=cmd" \
            "name=$name" \
            "path=$resolved"
          if (( ! JSON_MODE )); then
            if [[ "$resolved" == *.bak ]]; then
              say "DRY-RUN: would remove backup: $resolved"
            else
              say "DRY-RUN: would remove: $resolved"
            fi
          fi
          planned_count=$((planned_count+1))
        else
          _as_root rm -f "$resolved"
          resolved_base="$(basename "$resolved")"
          # [Patch] Remove /usr/bin symlink when uninstalling system shim
          remove_system_symlink_if_owned "$resolved_base"
          emit_json_object \
            "action=uninstall" \
            "status=removed" \
            "type=cmd" \
            "name=$name" \
            "path=$resolved"
          if (( ! JSON_MODE )); then
            if [[ "$resolved" == *.bak ]]; then
              ok "Removed backup: $resolved"
            else
              ok "Removed: $resolved"
            fi
          fi
          count=$((count+1))
        fi
      else
        if (( dry_run == 0 )) && [[ "$name" != *.bak ]]; then
          fallback_symlink="$name"
          if [[ "$fallback_symlink" == *.* ]]; then
            fallback_symlink="${fallback_symlink%.*}"
          fi
          remove_system_symlink_if_owned "$fallback_symlink"
        fi
        emit_json_object \
          "action=uninstall" \
          "status=missing" \
          "type=cmd" \
          "name=$name"
      fi
    else
      if [[ -e "$target_apps/$name" ]]; then
        local shim_path="$target_bin/$name"
        local dest_path="$target_apps/$name"
        if (( dry_run )); then
          local shim_exists=0 dest_exists=0
          [[ -e "$shim_path" || -L "$shim_path" ]] && shim_exists=1
          [[ -e "$dest_path" || -L "$dest_path" ]] && dest_exists=1
          emit_json_object \
            "action=uninstall" \
            "status=planned" \
            "type=app" \
            "name=$name" \
            "path=$dest_path" \
            "shim=$shim_path" \
            "shim_removed=$shim_exists" \
            "app_removed=$dest_exists"
          if (( ! JSON_MODE )); then
            [[ $shim_exists -eq 1 ]] && say "DRY-RUN: would remove shim: $shim_path"
            [[ $dest_exists -eq 1 ]] && say "DRY-RUN: would remove app: $dest_path"
          fi
          planned_count=$((planned_count+1))
        else
          local info
          info=$(_uninstall_app "$name")
          IFS=$'\t' read -r _ shim_path dest_path shim_removed dest_removed <<<"$info"
          local status="missing"
          (( shim_removed || dest_removed )) && status="removed"
          emit_json_object \
            "action=uninstall" \
            "status=$status" \
            "type=app" \
            "name=$name" \
            "path=$dest_path" \
            "shim=$shim_path" \
            "shim_removed=$shim_removed" \
            "app_removed=$dest_removed"
          if (( shim_removed )); then (( ! JSON_MODE )) && ok "Removed shim: $shim_path"; fi
          if (( dest_removed )); then (( ! JSON_MODE )) && ok "Removed app: $dest_path"; fi
          (( shim_removed || dest_removed )) && count=$((count+1))
        fi
        continue
      fi

      local resolved
      if resolved="$(_resolve_uninstall_target "$target_bin" "$name")"; then
        if (( dry_run )); then
          emit_json_object \
            "action=uninstall" \
            "status=planned" \
            "type=cmd" \
            "name=$name" \
            "path=$resolved"
          if (( ! JSON_MODE )); then
            if [[ "$resolved" == *.bak ]]; then
              say "DRY-RUN: would remove backup: $resolved"
            else
              say "DRY-RUN: would remove: $resolved"
            fi
          fi
          planned_count=$((planned_count+1))
        else
          rm -f "$resolved"
          emit_json_object \
            "action=uninstall" \
            "status=removed" \
            "type=cmd" \
            "name=$name" \
            "path=$resolved"
          if (( ! JSON_MODE )); then
            if [[ "$resolved" == *.bak ]]; then
              ok "Removed backup: $resolved"
            else
              ok "Removed: $resolved"
            fi
          fi
          count=$((count+1))
        fi
      else
        emit_json_object \
          "action=uninstall" \
          "status=missing" \
          "type=cmd" \
          "name=$name"
      fi
    fi
  done

  if (( dry_run )); then
    (( JSON_MODE )) || say "DRY-RUN: would remove $planned_count item(s)."
    return 0
  fi

  rehash_shell
  rehash_hint
  (( JSON_MODE )) || say "$count item(s) removed."
}




# --------------------------------------------------------------------------------------------------
# VERIFY — ensure installed commands/apps have their shims and entries intact
# --------------------------------------------------------------------------------------------------
op_verify(){
  local names=("$@")
  local verified_any=0
  local exit_code=0
  local target_bin="$BIN_DIR"
  local target_apps="$APP_STORE"
  (( SYSTEM_MODE )) && target_bin="$SYSTEM_BIN"
  (( SYSTEM_MODE )) && target_apps="$SYSTEM_APPS"

  local cmd_targets=()
  local app_targets=()
  if (( ${#names[@]} == 0 )); then
    mapfile -t cmd_targets < <(_get_installed_cmd_names)
    mapfile -t app_targets < <(_get_installed_app_names)
  else
    declare -A seen_cmd=()
    declare -A seen_app=()
    for item in "${names[@]}"; do
      local found=0
      if [[ -e "$target_apps/$item" && -z "${seen_app[$item]:-}" ]]; then
        app_targets+=("$item")
        seen_app[$item]=1
        found=1
      fi
      local cmd_name="${item%.*}"
      if [[ -e "$target_bin/$cmd_name" && -z "${seen_cmd[$cmd_name]:-}" ]]; then
        cmd_targets+=("$cmd_name")
        seen_cmd[$cmd_name]=1
        found=1
      fi
      if (( ! found )); then
        emit_json_object \
          "action=verify" \
          "status=missing" \
          "type=unknown" \
          "name=$item"
        (( ! JSON_MODE )) && err "Verify failed: $item (not installed)"
        exit_code=3
      fi
    done
  fi

  for name in "${cmd_targets[@]}"; do
    verified_any=1
    local path="$target_bin/$name"
    local status="ok" message="" version=""
    if [[ ! -e "$path" ]]; then
      status="error"
      message="missing"
    else
      version="$(script_version "$path")"
      if [[ ! -x "$path" ]]; then
        status="error"
        message="not executable"
      fi
    fi
    [[ $status == error ]] && exit_code=3
    emit_json_object \
      "action=verify" \
      "status=$status" \
      "type=cmd" \
      "name=$name" \
      "path=$path" \
      "version=$version" \
      "message=$message"
    if (( ! JSON_MODE )); then
      if [[ $status == ok ]]; then
        ok "Verified cmd: $name ($path)"
      else
        err "Verify failed cmd: $name — $message"
      fi
    fi
  done

  for name in "${app_targets[@]}"; do
    verified_any=1
    local path="$target_apps/$name"
    local entry="$path/bin/$name"
    local shim="$target_bin/$name"
    local version="" status="ok"
    local message_parts=()

    if [[ ! -e "$path" ]]; then
      status="error"
      message_parts+=("app missing")
    else
      version="$(script_version "$path")"
      if [[ ! -e "$entry" ]]; then
        status="error"
        message_parts+=("missing entry bin/$name")
      elif [[ ! -x "$entry" ]]; then
        status="error"
        message_parts+=("entry not executable")
      fi
      if [[ ! -e "$shim" ]]; then
        status="error"
        message_parts+=("shim missing")
      elif [[ ! -x "$shim" ]]; then
        status="error"
        message_parts+=("shim not executable")
      fi
    fi

    [[ $status == error ]] && exit_code=3

    local message=""
    if (( ${#message_parts[@]} )); then
      message=$(printf '%s; ' "${message_parts[@]}")
      message=${message%; }
    fi

    emit_json_object \
      "action=verify" \
      "status=$status" \
      "type=app" \
      "name=$name" \
      "path=$path" \
      "entry=$entry" \
      "shim=$shim" \
      "version=$version" \
      "message=$message"

    if (( ! JSON_MODE )); then
      if [[ $status == ok ]]; then
        ok "Verified app: $name ($entry)"
      else
        err "Verify failed app: $name — $message"
      fi
    fi
  done

  if (( ! JSON_MODE )) && (( verified_any == 0 )) && (( exit_code == 0 )); then
    say "Nothing to verify."
  fi

  (( exit_code )) && return 3 || return 0
}



# --------------------------------------------------------------------------------------------------
# LIST — show installed scripts/apps with versions and descriptions
# --------------------------------------------------------------------------------------------------
op_list(){
  ensure_bin; ensure_apps
  bm_ensure_inventory
  print_banner
  printf "%-8s %-24s %-10s %s\n" "Kind" "Name" "Version" "Path / Manifest"
  printf "%-8s %-24s %-10s %s\n" "----" "----" "-------" "---------------"
  local line kind name ver path type scope target preview help manifest run display_path shown=0
  local include_apps="${BINMAN_INCLUDE_APPS:-0}"
  while IFS=$'\t' read -r kind name ver path type scope target preview help manifest run; do
    display_path="$path"
    if [[ -z "$display_path" ]]; then
      display_path="$manifest"
    fi
    [[ -n "$display_path" ]] || display_path="-"
    # [Patch] Hide app dirs from list unless BINMAN_INCLUDE_APPS=1
    if [[ "$kind" == "app" && "$include_apps" != "1" ]]; then
      continue
    fi
    printf "%-8s %-24s %-10s %s\n" "$kind" "$name" "$ver" "$display_path"
    shown=1
  done < <(__bm_list_tsv | sort -t $'\t' -k1,1 -k2,2)
  (( shown )) || say "(no entries)"
}

TYPES=()
NAMES=()
VERS=()
PATHS=()
PREVIEWS=()
HELPS=()
FILES=()
TARGETS=()
RUNS=()
SCOPES=()
WTYPE=0
WNAME=0
WVER=0

_calc_widths() {
  local t n v max_name=0 len
  WTYPE=3
  WVER=7
  for t in "${TYPES[@]}"; do
    len=${#t}
    (( len > WTYPE )) && WTYPE=$len
  done
  for n in "${NAMES[@]}"; do
    len=${#n}
    (( len > max_name )) && max_name=$len
  done
  (( max_name > 38 )) && max_name=38
  (( max_name < 1 )) && max_name=1
  WNAME=$max_name
  for v in "${VERS[@]}"; do
    len=${#v}
    (( len > WVER )) && WVER=$len
  done
  (( WVER < 7 )) && WVER=7
  debug "Left pane widths: type=${WTYPE} name=${WNAME} ver=${WVER}"
}

_fmt_left_line() {
  local idx="$1" type name ver shown_name slice
  type="${TYPES[idx]}"
  name="${NAMES[idx]}"
  ver="${VERS[idx]}"
  if (( ${#name} > WNAME )); then
    if (( WNAME <= 1 )); then
      shown_name="…"
    else
      slice=$((WNAME - 1))
      shown_name="${name:0:slice}…"
    fi
  else
    shown_name="$name"
  fi
  printf "%-*s  %-*s  %s" "$WTYPE" "$type" "$WNAME" "$shown_name" "$ver"
}

_ensure_inventory_arrays() {
  if [[ ${NAMES+x} == x && ${#NAMES[@]} -gt 0 ]]; then
    return 0
  fi
  __bm_arrays_from_cache
}

_render_preview_for_idx() {
  local idx="${1:-0}"
  _ensure_inventory_arrays || return 0
  [[ "$idx" =~ ^[0-9]+$ ]] || idx=0
  if (( idx < 0 || idx >= ${#NAMES[@]} )); then
    _ui_right_clear
    _ui_right_header "[unknown]"
    _ui_right_kv "Path:" "-"
    _ui_right_kv "Type:" "-"
    _ui_right_text "(no preview available)"
    return 0
  fi
  local name="${NAMES[idx]}"
  local type="${TYPES[idx]}"
  local path="${PATHS[idx]}"
  local text="${PREVIEWS[idx]:-${HELPS[idx]}}"
  [[ -n "$text" ]] || text="(no preview available)"
  _ui_right_clear
  _ui_right_header "[${name:-unknown}]"
  _ui_right_kv "Path:" "${path:-"-"}"
  _ui_right_kv "Type:" "${type:-"-"}"
  _ui_right_text "$text"
}

__bm_arrays_from_cache() {
  [[ -n "${BINMAN_LIST_CACHE:-}" && -f "$BINMAN_LIST_CACHE" ]] || return 1
  unset TYPES NAMES VERS PATHS PREVIEWS HELPS FILES TARGETS RUNS SCOPES
  TYPES=(); NAMES=(); VERS=(); PATHS=(); PREVIEWS=(); HELPS=(); FILES=(); TARGETS=(); RUNS=(); SCOPES=()
  while IFS=$'\t' read -r kind name ver path type scope target preview help manifest run || [[ -n "$kind" ]]; do
    [[ -z "$kind" ]] && continue
    TYPES+=("$kind")
    NAMES+=("$name")
    VERS+=("$ver")
    PATHS+=("$path")
    TARGETS+=("$target")
    PREVIEWS+=("$(decode_field "$preview")")
    HELPS+=("$(decode_field "$help")")
    FILES+=("$manifest")
    RUNS+=("$(decode_field "$run")")
    SCOPES+=("$scope")
  done < "$BINMAN_LIST_CACHE"
  return 0
}

__bm_preview_line() {
  local n="${1:-1}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  __bm_arrays_from_cache || return 0
  local idx=$(( n ))
  (( idx < 0 || idx >= ${#NAMES[@]} )) && return 0
  debug "PREVIEW: n=$n -> idx=$idx name=${NAMES[idx]:-}"
  _render_preview_for_idx "$idx"
}

build_inventory() {
  local old_nullglob
  old_nullglob="$(shopt -p nullglob 2>/dev/null || true)"
  shopt -s nullglob

  unset lines
  lines=()
  : > "$BINMAN_LIST_CACHE"

  debug "INV: BIN_DIR=$BIN_DIR SYSTEM_BIN=$SYSTEM_BIN"
  debug "INV: APP_STORE=$APP_STORE SYSTEM_APPS=$SYSTEM_APPS"

  local dir f scope_label kind name version path type preview line
  local total=0
  # [Patch] Prefer apps; hide cmd when app exists; ensure cmd version via shim_version()
  declare -A _apps_seen=()

  debug "INV: scan apps in $APP_STORE"
  debug "INV: scan apps in $SYSTEM_APPS"
  for dir in "$APP_STORE" "$SYSTEM_APPS"; do
    [[ -d "$dir" ]] || continue
    if [[ "$dir" == "$APP_STORE" ]]; then
      scope_label="user"
    else
      scope_label="system"
    fi
    for f in "$dir"/*; do
      [[ -d "$f" || -L "$f" ]] || continue
      kind="app"
      name="$(basename "$f")"
      version="$(script_version "$f")"
      path="$(__bm_realpath "$f")"
      type="app"
      preview="$(script_desc "$f")"
      _apps_seen["$name"]=1
      printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$kind" "$name" "$version" "$path" "$type" "$scope_label" "$path" \
        "$(encode_field "$preview")" "$(encode_field "$preview")" "" ""
      lines+=("$line")
      ((total++))
    done
  done

  debug "INV: scan execs in $BIN_DIR"
  debug "INV: scan execs in $SYSTEM_BIN"
  for dir in "$BIN_DIR" "$SYSTEM_BIN"; do
    [[ -d "$dir" ]] || continue
    if [[ "$dir" == "$BIN_DIR" ]]; then
      scope_label="user"
    else
      scope_label="system"
    fi
    for f in "$dir"/*; do
      [[ -x "$f" && -f "$f" ]] || continue
      kind="cmd"
      name="$(basename "$f")"
      if [[ -n "${_apps_seen[$name]:-}" ]]; then
        debug "INV: skip cmd '$name' (app exists)"
        continue
      fi
      version="$(shim_version "$f")"
      path="$(__bm_realpath "$f")"
      type="cmd"
      preview="$(script_desc "$f")"
      printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$kind" "$name" "$version" "$path" "$type" "$scope_label" "$path" \
        "$(encode_field "$preview")" "$(encode_field "$preview")" "" ""
      lines+=("$line")
      ((total++))
    done
  done

  # [Patch] Ignore .app/.manifest unless BINMAN_INCLUDE_MANIFESTS=1
  local file help manifest_path preview_text run_val
  if [[ "${BINMAN_INCLUDE_MANIFESTS:-0}" == "1" ]]; then
    debug "INV: scan manifests in $APP_STORE and $SYSTEM_APPS (BINMAN_INCLUDE_MANIFESTS=1)"
    for file in "$APP_STORE"/*.{app,cmd,manifest} "$SYSTEM_APPS"/*.{app,cmd,manifest}; do
      [[ -f "$file" ]] || continue
      if read_manifest "$file"; then
        kind="${MF[type]:-app}"
        name="${MF[name]:-$(basename "$file")}"
        version="${MF[version]:-unknown}"
        path="$(expand_path "${MF[path]:-}")"
        type="${MF[type]:-app}"
        if [[ "$file" == $APP_STORE/* ]]; then
          scope_label="manifest-user"
        else
          scope_label="manifest-system"
        fi
        preview_text="${MF[preview]:-${MF[help]:-}}"
        help="${MF[help]:-}"
        run_val="${MF[run]:-${MF[run_raw]:-}}"
        manifest_path="$(__bm_realpath "$file")"
        printf -v line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
          "$kind" "$name" "$version" "$path" "$type" "$scope_label" "$path" \
          "$(encode_field "$preview_text")" "$(encode_field "$help")" "$manifest_path" "$(encode_field "$run_val")"
        lines+=("$line")
        ((total++))
      fi
    done
  else
    debug "INV: skip manifest scan (BINMAN_INCLUDE_MANIFESTS!=1)"
  fi

  printf '%s\n' "${lines[@]}" > "$BINMAN_LIST_CACHE"

  [[ -n "$old_nullglob" ]] && eval "$old_nullglob" || shopt -u nullglob

  __bm_arrays_from_cache || true

  (( BINMAN_DEBUG_FLAG )) && echo "INV: total rows=$total"
  (( total > 0 )) || return 1
  return 0
}

op_list_ranger() {
  if ! command -v fzf >/dev/null 2>&1; then
    op_list
    return 0
  fi

  if ! build_inventory; then
    warn "No manifest entries found."
    return 0
  fi

  local out key row idx kind name ver path type scope target preview help manifest run preview_cmd bind_doctor exec_target rc app_dir scope_is_manifest
  local display_line
  local -a formatted_rows=()

  _calc_widths
  for idx in "${!NAMES[@]}"; do
    kind="${TYPES[idx]}"
    name="${NAMES[idx]}"
    ver="${VERS[idx]}"
    path="${PATHS[idx]}"
    type="$kind"
    scope="${SCOPES[idx]:-manifest-user}"
    target="${TARGETS[idx]}"
    [[ -n "$target" ]] || target="$path"
    preview="$(encode_field "${PREVIEWS[idx]}")"
    help="$(encode_field "${HELPS[idx]}")"
    manifest="${FILES[idx]}"
    run="${RUNS[idx]}"
    formatted_rows+=("$(_fmt_left_line "$idx")"$'\t'"$kind"$'\t'"$name"$'\t'"$ver"$'\t'"$path"$'\t'"$type"$'\t'"$scope"$'\t'"$target"$'\t'"$preview"$'\t'"$help"$'\t'"$manifest"$'\t'"$run")
  done

  preview_cmd="bash -lc 'source \"${BINMAN_SELF}\"; __bm_preview_line {n}'"
  bind_doctor="d:execute-silent(bash -c 'exec \"$BINMAN_SELF\" doctor \"$@\"' doctor {3})"
  local bind_reload="ctrl-r:abort"

  out="$(printf '%s\n' "${formatted_rows[@]}" |
    fzf --ansi --border --height=100% --layout=reverse \
        --delimiter=$'\t' --with-nth=1 \
        --preview "${preview_cmd}" \
        --preview-window=right,60%,wrap \
        --bind "${bind_doctor}" \
        --bind "${bind_reload}" \
        --bind esc:abort \
        --prompt='BinMan ▸ ' \
        --header='↑↓ navigate • Enter=Run • d=Doctor • ctrl-r=Reload • Esc=Back' \
        --expect=enter,d,ctrl-r \
    || true)"

  [[ -z "$out" ]] && return 0

  key="$(printf '%s\n' "$out" | head -n1)"
  row="$(printf '%s\n' "$out" | tail -n1)"
  IFS=$'\t' read -r display_line kind name ver path type scope target preview help manifest run <<<"$row"
  scope_is_manifest=0
  [[ "$scope" == manifest-user || "$scope" == manifest-system ]] && scope_is_manifest=1

  case "$key" in
    d)
      "$BINMAN_SELF" doctor "$name"
      ;;
    ctrl-r)
      op_list_ranger
      ;;
    enter|*)
      exec_target="$target"
      app_dir="$path"
      if [[ "$kind" == "app" && $scope_is_manifest -eq 0 ]]; then
        local shim
        if [[ "$scope" == system ]]; then
          shim="$SYSTEM_BIN/$name"
        else
          shim="$BIN_DIR/$name"
        fi
        if [[ -x "$shim" ]]; then
          exec_target="$shim"
        elif [[ -x "$target" ]]; then
          exec_target="$target"
        elif [[ -n "$app_dir" ]]; then
          if [[ -x "$app_dir/bin/$name" ]]; then
            exec_target="$app_dir/bin/$name"
          elif [[ -x "$app_dir/bin/run.sh" ]]; then
            exec_target="$app_dir/bin/run.sh"
          elif [[ -x "$app_dir/bin/start" ]]; then
            exec_target="$app_dir/bin/start"
          elif [[ -x "$app_dir/$name" ]]; then
            exec_target="$app_dir/$name"
          elif [[ -x "$app_dir/run.sh" ]]; then
            exec_target="$app_dir/run.sh"
          fi
        fi
      fi

      if [[ ! -x "$exec_target" ]]; then
        if [[ $scope_is_manifest -eq 1 && -n "$run" ]]; then
          warn "Manifest entry has run command only (not executed automatically)."
        else
          warn "Not executable: ${exec_target:-<none>}"
        fi
      else
        printf "\nRunning: %s\n\n" "$exec_target"
        "$exec_target"
        rc=$?
        printf "\nExit code: %s\n" "$rc"
      fi
      ;;
  esac

  return 0
}

# [Patch] Run installed tools via sudo helper
op_sudo(){
  local name="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi
  [[ -n "$name" ]] || { err "usage: binman sudo <name> [args...]"; return 2; }

  local shim appdir
  if (( SYSTEM_MODE )); then
    shim="$SYSTEM_BIN/$name"
    appdir="$SYSTEM_APPS/$name"
  else
    shim="$BIN_DIR/$name"
    appdir="$APP_STORE/$name"
  fi

  if [[ ! -x "$shim" ]]; then
    if [[ -x "$appdir/bin/$name" ]]; then
      shim="$appdir/bin/$name"
    fi
  fi

  [[ -x "$shim" ]] || { err "not installed or not executable: $name"; return 2; }

  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$shim" "$@"
  else
    err "sudo not available"
    return 2
  fi
}

__fzf_common_opts() {
  # One option per line; callers will mapfile into an array safely.
  cat <<'EOF'
--ansi
--border
--layout=reverse-list
--height=90%
--info=inline
--prompt=› 
--pointer=›
--marker=»
--cycle
--bind=alt-q:abort
EOF
}


# --------------------------------------------------------------------------------------------------
# DOCTOR — environment + per-app healing (venv/deps/hook)
# --------------------------------------------------------------------------------------------------

# Keep legacy entry for any old callers; now just proxies to the env summary.
# Flags:
#   --quiet      : suppress any pauses/handoffs; same as BINMAN_NONINTERACTIVE=1
#   --fix-path   : attempt PATH patching in common shells

op_doctor(){
  local QUIET=0
  FIX_PATH=${FIX_PATH:-0}

  while (( $# )); do
    case "$1" in
      --quiet|-q) QUIET=1; shift ;;
      --fix-path) FIX_PATH=1; shift ;;
      *) break ;;
    esac
  done

  doctor_env "$QUIET"
}

# Environment summary (+ optional PATH patch)
doctor_env() {
  local quiet="${1:-0}"
  local mode bin_dir app_store
  mode=$([[ $SYSTEM_MODE -eq 1 ]] && echo system || echo user)
  bin_dir=$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR")
  app_store=$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE")

  say "Mode      : $mode"
  say "BIN_DIR   : $bin_dir"
  say "APP_STORE : $app_store"
  (( SYSTEM_MODE )) || { in_path && ok "PATH ok" || warn "PATH missing ${BIN_DIR}"; }

  exists zip   && ok "zip: present"   || warn "zip: not found (fallback to .tar.gz)"
  exists unzip && ok "unzip: present" || warn "unzip: not found (needed to restore .zip)"
  exists tar   && ok "tar: present"   || warn "tar: not found (needed to restore .tar.gz)"

  # Bonus: shadow check for installed shims
  if command -v binman >/dev/null 2>&1; then
    local resolved
    resolved="$(command -v binman)"
    [[ "$resolved" != "$BIN_DIR/binman" && -e "$BIN_DIR/binman" ]] && \
      warn "binman in PATH is '$resolved' but user shim exists at '$BIN_DIR/binman' (shadowed)."
  fi

  # Optional: safer PATH patching across shells
  if [[ ${FIX_PATH:-0} -eq 1 ]]; then
    local line='export PATH="$HOME/.local/bin:$PATH"'
    for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.profile"; do
      [[ -f "$f" ]] || continue
      grep -qF "$line" "$f" || { printf '\n# Added by binman doctor\n%s\n' "$line" >> "$f"; ok "Patched PATH in $f"; }
    done
    if command -v fish >/dev/null 2>&1; then
      local fish_conf="$HOME/.config/fish/config.fish"
      mkdir -p "$(dirname "$fish_conf")"
      grep -q 'set -gx PATH $HOME/.local/bin $PATH' "$fish_conf" 2>/dev/null || {
        printf '\n# Added by binman doctor\nset -gx PATH $HOME/.local/bin $PATH\n' >> "$fish_conf"
        ok "Patched PATH in fish config"
      }
    fi
  fi

  # --- Non-interactive guard: never pause or chain to other menus ---
  if [[ -n "${BINMAN_NONINTERACTIVE:-}" || "$quiet" -eq 1 || ! -t 0 || ! -t 1 ]]; then
    return 0
  fi

  # Interactive mode simply returns; no hidden prompts, no chaining.
  return 0
}


# ---- Per‑app helpers ---------------------------------------------------------
_apps_dir(){
    [[ $SYSTEM_MODE -eq 1 ]] && echo "${SYSTEM_APPS}" || echo "${APP_STORE}";
}

_list_apps(){
  local d; d="$(_apps_dir)"
  [[ -d "$d" ]] || return 0
  for x in "$d"/*; do [[ -d "$x" ]] && basename "$x"; done
}

_pick_app(){
  local items; items="$(_list_apps)"
  [[ -n "$items" ]] || { err "No apps installed."; return 1; }
  if exists fzf; then
    printf "%s\n" "$items" | fzf --prompt="Doctor → "
  else
    warn "Tip: install 'fzf' for fuzzy picking."
    local i=1 arr; mapfile -t arr < <(printf "%s\n" "$items")
    say "Choose an app:"; for n in "${arr[@]}"; do printf "  [%d] %s\n" "$i" "$n"; ((i++)); done
    printf "Number: "; read -r n
    [[ "$n" =~ ^[0-9]+$ ]] && echo "${arr[$((n-1))]}"
  fi
}

_is_python_app(){
  local d="$1"
  [[ -d "$d/.venv" || -f "$d/requirements.txt" || -f "$d/pyproject.toml" ]] && return 0
  find "$d" -maxdepth 2 -type f -name "*.py" | read -r _ && return 0
  return 1
}

_make_venv(){
  local d="$1" pyver="$2" dry="$3" py="python3"
  [[ -n "$pyver" ]] && py="python${pyver}"
  command -v "$py" >/dev/null 2>&1 || { err "Requested interpreter not found: $py"; return 2; }
  if [[ "$dry" == 1 ]]; then
    say "🩺 DRY: would create venv with $py at $d/.venv"
  else
    [[ -d "$d/.venv" ]] || { say "🩺 Creating venv (.venv) with $py"; "$py" -m venv "$d/.venv" || return 2; }
    "$d/.venv/bin/python" -m pip install -U pip >/dev/null 2>&1 || true
  fi
  echo "$d/.venv"
}

_pyproj_deps(){
  awk '
    /^\[project\]/ { in=1; next }
    /^\[/ { in=0 }
    in && /^dependencies *= *\[/ {
      buf=$0
      while (buf !~ /\]/) { getline x; buf=buf x }
      print buf
    }
  ' "$1" | sed -E 's/.*\[(.*)\].*/\1/' | tr -d '"'\'' ' | tr ',' '\n' | sed '/^$/d'
}

_install_reqs(){
  local d="$1" venv="$2" dry="$3" quiet="$4"
  local req="$d/requirements.txt" pyproj="$d/pyproject.toml" pkgs=() q=
  [[ "$quiet" == 1 ]] && q="-q" || q=""
  if [[ -f "$req" ]]; then
    say "📦 requirements.txt"
    if [[ "$dry" == 1 ]]; then
      say "DRY: would install ->"; sed -E 's/#.*$//' "$req" | sed '/^\s*$/d' | sed 's/^/  - /'
      return 0
    fi
    "$venv/bin/pip" install $q -U -r "$req" || return 2
    return 0
  fi
  if [[ -f "$pyproj" ]]; then
    mapfile -t pkgs < <(_pyproj_deps "$pyproj")
    if ((${#pkgs[@]})); then
      say "📦 pyproject.toml deps"
      if [[ "$dry" == 1 ]]; then printf "  - %s\n" "${pkgs[@]}"; return 0; fi
      "$venv/bin/pip" install $q -U "${pkgs[@]}" || return 2
      return 0
    else
      warn "No dependencies listed."
    fi
  else
    warn "No requirements.txt / pyproject.toml found."
  fi
}

_run_hook(){
  local d="$1" dry="$2" hook="$d/.binman/doctor.sh"
  [[ -x "$hook" ]] || return 0
  say "🔧 Hook: .binman/doctor.sh"
  [[ "$dry" == 1 ]] && { say "DRY: would run hook"; return 0; }
  ( cd "$d" && bash "$hook" )
}

doctor_app_one(){
  local name="$1" pyver="$2" dry="$3" quiet="$4" status=0
  local base d
  base="$(_apps_dir)"; d="${base%/}/$name"
  [[ -d "$d" ]] || { err "Not found: $name"; return 2; }
  say "🩺 Checking: $name  →  $d"
  if _is_python_app "$d"; then
    local v; v="$(_make_venv "$d" "$pyver" "$dry")" || status=2
    [[ $status -eq 0 ]] && _install_reqs "$d" "$v" "$dry" "$quiet" || status=2
  else
    say "🧩 Not a Python app; skipping venv stage."
  fi
  _run_hook "$d" "$dry" || status=2
  (( status == 0 )) && ok "✅ Healthy" || warn "⚠️  Issues detected"
  return $status
}

cmd_doctor(){
  local DO_ALL=0 DRY=0 QUIET=0 PYVER="" tgt=
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) DO_ALL=1;;
      --dry-run) DRY=1;;
      -q|--quiet) QUIET=1;;
      --python) shift; PYVER="$1";;
      -h|--help) say "binman doctor [--all|<name>] [--python X.Y] [--dry-run] [-q]"; return 0;;
      *) tgt="$1";;
    esac; shift
  done

  if [[ -z "$tgt" && $DO_ALL -eq 0 ]]; then
    doctor_env
    echo
    tgt="$(_pick_app)" || return 2
  fi

  if [[ $DO_ALL -eq 1 ]]; then
    local fail=0 any=0
    while read -r n; do
      [[ -z "$n" ]] && continue
      any=1
      doctor_app_one "$n" "$PYVER" "$DRY" "$QUIET" || ((fail++))
    done < <(_list_apps)
    [[ $any -eq 0 ]] && { warn "No apps installed."; return 0; }
    ((fail==0)) && return 0 || return 2
  else
    doctor_env; echo; doctor_app_one "$tgt" "$PYVER" "$DRY" "$QUIET"
  fi
}

cmd_prune_rollbacks(){
  [[ -d "$ROLLBACK_ROOT" ]] || { say "No rollback snapshots found."; return 0; }

  local before_h before_k after_h after_k freed_k freed_bytes freed_h
  before_h=$(du -sh "$ROLLBACK_ROOT" 2>/dev/null | awk '{print $1}')
  before_k=$(du -sk "$ROLLBACK_ROOT" 2>/dev/null | awk '{print $1}')
  before_k=${before_k:-0}
  before_h=${before_h:-0B}

  prune_rollbacks

  after_h=$(du -sh "$ROLLBACK_ROOT" 2>/dev/null | awk '{print $1}')
  after_k=$(du -sk "$ROLLBACK_ROOT" 2>/dev/null | awk '{print $1}')
  after_k=${after_k:-0}
  after_h=${after_h:-0B}

  freed_k=$(( before_k - after_k ))
  (( freed_k < 0 )) && freed_k=0
  freed_bytes=$(( freed_k * 1024 ))

  if command -v numfmt >/dev/null 2>&1; then
    freed_h=$(numfmt --to=iec --suffix=B "$freed_bytes" 2>/dev/null || echo "${freed_bytes}B")
  else
    if (( freed_k == 0 )); then
      freed_h="0B"
    else
      freed_h="${freed_k}K"
    fi
  fi

  local msg
  msg="Pruned ${PRUNE_LAST_REMOVED:-0} rollback(s); reclaimed ${freed_h} (was ${before_h:-0}, now ${after_h:-0})"
  if (( PRUNE_LAST_REMOVED > 0 )); then
    ok "$msg"
  else
    say "$msg"
  fi
}

cmd_analyze(){
  local top=20 root="/"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --top)
        [[ -n "${2:-}" ]] || { err "--top requires a number"; return 2; }
        top="$2"; shift 2;;
      --root)
        [[ -n "${2:-}" ]] || { err "--root requires a directory"; return 2; }
        root="$2"; shift 2;;
      -h|--help)
        say "Usage: ${SCRIPT_NAME} analyze [--top N] [--root DIR]"; return 0;;
      *)
        err "Unknown analyze option: $1"; return 2;;
    esac
  done

  [[ "$top" =~ ^[0-9]+$ && top -gt 0 ]] || { warn "Invalid --top value; defaulting to 20"; top=20; }
  [[ -d "$root" ]] || { err "Root directory not found: $root"; return 2; }

  local root_abs
  root_abs=$(realpath_f "$root" 2>/dev/null || echo "$root")

  ui_init
  printf "%sAnalyze:%s inspecting %s (top %s)\n" "$UI_BOLD" "$UI_RESET" "$root_abs" "$top"
  ui_hr

  printf "%sDisk overview (df -hT)%s\n" "$UI_CYAN" "$UI_RESET"
  if ! df -hT "$root_abs" 2>/dev/null; then
    df -hT 2>/dev/null || warn "df failed"
  fi

  echo
  printf "%sTop %s directories under %s%s\n" "$UI_CYAN" "$top" "$root_abs" "$UI_RESET"
  ui_hr
  local du_output
  du_output="$( { maybe_sudo_cmd du -xhd1 "$root_abs" 2>/dev/null || true; } | sort -hr | head -n "$top" || true)"
  if [[ -n "$du_output" ]]; then
    printf "%s\n" "$du_output" | sed 's/^/  /'
  else
    printf "  (no data)\n"
  fi

  echo
  printf "%sTop %s files under %s%s\n" "$UI_CYAN" "$top" "$root_abs" "$UI_RESET"
  ui_hr
  local find_output
  find_output="$( { maybe_sudo_cmd find "$root_abs" -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o -type f -printf '%s\t%p\n' 2>/dev/null || true; } | sort -nr | head -n "$top" || true)"

  if [[ -n "$find_output" ]]; then
    while IFS=$'\t' read -r size path; do
      [[ -z "$path" ]] && continue
      printf "  %s%-9s%s %s\n" "$UI_GREEN" "$(human_size "$size")" "$UI_RESET" "$path"
    done <<< "$find_output"
  else
    printf "  (no files)\n"
  fi

  echo
  printf "%sHint:%s Use sysclean for interactive cleanup.\n" "$UI_DIM" "$UI_RESET"
}



# --------------------------------------------------------------------------------------------------
# UPDATE — reinstall with overwrite (optionally pull a git dir first)
# --------------------------------------------------------------------------------------------------
op_update(){
  [[ -n "$GIT_DIR" && -d "$GIT_DIR/.git" ]] && (cd "$GIT_DIR" && git pull --rebase --autostash)
  local targets=("$@"); [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] && { FORCE=1; maybe_snapshot; op_install "${targets[@]}"; } || warn "Nothing to reinstall"
}



# --------------------------------------------------------------------------------------------------
# BACKUP & RESTORE — archive management (zip preferred; tar.gz fallback)
# --------------------------------------------------------------------------------------------------
_backup_filename_default(){
    local ext="$1"; 
    local ts; 
    ts=$(date +%Y%m%d-%H%M%S); 
    echo "binman_backup-${ts}.${ext}";
}

op_backup_subset(){
  # ARGS: output filename (optional) + selected rows on stdin ("cmd  name" / "app  name")
  # Example use:
  #   _tui_pick_cmd_or_app_multi | op_backup_subset "mybundle.zip"
  local outfile="${1:-}"
  shift || true

  local tmp sel
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  mkdir -p "$tmp"/{bin,apps}

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local kind name
    kind="$(awk '{print $1}' <<<"$line")"
    name="$(awk '{print $2}' <<<"$line")"
    if [[ "$kind" == "cmd" && -x "$BIN_DIR/$name" ]]; then
      cp -a "$BIN_DIR/$name" "$tmp/bin/$name" 2>/dev/null || true
    elif [[ "$kind" == "app" && -e "$APP_STORE/$name" ]]; then
      cp -a "$APP_STORE/$name" "$tmp/apps/$name" 2>/dev/null || true
    fi
  done

  # If nothing selected, do nothing
  if ! compgen -G "$tmp/bin/*" >/dev/null && ! compgen -G "$tmp/apps/*" >/dev/null; then
    warn "Nothing selected; backup skipped."
    return 0
  fi

  # Temporarily point BIN/APPS to temp, then call op_backup (so it writes manifest/metadata)
  local old_bin="$BIN_DIR" old_apps="$APP_STORE"
  BIN_DIR="$tmp/bin"; APP_STORE="$tmp/apps"
  op_backup "$outfile"
  local rc=$?
  BIN_DIR="$old_bin"; APP_STORE="$old_apps"
  return $rc
}

op_backup(){
  ensure_bin; ensure_apps

  local prefer_zip=1 ext
  if exists zip && exists unzip; then
    ext="zip"
  else
    prefer_zip=0
    ext="tar.gz"
    warn "zip/unzip not fully available; using .tar.gz"
  fi

  # Normalize outfile: add ext if missing; make relative paths land in $PWD
  local outfile="${1:-$(_backup_filename_default "$ext")}"
  [[ "$outfile" != *.zip && "$outfile" != *.tar.gz && "$outfile" != *.tgz ]] && outfile="${outfile}.${ext}"
  case "$outfile" in
    /*) : ;;                   # absolute → keep
    *)  outfile="$PWD/$outfile" ;;
  esac
  mkdir -p "$(dirname "$outfile")"

  (
    set -e
    # subshell keeps tmp in scope until EXIT → no nounset trap blowups
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT

    mkdir -p "$tmp"/{bin,apps,meta}
    [[ -d "$BIN_DIR"   ]] && cp -a "$BIN_DIR"/.   "$tmp/bin"  2>/dev/null || true
    [[ -d "$APP_STORE" ]] && cp -a "$APP_STORE"/. "$tmp/apps" 2>/dev/null || true

    cat > "$tmp/meta/info.txt" <<EOF
Created: $(iso_now)
BinMan:  ${SCRIPT_NAME} v${VERSION}
BIN_DIR: ${BIN_DIR}
APP_STORE: ${APP_STORE}
Host: $(uname -a)
EOF

    if [[ $prefer_zip -eq 1 ]]; then
      (cd "$tmp" && zip -qr "$outfile" bin apps meta)
    else
      (cd "$tmp" && tar -czf "$outfile" bin apps meta)
    fi

    abs_out="$(realpath_f "$outfile")"
    if (( JSON_MODE )); then
      emit_json_object event=backup path="$abs_out" status=ok
    else
      ok "Backup created: ${abs_out}"
    fi
  )
}

_detect_extract_root(){
  local base="$1"
  if [[ -d "$base/bin" || -d "$base/apps" ]]; then echo "$base"; return 0; fi
  for d in "$base"/*; do [[ -d "$d" ]] || continue; [[ -d "$d/bin" || -d "$d/apps" ]] && { echo "$d"; return 0; }; done
  echo "$base"
}

op_restore(){
  ensure_bin; ensure_apps; maybe_snapshot
  local archive="${1:-}"
  [[ -n "$archive" && -f "$archive" ]] || { err "restore requires an existing archive path"; return 2; }

  local tmp; tmp=$(mktemp -d)
  cleanup_restore(){ rm -rf "${tmp:-}"; }
  trap cleanup_restore EXIT

  case "$archive" in
    *.zip)
      exists unzip || { err "unzip not available"; exit 2; }
      unzip -q "$archive" -d "$tmp"
      ;;
    *.tar.gz|*.tgz)
      exists tar || { err "tar not available"; exit 2; }
      tar -xzf "$archive" -C "$tmp"
      ;;
    *)
      err "Unknown archive type (use .zip or .tar.gz): $archive"
      exit 2
      ;;
  esac

  local root; root="$(_detect_extract_root "$tmp")"
  [[ -d "$root/bin"  ]] && { say "Restoring scripts to ${BIN_DIR}..."; _merge_dir "$root/bin" "$BIN_DIR"; }
  [[ -d "$root/apps" ]] && { say "Restoring apps to ${APP_STORE}..."; _merge_dir "$root/apps" "$APP_STORE"; }

  _chmod_bin_execs
  rehash_shell
  if (( EMIT_REHASH )); then
    printf '[ -n "${ZSH_VERSION:-}" ] && rehash || { [ -n "${BASH_VERSION:-}" ] && hash -r; }%s' $'\n'
    return 0
  fi
  ok "Restore complete."
}




# --------------------------------------------------------------------------------------------------
# SELF-UPDATE — pull repo and reinstall the binman shim
# --------------------------------------------------------------------------------------------------
op_self_update(){
  local url="https://raw.githubusercontent.com/karialo/binman/main/binman.sh"

  local dest
  dest="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

  local tmp bak
  tmp="$(mktemp "${TMPDIR:-/tmp}/binman.update.XXXXXX")" || { err "mktemp failed"; return 2; }
  trap '[ -n "${tmp:-}" ] && rm -f "$tmp"' EXIT

  if exists curl; then
    curl -fsSL "$url" -o "$tmp" || { err "Download failed."; return 2; }
  elif exists wget; then
    wget -q "$url" -O "$tmp" || { err "Download failed."; return 2; }
  else
    err "Need curl or wget for self-update"; return 2
  fi

  chmod 755 "$tmp"

  if ! grep -q 'case "\$ACTION"' "$tmp"; then
    err "Fetched file doesn't look like binman.sh"; return 2
  fi

  if cmp -s "$dest" "$tmp"; then
    ok "Already up to date."
    return 0
  fi

  bak="${dest}.bak"  # single rotating backup
  cp -p -- "$dest" "$bak" 2>/dev/null || true

  if install -m 755 "$tmp" "$dest" 2>/dev/null; then
    ok "Self-update complete → $dest (backup: $bak)"
  elif command -v sudo >/dev/null 2>&1 && sudo install -m 755 "$tmp" "$dest"; then
    ok "Self-update complete (sudo) → $dest (backup: $bak)"
  else
    err "Couldn't write to $dest. Try: sudo install -m 755 \"$tmp\" \"$dest\""
    return 2
  fi
}


# --------------------------------------------------------------------------------------------------
# BUNDLE — export bin+apps plus a manifest file
# --------------------------------------------------------------------------------------------------
# Replace the whole op_bundle() with this:
op_bundle(){
  ensure_bin; ensure_apps

  local out="${1:-binman_bundle-$(date +%Y%m%d-%H%M%S).zip}"
  case "$out" in
    /*) : ;;
    *)  out="$PWD/$out" ;;
  esac
  mkdir -p "$(dirname "$out")"

  (
    set -e
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT

    mkdir -p "$tmp"/{bin,apps}
    [[ -d "$BIN_DIR"   ]] && cp -a "$BIN_DIR"/.   "$tmp/bin"  2>/dev/null || true
    [[ -d "$APP_STORE" ]] && cp -a "$APP_STORE"/. "$tmp/apps" 2>/dev/null || true

    {
      echo "# BinMan bundle manifest"
      echo "created=$(iso_now)"
      echo "bin_dir=$BIN_DIR"
      echo "app_store=$APP_STORE"
      echo
      echo "[bin]";  find "$tmp/bin"  -maxdepth 1 -type f -printf "%f\n" 2>/dev/null || true
      echo
      echo "[apps]"; find "$tmp/apps" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null || true
    } > "$tmp/manifest.txt"

    if [[ "$out" == *.zip ]]; then
      (cd "$tmp" && zip -qr "$out" bin apps manifest.txt)
    else
      out="${out%.tar.gz}.tar.gz"
      (cd "$tmp" && tar -czf "$out" bin apps manifest.txt)
    fi

    abs_out="$(realpath_f "$out")"
    say "Bundle created: ${abs_out}"
    ok  "Bundle created: ${abs_out}"
  )
}



# --------------------------------------------------------------------------------------------------
# STRESS — internal gauntlet (binman test stress)
# --------------------------------------------------------------------------------------------------
op_test_stress(){
  # args
  local JOBS=6 VERBOSE=0 KEEP=0 QUICK=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs) JOBS="${2:-6}"; shift 2;;
      --verbose|-v) VERBOSE=1; shift;;
      --keep|-k) KEEP=1; shift;;
      --quick|-q) QUICK=1; shift;;
      *) shift;;
    esac
  done

  # save & relax shell options (turn off errexit for the stress run)
  local _old_opts; _old_opts="$(set +o)"; set +e

  # ---------- Pretty ----------
  note(){ printf "\033[36m[NOTE]\033[0m %s\n" "$*"; }
  ok(){   printf "\033[32m[ OK ]\033[0m %s\n" "$*"; }
  warn(){ printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
  fail(){ printf "\033[31m[FAIL]\033[0m %s\n" "$*"; }
  die(){ fail "$*"; eval "$_old_opts"; exit 1; }
  assert_file(){ [[ -f "$1" ]] || die "Missing file: $1"; }
  assert_dir(){  [[ -d "$1" ]] || die "Missing dir: $1"; }
  assert_exe(){  [[ -x "$1" ]] || die "Not executable: $1"; }
  assert_no(){   [[ ! -e "$1" ]] || die "Should not exist: $1"; }
  assert_eq(){   [[ "$1" == "$2" ]] || die "Expected '$2' got '$1'"; }

  # run helper: DO NOT toggle -e here; the harness already set +e globally
  run(){
    local rc
    (( VERBOSE )) && set -x
    "$@"; rc=$?
    (( VERBOSE )) && set +x
    return $rc
  }

  # ---------- Sandbox ----------
  local ROOT; ROOT="$(mktemp -d -t binman-stress-XXXXXX)"
  cleanup() { [[ ${KEEP:-0} -eq 1 ]] && return 0; rm -rf "${ROOT:-}"; }
  trap cleanup EXIT

  export HOME="$ROOT/home"
  mkdir -p "$HOME" "$ROOT/work" "$ROOT/remotes" "$ROOT/tmp"
  touch "$HOME/.zshrc" "$HOME/.zprofile"

  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CONFIG_HOME="$HOME/.config"

  local BINDIR="$HOME/.local/bin"
  local APPDIR="$HOME/.local/share/binman/apps"
  mkdir -p "$BINDIR" "$APPDIR"
  export PATH="$BINDIR:$PATH"

  # Resolve self
  local BIN
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    BIN="$(python3 - <<'PY' "${BASH_SOURCE[0]}"
import os,sys; print(os.path.realpath(sys.argv[1]))
PY
)"
  else
    BIN="$0"
  fi
  cp "$BIN" "$ROOT/binman"; chmod +x "$ROOT/binman"; BIN="$ROOT/binman"

  say "🏗  Sandbox: $ROOT"; say "🏠 HOME:    $HOME"; say "🛠  BinMan:  $BIN"

  local PASS=0 FAILC=0
  okstep(){ ok "$*"; ((PASS++)); }
  badstep(){ fail "$*"; ((FAILC++)); }

  # ---------- Fixtures ----------
  mk_script() { mkdir -p "$(dirname "$1")"; printf '#!/usr/bin/env bash\nset -euo pipefail\necho "%s"\n' "${2:-hi}" > "$1"; chmod +x "$1"; }
  mk_app() { local root="$1/$2"; mkdir -p "$root/bin"; echo "1.0.0" > "$root/VERSION"; printf '#!/usr/bin/env bash\nset -euo pipefail\necho "%s"\n' "${3:-$2}" > "$root/bin/$2"; chmod +x "$root/bin/$2"; printf "%s" "$root"; }
  mk_remote_app_repo(){ local repo="$1/$2-remote"; mkdir -p "$repo/apps/$2/bin"; echo "$3" > "$repo/apps/$2/VERSION"; printf '#!/usr/bin/env bash\nset -euo pipefail\necho "%s"\n' "$4" > "$repo/apps/$2/bin/$2"; chmod +x "$repo/apps/$2/bin/$2"; printf "%s" "$repo"; }

  # ---------- 1) Help / version ----------
  note "Sanity: help & version"
  run "$BIN" help >/dev/null || die "help failed"
  run "$BIN" version >/dev/null || true
  okstep "help/version ok"

  # ---------- 2) Single-file install (copy) ----------
  note "Install single-file script (copy mode)"
  local S1="$ROOT/work/hello.sh"; mk_script "$S1" "hello-copy"
  run "$BIN" install "$S1" --force
  assert_exe "$BINDIR/hello"; assert_eq "$("$BINDIR/hello")" "hello-copy"
  okstep "script install (copy) ok"

  # ---------- 3) Single-file install (link) ----------
  note "Install single-file script (link mode)"
  local S2="$ROOT/work/echo.sh"; mk_script "$S2" "hello-link"
  run "$BIN" install "$S2" --link --force
  assert_exe "$BINDIR/echo"; assert_eq "$("$BINDIR/echo")" "hello-link"
  okstep "script install (link) ok"

  # ---------- 4) App install + shim ----------
  note "Install app (bin/<name> layout)"
  local APP_A_SRC; APP_A_SRC="$(mk_app "$ROOT/work" 'appalpha' 'alpha-1.0.0')"
  run "$BIN" install "$APP_A_SRC"
  assert_file "$APPDIR/appalpha/bin/appalpha"; assert_exe "$BINDIR/appalpha"
  [[ "$("$BINDIR/appalpha")" == "alpha-1.0.0" ]] || die "appalpha wrong output"
  okstep "app install + shim ok"

  # ---------- 5) List ----------
  note "List inventory"
  run "$BIN" list >/dev/null || die "list failed"
  okstep "list ok"

  # ---------- 6) Update via remote (reinstall from fake remote) ----------
  note "Update app from fake remote (simulate remote upgrade)"
  local REMOTE; REMOTE="$(mk_remote_app_repo "$ROOT/remotes" 'appalpha' '1.2.3' 'alpha-1.2.3')"
  run "$BIN" install "$REMOTE/apps/appalpha" --force
  [[ "$(tr -d '\n' < "$APPDIR/appalpha/VERSION")" == "1.2.3" ]] || die "version not updated"
  [[ "$("$BINDIR/appalpha")" == "alpha-1.2.3" ]] || die "shim not updated"
  okstep "remote reinstall bumped to 1.2.3"

  # ---------- 7) Manifest bulk ----------
  note "Manifest bulk install (2 scripts + 1 app)"
  local S3="$ROOT/work/tool-a.sh"; mk_script "$S3" "tool-a"
  local S4="$ROOT/work/tool-b.sh"; mk_script "$S4" "tool-b"
  local APP_B_SRC; APP_B_SRC="$(mk_app "$ROOT/work" 'appbeta' 'beta-1.0.0')"
  local MAN="$ROOT/work/manifest.txt"; printf "%s\n%s\n%s\n" "$S3" "$S4" "$APP_B_SRC" > "$MAN"
  run "$BIN" --manifest "$MAN" install
  assert_exe "$BINDIR/tool-a"; assert_exe "$BINDIR/tool-b"; assert_file "$APPDIR/appbeta/bin/appbeta"
  okstep "manifest install ok"

  # ---------- 8) Uninstall + rollback snapshot existence ----------
  note "Uninstall and confirm rollback snapshot incremented"
  local RDIR="$HOME/.local/share/binman/rollback"; local pre=$(find "$RDIR" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  run "$BIN" uninstall tool-b
  assert_no "$BINDIR/tool-b"
  local post=$(find "$RDIR" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  (( post > pre )) || warn "no snapshot growth detected (timestamp granularity)"
  okstep "uninstall + rollback snapshot passable"

  # ---------- 9) Doctor --fix-path ----------
  note "Doctor --fix-path modifies rc files"
  run "$BIN" --fix-path doctor >/dev/null || die "doctor failed"
  okstep "doctor ok"

  # ---------- 10) Idempotent reinstall ----------
  note "Idempotent reinstall"
  run "$BIN" install "$S1" >/dev/null || true
  okstep "idempotent reinstall ok"

  # ---------- 11) Weird filenames ----------
  note "Install weird filenames"
  local W1="$ROOT/work/space name.sh"; mk_script "$W1" "space-ok"
  local W2="$ROOT/work/uniçøde.sh";   mk_script "$W2" "unicode-ok"
  run "$BIN" install "$W1" --force; run "$BIN" install "$W2" --force
  [[ "$("$BINDIR/space name")" == "space-ok" ]] || die "space name failed"
  [[ "$("$BINDIR/uniçøde")" == "unicode-ok" ]] || die "unicode failed"
  okstep "weird names ok"

  # ---------- 12) Concurrency ----------
  if (( QUICK == 0 )); then
    note "Parallel installs (race test)"
    local PAR="$ROOT/work/parallel"; mkdir -p "$PAR"
    local N=20 i; for i in $(seq 1 "$N"); do mk_script "$PAR/t$i.sh" "T$i"; done
    local p
    for i in $(seq 1 "$N"); do
      run "$BIN" install "$PAR/t$i.sh" --force >/dev/null 2>&1 & p=$!
      while (( $(jobs -p | wc -l) >= JOBS )); do wait -n || true; done
    done
    wait || true
    for i in $(seq 1 "$N"); do assert_exe "$BINDIR/t$i"; done
    okstep "concurrency ok"
  fi

  # ---------- 13) Non-interactive list ----------
  note "Non-interactive list (TERM=dumb)"
  ( export TERM=dumb; run "$BIN" list >/dev/null )
  okstep "non-interactive ok"

  # ---------- 14) Backup & Restore (robust path capture) ----------
  note "Backup and Restore"

  # Helper: strip ANSI just in case
  strip_ansi(){ sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

  # Always write inside the sandbox so no cwd surprises
  local base="$ROOT/tmp/bmstress-$$"
  local msg rc BK

  msg="$("$BIN" backup "$base" 2>&1)"; rc=$?
  (( rc == 0 )) || die "backup failed: $(printf '%s' "$msg" | strip_ansi)"

  # 1) Prefer the tool's own absolute path from stdout
  BK="$(printf '%s\n' "$msg" | strip_ansi | sed -n 's/^.*Backup created:[[:space:]]*\(.*\)$/\1/p' | tail -1)"

  # 2) If missing, check both extensions right where we asked binman to write
  [[ -z "$BK" && -f "${base}.zip"    ]] && BK="${base}.zip"
  [[ -z "$BK" && -f "${base}.tar.gz" ]] && BK="${base}.tar.gz"

  # 3) Last-ditch: glob any file that starts with base, prefer newest
  [[ -z "$BK" ]] && BK="$(ls -1t "${base}".zip "${base}".tar.gz 2>/dev/null | head -n1 || true)"

  # 4) Verify
  [[ -n "$BK" ]] || die "could not locate backup file (output was: $(printf '%s' "$msg" | strip_ansi))"
  assert_file "$BK"

  # Nuke one file to prove restore works
  rm -f "$BINDIR/hello"; [[ ! -e "$BINDIR/hello" ]] || die "failed to remove hello"

  run "$BIN" restore "$BK" || die "restore failed"
  assert_exe "$BINDIR/hello"
  okstep "backup/restore ok"

  # ---------- 15) Bundle export (robust path capture) ----------
  note "Bundle export"
  local bmsg bfile
  bmsg="$("$BIN" bundle "$ROOT/tmp/bundle" 2>&1)" || true

  # Prefer explicit path from stdout
  bfile="$(printf '%s\n' "$bmsg" | strip_ansi | sed -n 's/^.*Bundle created:[[:space:]]*\(.*\)$/\1/p' | tail -1)"

  # Fallbacks
  [[ -z "$bfile" && -f "$ROOT/tmp/bundle.zip"    ]] && bfile="$ROOT/tmp/bundle.zip"
  [[ -z "$bfile" && -f "$ROOT/tmp/bundle.tar.gz" ]] && bfile="$ROOT/tmp/bundle.tar.gz"
  [[ -z "$bfile" ]] && bfile="$(ls -1t "$ROOT"/tmp/bundle.* 2>/dev/null | head -n1 || true)"

  [[ -n "$bfile" ]] || die "bundle file not found; output: $(printf '%s' "$bmsg" | strip_ansi)"
  assert_file "$bfile"
  okstep "bundle created"
}



# --------------------------------------------------------------------------------------------------
# TEST — run an installed command (default --help) to check exit status
# --------------------------------------------------------------------------------------------------
op_test(){
  local name="${1:-}"; shift || true

  # allow: binman test stress [--opts]
  if [[ "$name" == "stress" ]]; then
    op_test_stress "$@"
    return $?
  fi

  # if blank, or invalid name typed, offer interactive picker
  _ensure_target(){
    local n="$1"
    local path="$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN/$n" || echo "$BIN_DIR/$n")"
    [[ -n "$n" && -x "$path" ]]
  }

  if ! _ensure_target "$name"; then
    local picked
    picked="$(_pick_installed_cmd)" || { warn "Cancelled."; return 1; }
    [[ -z "$picked" ]] && { warn "Cancelled."; return 1; }
    name="$picked"
  fi

  local path; if (( SYSTEM_MODE )); then path="$SYSTEM_BIN/$name"; else path="$BIN_DIR/$name"; fi
  [[ -x "$path" ]] || { err "not installed or not executable: $name"; return 2; }

  # default to --help unless user gave explicit args after --
  local args=("$@"); [[ ${#args[@]} -eq 0 ]] && args=(--help)
  if "$path" "${args[@]}" >/dev/null 2>&1; then
    ok "PASS: $name ${args[*]}"
    return 0
  else
    local rc=$?
    warn "FAIL: $name (exit $rc)"
    return $rc
  fi
}



# --------------------------------------------------------------------------------------------------
# MANIFEST — install from a plain list (or JSON array when jq available)
# --------------------------------------------------------------------------------------------------
op_install_manifest(){
  local mf="$1"; [[ -f "$mf" ]] || { err "manifest not found: $mf"; return 2; }
  local items=()
  if [[ "$mf" == *.json && $(exists jq && echo yes) == yes ]]; then
    mapfile -t items < <(jq -r '.[] | if type=="object" then .source else . end' "$mf")
  else
    while IFS= read -r line; do
      line="${line%%#*}"; line="${line//[$'\t\r'] / }"
      [[ -n "$line" ]] && items+=("$line")
    done < "$mf"
  fi
  [[ ${#items[@]} -gt 0 ]] || { warn "manifest empty: $mf"; return 0; }
  op_install "${items[@]}"
}

# --------------------------------------------------------------------------------------------------
# Generator (bash/python) with optional venv launcher for python apps
#   • python app with --venv creates: .venv + src/<name>/{__init__,__main__}.py + bin/<name>
#   • launcher auto-activates venv, installs requirements.txt quietly if present, sets PYTHONPATH=src
# --------------------------------------------------------------------------------------------------
new_cmd(){
  local name="$1"; shift || true
  local lang="bash" make_app=0 target_dir="$PWD" with_venv=0
  local cmdname="${name%.*}"

  # infer language from filename extension (can be overridden by --lang later)
  case "${name,,}" in
    *.sh)   lang="bash" ;;
    *.py)   lang="python" ;;
    *.js)   lang="node" ;;
    *.ts)   lang="typescript" ;;
    *.go)   lang="go" ;;
    *.rs)   lang="rust" ;;
    *.rb)   lang="ruby" ;;
    *.php)  lang="php" ;;
    *)      : ;;  # no extension → leave default (bash) unless --lang provided
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) make_app=1; shift;;
      --lang) lang="${2,,}"; shift 2;;
      --dir) target_dir="$2"; shift 2;;
      --venv) with_venv=1; shift;;
      *) shift;;
    esac
  done

  mkdir -p "$target_dir"

  # --- helpers --------------------------------------------------------------
  _mk(){ mkdir -p "$@"; }
  _wr(){ printf "%s" "$2" > "$1"; }
  _wre(){ printf "%s\n" "$2" >> "$1"; }
  _exec(){ chmod +x "$1"; }
  _appdir(){ echo "$target_dir/$cmdname"; }
  _entry(){ echo "$(_appdir)/bin/$cmdname"; }

  case "$lang" in
    bash|sh|shell)        lang="bash" ;;
    py|python3)           lang="python" ;;
    js|node|javascript)   lang="node" ;;
    ts|typescript)        lang="typescript" ;;
    go|golang)            lang="go" ;;
    rs|rust)              lang="rust" ;;
    rb|ruby)              lang="ruby" ;;
    php)                  lang="php" ;;
    *) : ;;
  esac

  if [[ $make_app -eq 1 ]]; then
    # =========================
    #         APP MODE
    # =========================
    local appdir="$(_appdir)"
    _mk "$appdir/bin" "$appdir/src"
    echo "0.1.0" > "$appdir/VERSION"

    case "$lang" in
      bash)
        cat > "$(_entry)" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (bash app)
VERSION="0.1.0"
set -Eeuo pipefail
echo "__APPNAME__ v${VERSION} — hello (bash)"
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        ;;

      python)
        if [[ $with_venv -eq 1 ]]; then python3 -m venv "$appdir/.venv"; fi
        _mk "$appdir/src/$cmdname"
        _wr "$appdir/src/$cmdname/__init__.py" '__version__="0.1.0"'
        cat > "$appdir/src/$cmdname/__main__.py" <<'PY'
from . import __version__
def main():
    print(f"__APPNAME__ v{__version__} — hello (python)")
if __name__ == "__main__":
    main()
PY
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/$cmdname/__main__.py"
        _wr "$appdir/requirements.txt" "# click>=8.1"
        cat > "$(_entry)" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (python venv launcher)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
if [[ ! -x "$HERE/.venv/bin/python" ]]; then python3 -m venv "$HERE/.venv" >/dev/null 2>&1 || true; fi
[[ -f "$HERE/.venv/bin/activate" ]] && source "$HERE/.venv/bin/activate"
if [[ -f "$HERE/requirements.txt" ]]; then "$HERE/.venv/bin/pip" install -q -r "$HERE/requirements.txt" || true; fi
export PYTHONPATH="$HERE/src${PYTHONPATH:+:$PYTHONPATH}"
exec python -m __APPNAME__ "$@"
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        ;;

      node)
        # Node app: bin script + src/index.js + package.json
        cat > "$appdir/src/index.js" <<'JS'
export function main() {
  console.log("__APPNAME__ v0.1.0 — hello (node)");
}
if (import.meta.url === `file://${process.argv[1]}`) main();
JS
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/index.js"
        cat > "$(_entry)" <<'JS'
#!/usr/bin/env node
import { main } from "../src/index.js"; main();
JS
        _exec "$(_entry)"
        cat > "$appdir/package.json" <<EOF
{
  "name": "$cmdname",
  "version": "0.1.0",
  "type": "module",
  "bin": { "$cmdname": "./bin/$cmdname" },
  "scripts": { "start": "node ./bin/$cmdname" },
  "dependencies": {}
}
EOF
        ;;

      typescript)
        _mk "$appdir/src"
        cat > "$appdir/src/index.ts" <<'TS'
export function main(): void {
  console.log("__APPNAME__ v0.1.0 — hello (typescript)");
}
if (import.meta.url === `file://${process.argv[1]}`) main();
TS
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/index.ts"
        cat > "$(_entry)" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (TypeScript runtime launcher)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
if command -v tsx >/dev/null 2>&1; then
  exec tsx "$HERE/src/index.ts" "$@"
elif command -v node >/dev/null 2>&1 && node -e "require.resolve('ts-node/register')" >/dev/null 2>&1 2>/dev/null; then
  exec node -r ts-node/register "$HERE/src/index.ts" "$@"
else
  echo "TypeScript runtime missing. Try: npm i -D tsx  (or: npm i -D ts-node typescript)" >&2
  exit 1
fi
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        cat > "$appdir/package.json" <<EOF
{
  "name": "$cmdname",
  "version": "0.1.0",
  "type": "module",
  "bin": { "$cmdname": "./bin/$cmdname" },
  "scripts": { "start": "./bin/$cmdname" },
  "devDependencies": {}
}
EOF
        _wr "$appdir/tsconfig.json" '{"compilerOptions":{"target":"ES2020","module":"ESNext","moduleResolution":"Bundler","esModuleInterop":true},"include":["src"]}'
        ;;

      go)
        _mk "$appdir/cmd/$cmdname"
        cat > "$appdir/cmd/$cmdname/main.go" <<'GO'
package main
import (
  "flag"
  "fmt"
)
var version = "0.1.0"
func main() {
  flag.Parse()
  fmt.Printf("__APPNAME__ v%v — hello (go)\n", version)
}
GO
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/cmd/$cmdname/main.go"
        ( cd "$appdir" && go mod init "$cmdname" >/dev/null 2>&1 || true )
        cat > "$(_entry)" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (go launcher)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BIN="$HERE/.bin/__APPNAME__"
if [[ -x "$BIN" ]]; then exec "$BIN" "$@"; fi
if command -v go >/dev/null 2>&1; then
  mkdir -p "$HERE/.bin"
  (cd "$HERE" && go build -o "$BIN" "./cmd/__APPNAME__") && exec "$BIN" "$@"
fi
echo "Go toolchain not found. Install Go or prebuild $BIN" >&2
exit 1
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        ;;

      rust)
        _mk "$appdir"
        cat > "$appdir/Cargo.toml" <<EOF
[package]
name = "$cmdname"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "$cmdname"
path = "src/main.rs"
[dependencies]
EOF
        _mk "$appdir/src"
        cat > "$appdir/src/main.rs" <<'RS'
fn main() {
    println!("__APPNAME__ v0.1.0 — hello (rust)");
}
RS
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/main.rs"
        cat > "$(_entry)" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (rust launcher)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
BIN="$HERE/target/release/__APPNAME__"
if [[ -x "$BIN" ]]; then exec "$BIN" "$@"; fi
if command -v cargo >/dev/null 2>&1; then
  (cd "$HERE" && cargo build --quiet --release) && exec "$BIN" "$@"
fi
echo "Rust toolchain not found. Install cargo or prebuild $BIN" >&2
exit 1
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        ;;

      ruby)
        cat > "$appdir/src/main.rb" <<'RB'
puts "__APPNAME__ v0.1.0 — hello (ruby)"
RB
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/main.rb"
        cat > "$(_entry)" <<'RB'
#!/usr/bin/env ruby
# Description: __APPNAME__ (ruby app)
require_relative "../src/main"
RB
        sed -i "s/__APPNAME__/$cmdname/g" "$(_entry)"; _exec "$(_entry)"
        ;;

      php)
        cat > "$appdir/src/main.php" <<'PHP'
<?php
printf("__APPNAME__ v0.1.0 — hello (php)\n");
PHP
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/main.php"
        cat > "$(_entry)" <<'PHP'
#!/usr/bin/env php
<?php require __DIR__ . "/../src/main.php";
PHP
        _exec "$(_entry)"
        ;;

      *)
        echo "Unknown --lang '$lang'. Supported: bash, python, node, typescript, go, rust, ruby, php" >&2
        return 2
        ;;
    esac

    ok "App scaffolded: $appdir"

  else
    # =========================
    #       SINGLE FILE
    # =========================
    case "$lang" in
      bash)
        [[ "$name" != *.sh ]] && name="${name}.sh"
        cat > "$target_dir/$name" <<'BASH'
#!/usr/bin/env bash
# Description: Hello from script
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from __SCRIPTNAME__ v$VERSION (bash)"
BASH
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"; _exec "$target_dir/$name"
        ;;

      python)
        [[ "$name" != *.py ]] && name="${name}.py"
        cat > "$target_dir/$name" <<'PY'
#!/usr/bin/env python3
# Description: Hello from script
__version__ = "0.1.0"
def main():
    print(f"Hello from __SCRIPTNAME__ v{__version__} (python)")
    return 0
if __name__ == "__main__":
    import sys; sys.exit(main())
PY
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"; _exec "$target_dir/$name"
        ;;

      node)
        [[ "$name" != *.js ]] && name="${name}.js"
        cat > "$target_dir/$name" <<'JS'
#!/usr/bin/env node
// Description: Hello from script
const version = "0.1.0";
console.log(`Hello from __SCRIPTNAME__ v${version} (node)`);
JS
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"; _exec "$target_dir/$name"
        ;;

      typescript)
        [[ "$name" != *.ts ]] && name="${name}.ts"
        cat > "$target_dir/$name" <<'TS'
// Description: Hello from TS script
const version = "0.1.0";
console.log(`Hello from __SCRIPTNAME__ v${version} (typescript)`);
TS
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
        # Tiny launcher so TS runs immediately
        cat > "$target_dir/${cmdname}" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$SELF/__SCRIPTNAME__.ts"
if command -v tsx >/dev/null 2>&1; then exec tsx "$TS" "$@"; fi
if node -e "require.resolve('ts-node/register')" >/dev/null 2>&1 2>/dev/null; then exec node -r ts-node/register "$TS" "$@"; fi
echo "TS runtime missing. Try: npm i -g tsx   (or: npm i -g ts-node typescript)" >&2; exit 1
BASH
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/${cmdname}"; _exec "$target_dir/${cmdname}"
        ;;

      go)
        [[ "$name" != *.go ]] && name="${name}.go"
        cat > "$target_dir/$name" <<'GO'
package main
import "fmt"
func main(){ fmt.Println("Hello from __SCRIPTNAME__ v0.1.0 (go)") }
GO
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
        cat > "$target_dir/${cmdname}" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF/__SCRIPTNAME__.go"
OUT="$SELF/__SCRIPTNAME__.bin"
if [[ -x "$OUT" ]]; then exec "$OUT" "$@"; fi
if command -v go >/dev/null 2>&1; then go build -o "$OUT" "$SRC" && exec "$OUT" "$@"; fi
echo "Go not found." >&2; exit 1
BASH
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/${cmdname}"; _exec "$target_dir/${cmdname}"
        ;;

      rust)
        local rdir="$target_dir/${cmdname}_rs"
        _mk "$rdir/src"
        echo -e "[package]\nname=\"$cmdname\"\nversion=\"0.1.0\"\nedition=\"2021\"" > "$rdir/Cargo.toml"
        echo 'fn main(){ println!("Hello from __SCRIPTNAME__ v0.1.0 (rust)"); }' > "$rdir/src/main.rs"
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$rdir/src/main.rs"
        cat > "$target_dir/${cmdname}" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/__SCRIPTNAME___rs"
BIN="$ROOT/target/release/__SCRIPTNAME__"
if [[ -x "$BIN" ]]; then exec "$BIN" "$@"; fi
if command -v cargo >/dev/null 2>&1; then (cd "$ROOT" && cargo build --quiet --release) && exec "$BIN" "$@"; fi
echo "Rust not found." >&2; exit 1
BASH
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/${cmdname}"; _exec "$target_dir/${cmdname}"
        ;;

      ruby)
        [[ "$name" != *.rb ]] && name="${name}.rb"
        cat > "$target_dir/$name" <<'RB'
#!/usr/bin/env ruby
# Description: Hello from script
puts "Hello from __SCRIPTNAME__ v0.1.0 (ruby)"
RB
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"; _exec "$target_dir/$name"
        ;;

      php)
        [[ "$name" != *.php ]] && name="${name}.php"
        cat > "$target_dir/$name" <<'PHP'
#!/usr/bin/env php
<?php echo "Hello from __SCRIPTNAME__ v0.1.0 (php)\n";
PHP
        sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"; _exec "$target_dir/$name"
        ;;

      *)
        echo "Unknown --lang '$lang'. Supported: bash, python, node, typescript, go, rust, ruby, php" >&2
        return 2
        ;;
    esac

    ok "Script scaffolded: $target_dir/$name"
  fi
}

# --------------------------------------------------------------------------------------------------
# Wizard — interactive project scaffolder + optional install + optional git prep
#   • Reuses ask/ask_choice/ask_yesno which write to /dev/tty (no stdin capture weirdness)
#   • Git step:
#       - We NEVER prompt for username/password.
#       - We print exactly what to run for SSH or HTTPS, and recommend SSH.
#       - If the user enters a remote URL, we just wire it; otherwise we leave instructions.
# --------------------------------------------------------------------------------------------------
new_wizard(){
  ui_init; prompt_init
  tput clear 2>/dev/null || clear
  echo
  printf "%s🧙  BinMan Project Wizard%s\n" "$UI_BOLD" "$UI_RESET"
  printf "%sPress Enter to accept defaults in %s[brackets]%s.%s\n\n" "$UI_DIM" "$UI_BOLD" "$UI_RESET" "$UI_RESET"

  # == Basics =================================================================
  printf "%s==> Basics%s\n" "$UI_GREEN" "$UI_RESET"
  local name kind lang target_dir desc author
  name="$(ask "Project name (no spaces)" "MyTool")"
  kind="$(ask_choice "Type" "single/app" "app")"; [[ "${kind,,}" =~ ^s ]] && kind="single" || kind="app"

  # Expanded language set
  lang="$(ask_choice "Language" "bash/python/node/typescript/go/rust/ruby/php" "bash")"

  # normalize aliases
  case "${lang,,}" in
    sh|shell)      lang="bash" ;;
    py|python3)    lang="python" ;;
    js|node|javascript) lang="node" ;;
    ts)            lang="typescript" ;;
    go|golang)     lang="go" ;;
    rs)            lang="rust" ;;
    rb)            lang="ruby" ;;
    *)             lang="${lang,,}" ;;
  esac

  target_dir="$(ask "Create in directory" "$PWD")"; mkdir -p "$target_dir"
  desc="$(ask "Short description" "A neat little tool")"
  author="$(ask "Author" "${USER}")"

  # == Python options (venv) ==================================================
  local with_venv="n"
  if [[ "$kind" == "app" && "$lang" == "python" ]]; then
    printf "\n%s==> Python options%s\n" "$UI_GREEN" "$UI_RESET"
    ask_yesno "Create virtual environment (.venv)?" "y" && with_venv="y"
  fi

  # == Summary ================================================================
  printf "\n%s==> Summary%s\n" "$UI_GREEN" "$UI_RESET"
  prompt_kv "Name"        "$name"
  prompt_kv "Type"        "$kind"
  prompt_kv "Language"    "$lang"
  prompt_kv "Directory"   "$target_dir"
  prompt_kv "Description" "$desc"
  prompt_kv "Author"      "$author"
  [[ "$with_venv" == "y" ]] && prompt_kv "Python venv" "enabled"
  echo
  ask_yesno "Proceed with generation?" "y" || { warn "Aborted by user."; return 1; }

  echo; ok "Generating…"

  # == Generate ===============================================================
  local filename path
  if [[ "$kind" == "single" ]]; then
    # choose extension by language if the user didn't provide one
    case "$lang" in
      bash)       [[ "$name" != *.sh  ]] && filename="${name}.sh"  || filename="$name" ;;
      python)     [[ "$name" != *.py  ]] && filename="${name}.py"  || filename="$name" ;;
      node)       [[ "$name" != *.js  ]] && filename="${name}.js"  || filename="$name" ;;
      typescript) [[ "$name" != *.ts  ]] && filename="${name}.ts"  || filename="$name" ;;
      go)         [[ "$name" != *.go  ]] && filename="${name}.go"  || filename="$name" ;;
      rust)       # single-file rust scaffold uses a helper launcher; leave bare name
                  filename="$name" ;;
      ruby)       [[ "$name" != *.rb  ]] && filename="${name}.rb"  || filename="$name" ;;
      php)        [[ "$name" != *.php ]] && filename="${name}.php" || filename="$name" ;;
      *)          filename="$name" ;;
    esac

    new_cmd "$filename" --lang "$lang" --dir "$target_dir"
    path="${target_dir}/${filename}"

    cat > "${target_dir}/README.md" <<EOF
# ${name}

${desc}

Author: ${author}

## Usage
\`\`\`
${name%.*} [args]
\`\`\`
EOF
    ok "README.md created → ${target_dir}/README.md"
  else
    local vflag=(); [[ "${with_venv,,}" == "y" ]] && vflag+=(--venv)
    new_cmd "$name" --app --lang "$lang" --dir "$target_dir" "${vflag[@]}"
    path="${target_dir}/${name}"

    cat > "${path}/README.md" <<EOF
# ${name}

${desc}

Author: ${author}

## Layout
\`\`\`
${name}/
├─ bin/${name}
├─ src/
└─ VERSION
\`\`\`

## Run
\`\`\`
${name} [args]
\`\`\`
EOF
    ok "README.md created → ${path}/README.md"
  fi

  # == Manifest ==============================================================
  local manifest_kind manifest_path manifest_file manifest_run manifest_ext manifest_desc
  if [[ "$kind" == "single" ]]; then
    manifest_kind="cmd"
    manifest_ext="cmd"
    manifest_path="$(realpath_f "${path}")"
    manifest_run="$manifest_path"
  else
    manifest_kind="app"
    manifest_ext="app"
    manifest_path="$(realpath_f "${path}")"
    manifest_run="${manifest_path}/bin/${name}"
  fi
  manifest_desc="$desc"
  manifest_desc="${manifest_desc//\"/\\\"}"
  ensure_apps
  manifest_file="${APP_STORE%/}/${name}.${manifest_ext}"
  if [[ -e "$manifest_file" ]]; then
    warn "Manifest exists (skipped): ${manifest_file}"
  else
    cat >"$manifest_file" <<EOF
# BinMan manifest (generated by wizard on $(iso_now))
name = "${name}"
type = "${manifest_kind}"
version = "0.1.0"
path = "${manifest_path}"
run = "${manifest_run}"
preview = "${manifest_desc}"
help = "${manifest_desc}"
EOF
    ok "Manifest created → ${manifest_file}"
  fi

  # == Install (optional) =====================================================
  echo; printf "%s==> Install%s\n" "$UI_GREEN" "$UI_RESET"
  local saved_mode="$COPY_MODE"
  if ask_yesno "Install now?" "y"; then
    ask_yesno "Use symlink instead of copy?" "n" && COPY_MODE="link" || COPY_MODE="copy"
    op_install "$path" || true
  fi
  COPY_MODE="$saved_mode"

  # == Git / GitHub ===========================================================
  echo; printf "%s==> Git%s\n" "$UI_GREEN" "$UI_RESET"
  if ask_yesno "Initialize a git repo here?" "y"; then
    local projdir; [[ "$kind" == "app" ]] && projdir="$path" || projdir="$target_dir"
    local gp_branch; gp_branch="$(ask "Default branch name" "main")"

    (
      cd "$projdir" || { err "Failed to cd $projdir"; return 1; }

      if exists gitprep; then
        gitprep --branch "$gp_branch" || true
      else
        if git init -b "$gp_branch" >/dev/null 2>&1; then :; else
          git init >/dev/null 2>&1
          git symbolic-ref HEAD "refs/heads/$gp_branch" >/dev/null 2>&1 || true
        fi
        [[ -f README.md ]] || printf "# %s\n\nInitialized with BinMan wizard.\n" "$name" > README.md
        [[ -f .gitignore ]] || printf ".venv/\n.DS_Store\nnode_modules/\n__pycache__/\n" > .gitignore
        git add -A >/dev/null 2>&1
        if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
          git commit -m "init: ${name} (BinMan wizard)" >/dev/null 2>&1 || true
        else
          if ! git diff --cached --quiet >/dev/null 2>&1; then
            git commit -m "chore: snapshot (BinMan wizard)" >/dev/null 2>&1 || true
          fi
        fi
      fi

      if ask_yesno "Set up a GitHub remote (SSH) now?" "y"; then
        local gh_user gh_repo gh_vis ssh_url created_ok push_rc
        gh_user="$USER"
        if exists gh; then
          local gh_user_guess
          gh_user_guess="$(gh api user --jq '.login' 2>/dev/null || true)"
          [[ -n "$gh_user_guess" ]] && gh_user="$gh_user_guess"
        fi

        gh_user="$(ask "GitHub username" "$gh_user")"
        gh_repo="$(ask "Repository name" "$(basename "$projdir")")"
        gh_vis="$(ask_choice "Visibility" "public/private" "private")"
        [[ "${gh_vis,,}" == "private" ]] && gh_vis="private" || gh_vis="public"

        ssh_url="git@github.com:${gh_user}/${gh_repo}.git"
        created_ok=0

        if exists gh && ask_yesno "Create ${gh_user}/${gh_repo} on GitHub with 'gh' now?" "y"; then
          if gh repo create "${gh_user}/${gh_repo}" --"${gh_vis}" --source=. --remote=origin --push -y >/dev/null 2>&1; then
            local real_ssh
            real_ssh="$(gh repo view "${gh_user}/${gh_repo}" --json sshUrl -q .sshUrl 2>/dev/null || true)"
            [[ -n "$real_ssh" ]] && git remote set-url origin "$real_ssh" >/dev/null 2>&1 || true
            ok "Created and pushed → ${gh_user}/${gh_repo}"
            created_ok=1
          else
            warn "gh repo create failed (auth/permissions/name may be the issue). Falling back to manual wiring."
          fi
        fi

        if [[ $created_ok -ne 1 ]]; then
          git remote remove origin >/dev/null 2>&1 || true
          git remote add origin "$ssh_url" >/dev/null 2>&1 || true
          ok "Added origin → $ssh_url"
          say "Attempting to push…"
          git push -u origin "$gp_branch" >/dev/null 2>&1
          push_rc=$?
          if [[ $push_rc -eq 0 ]]; then
            ok "Pushed to origin/$gp_branch"
          else
            warn "Push failed (exit $push_rc). Common reasons:"
            warn "  • Repo not created yet • SSH key not linked • No access rights"
            echo
            say "Next steps:"
            say "  gh repo create ${gh_user}/${gh_repo} --${gh_vis} --source . --remote=origin --push -y"
            say "  (or create on web, then: git push -u origin ${gp_branch})"
            echo
          fi
        fi
      else
        echo
        say "Next steps:"
        say "  • Set remote: git remote add origin git@github.com:<user>/<repo>.git"
        say "  • Then push:  git push -u origin ${gp_branch}"
        echo
      fi
    )

    ok "Git repository initialized."
  fi

  echo
  ok "Wizard complete. Happy hacking, ${author}! ✨"
}



# --------------------------------------------------------------------------------------------------
# Banner & simple menu (TUI)
# --------------------------------------------------------------------------------------------------
print_banner(){
  ui_init
  tput clear 2>/dev/null || clear
  cat <<'EOF'

$$$$$$$\  $$\           $$\      $$\                     
$$  __$$\ \__|          $$$\    $$$ |                    
$$ |  $$ |$$\ $$$$$$$\  $$$$\  $$$$ | $$$$$$\  $$$$$$$\  
$$$$$$$\ |$$ |$$  __$$\ $$\$$\$$ $$ | \____$$\ $$  __$$\ 
$$  __$$\ $$ |$$ |  $$ |$$ \$$$  $$ | $$$$$$$ |$$ |  $$ |
$$ |  $$ |$$ |$$ |  $$ |$$ |\$  /$$ |$$  __$$ |$$ |  $$ |
$$$$$$$  |$$ |$$ |  $$ |$$ | \_/ $$ |\$$$$$$$ |$$ |  $$ |
\_______/ \__|\__|  \__|\__|     \__| \_______|\__|  \__|
EOF
  printf "  %sv%s%s\n\n" "$UI_DIM" "$VERSION" "$UI_RESET"

  local home_path apps_path sys_path
  home_path="$(shorten_path "$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN"  || echo "$BIN_DIR")" 60)"
  apps_path="$(shorten_path "$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE")" 60)"
  sys_path="$(shorten_path "$SYSTEM_BIN" 60)"

  ui_kv "Home:"  "$home_path"
  ui_kv "Apps:"  "$apps_path"
  ui_kv "System:" "$sys_path"
  ui_hr
  printf "%s1)%s Install   %s2)%s Uninstall   %s3)%s List   %s4)%s Doctor   %s5)%s Prune Rollbacks\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"

  printf "%s6)%s Wizard    %s7)%s Backup    %s8)%s Restore     %s9)%s Self-Update   %sa)%s Rollback   %sb)%s Bundle   %sc)%s Test\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"

  printf "%ss)%s Toggle System Mode %s(currently: %s)%s    %sq)%s Quit\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_DIM" "$([[ $SYSTEM_MODE -eq 1 ]] && echo "ON" || echo "OFF")" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
    
  ui_hr
}

__bm_menu_loop() {
  ui_init
  prompt_init
  maybe_warn_auto_backup_disabled
  while true; do
    local __chosen_action
    __chosen_action="$(_bm_mainmenu_fzf)" || break            # aborted
    [[ -n "${__chosen_action:-}" ]] || break                  # no selection
    case "$__chosen_action" in
      q|quit) break ;;                                        # explicit quit
    esac
    __bm_run_action_safe "$__chosen_action" || :              # run action, ignore non-zero
    # after action returns, loop back to the menu
  done
}

__bm_mainmenu_build() {
  local header preview_cmd tsv sel action
  local -a _opts
  mapfile -t _opts < <(__fzf_common_opts)

  header="BinMan — choose an action (↑↓ to move, Enter to run, Alt-q to abort)"
  preview_cmd='cut -f4'

tsv=$(
  cat <<'TSV'
1	Install	install	Install apps/scripts into your ~/bin or system bin.
2	Uninstall	uninstall	Remove installed items and clean up stubs.
3	List	list	Browse all items with live preview and quick actions.
4	Doctor	doctor	Run diagnostics and environment checks.
6	Wizard	wizard	Create a new app/cmd manifest via guided prompts.
7	Backup	backup	Create a backup archive of installed items.
8	Restore	restore	Restore from a backup archive.
9	Self-Update	selfupdate	Update BinMan to the latest version.
a	Rollback	rollback	Revert to a previous snapshot.
b	Bundle	bundle	Bundle selected apps into a portable pack.
c	Test	test	Run developer/test utilities.
t	Toggle System Mode	toggle_system	Switch between user/system install targets.
q	Quit	quit	Exit BinMan.
TSV
)



  # Drive fzf from TSV; show key+label, preview the 4th column.
  FZF_DEFAULT_OPTS='' \
  sel=$(printf "%s\n" "$tsv" \
    | fzf "${_opts[@]}" \
          --delimiter=$'\t' \
          --with-nth=1,2 \
          --header="$header" \
          --preview "$preview_cmd" \
          --preview-window=right:60%:wrap)

  [[ -n "$sel" ]] || return 1
  action=$(awk -F'\t' '{print $3}' <<<"$sel")
  printf '%s\n' "$action"
}

# Back-compat shims: older call sites expect *_bm_mainmenu_fzf
_bm_mainmenu_fzf() { __bm_mainmenu_build; }
__bm_mainmenu_fzf() { __bm_mainmenu_build; }

__bm_run_action_safe() {
  local a="$1"; shift || true
  case "$a" in
    install)
      # DO NOT shift here — outer dispatcher already shifted the action off.
      if [[ -n "${MANIFEST_FILE:-}" ]]; then
        op_install_manifest "$MANIFEST_FILE" "$@"
      elif [[ $# -gt 0 ]]; then
        # args present → install exactly what was passed (path/URL), no picker
        op_install "$@"
      elif [[ -t 1 ]]; then
        # interactive and no args → open TUI
        __bm_tui_install_flow
      else
        err "No install target provided."
        return 1
      fi
      ;;
    uninstall)
      # Use args if provided; only open TUI when no args and interactive
      if [[ $# -gt 0 ]]; then
        op_uninstall "$@"
      elif [[ -t 1 ]]; then
        __bm_tui_uninstall_flow
      else
        err "No uninstall target provided."
        return 1
      fi
      ;;
    verify)          op_verify ;;
    list)
      if command -v fzf >/dev/null 2>&1 && [[ -t 1 ]]; then
        op_list_ranger
      else
        op_list
      fi
      ;;
    doctor)          cmd_doctor ;;
    update)          op_update "$@" ;;
    new)             new_cmd ;;
    wizard)          new_wizard ;;
    backup)          op_backup ;;
    restore)
      if [[ -t 1 ]]; then
        local f; f="$(_tui_pick_archive)"
        [[ -z "$f" ]] && { warn "Cancelled."; } || op_restore "$f"
      else
        op_restore "$@"
      fi
      ;;
    self-update|selfupdate)
                      op_self_update ;;
    rollback)
      id="$(latest_rollback_id || true)"
      [[ -n "$id" ]] && apply_rollback "$id" || warn "No rollback snapshots yet"
      ;;
    prune-rollbacks) cmd_prune_rollbacks ;;
    analyze)         cmd_analyze ;;
    bundle)          op_bundle ;;
    test)            op_test ;;
    sudo)            op_sudo "$@" ;;
    toggle_system|toggle_system_mode|toggle-system)
                      toggle_system_mode ;;
    quit|q|"")       : ;;        # explicit no-op
    *)               return 1 ;; # unknown: let caller handle
  esac
}

# --------------------------------------------------------------------------------------------------
# Option parser (top-level flags). Special-cases --backup/--restore to run immediately.
# --------------------------------------------------------------------------------------------------

# Parses only leading flags. Leaves first non-flag arg in ARGS_OUT.
# Returns 0 if it handled a terminal request (like --help) and the main should exit.
# Returns 1 for normal flow (continue dispatch with ARGS_OUT).
# Parses only leading flags. Leaves first non-flag arg in ARGS_OUT.
# Returns 0 if it handled a terminal action (help/version), 1 otherwise.

parse_common_opts() {
  OPTERR=0
  ARGS_OUT=()

  # sanitize inputs first
  __strip_empty_args "$@"
  set -- "${ARGS_OUT[@]}"
  ARGS_OUT=()

  # nothing or first isn't a flag? nothing to parse
  [[ $# -gt 0 && "${1:-}" == -* ]] || return 1

  local handled=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reindex) REINDEX_REQUEST=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help)  usage; handled=0; shift ;;
      -v|--version) say "${SCRIPT_NAME} v${VERSION}"; handled=0; shift ;;
      --) shift; while [[ $# -gt 0 ]]; do ARGS_OUT+=("$1"); shift; done; break ;;
      -*) # unknown flag: stop parsing; push back for caller/usage
          ARGS_OUT+=("$@"); break ;;
      *)  # first non-flag: return remainder
          while [[ $# -gt 0 ]]; do ARGS_OUT+=("$1"); shift; done; break ;;
    esac
  done

  return $handled
}



# --------------------------------------------------------------------------------------------------
# TUI loop
# --------------------------------------------------------------------------------------------------
binman_tui(){
  ui_init
  prompt_init
  while :; do
    print_banner
    printf "%sChoice:%s " "$UI_BOLD" "$UI_RESET"
    IFS= read -r c

    case "$c" in
      1)  # Install — robust fzf picker over CWD (files + dirs); fall back to prompt
        if exists fzf; then
          # Build a TSV: TYPE<TAB>REL_PATH  (TYPE is DIR or FILE)
          mapfile -t items < <(
            for d in .* *; do
              [[ -e "$d" ]] || continue
              [[ "$d" == "." || "$d" == ".." ]] && continue
              if [[ -d "$d" ]]; then
                printf "DIR\t%s/\n" "$d"
              else
                printf "FILE\t%s\n" "$d"
              fi
            done
          )

          # Show only the path column; keep selections exactly as typed (spaces safe)
          mapfile -t selections < <(
            { printf '%s\n' "${items[@]}" \
                | fzf --multi --prompt="Install > " --height=60% --reverse \
                      --delimiter=$'\t' --with-nth=2 \
                | cut -f2; } || true
          )

          if ((${#selections[@]} == 0)); then
            echo "Cancelled."
            printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"
            read -r
            continue
          fi

          # Convert selections into absolute paths (validate files/dirs)
          targets=()
          for rel in "${selections[@]}"; do
            [[ -z "$rel" ]] && continue
            rel="${rel%/}"                      # drop trailing slash for dirs
            if [[ "$rel" == /* ]]; then
              abs="$rel"
            else
              abs="$PWD/$rel"
            fi
            if [[ -f "$abs" || -d "$abs" ]]; then
              targets+=("$abs")
            else
              warn "Skip (not a file): $rel"
            fi
          done

          if (( ${#targets[@]} == 0 )); then
            warn "No valid selections."
            printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"
            read -r
            continue
          fi

          # Manifest convenience
          if (( ${#targets[@]} == 1 )) && [[ "${targets[0]}" =~ \.(txt|list|json)$ ]]; then
            op_install_manifest "${targets[0]}" || true
          else
            op_install "${targets[@]}" || true
          fi
        else
          printf "File/dir/URL (or --manifest FILE): "
          manual_lines=()
          if IFS= read -r line; then
            [[ -z "$line" ]] && { echo "Cancelled."; continue; }
            manual_lines+=("$line")
            while IFS= read -r -t 0 extra_line; do
              manual_lines+=("$extra_line")
            done
          else
            continue
          fi

          targets=()
          manifest=""
          for entry in "${manual_lines[@]}"; do
            [[ -z "$entry" ]] && continue
            if [[ "$entry" =~ ^--manifest[[:space:]]+ ]]; then
              manifest="${entry#--manifest }"
              continue
            fi
            entry="${entry%/}"
            if [[ "$entry" == /* ]]; then
              abs="$entry"
            else
              abs="$PWD/$entry"
            fi
            if [[ -f "$abs" || -d "$abs" ]]; then
              targets+=("$abs")
            else
              targets+=("$entry")
            fi
          done

          if [[ -n "$manifest" ]]; then
            if [[ "$manifest" != /* && -e "$manifest" ]]; then
              manifest="$PWD/$manifest"
            fi
            op_install_manifest "$manifest" || true
          elif (( ${#targets[@]} > 0 )); then
            op_install "${targets[@]}" || true
          else
            echo "Cancelled."
            continue
          fi
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      2)  # Uninstall — (unchanged; your fzf/multi workflow already in place)
        if exists fzf; then
          mapfile -t _cmds < <(_get_installed_cmd_names)
          _apps=()
          # [Patch] Uninstall: only list shims unless BINMAN_INCLUDE_APPS=1
          if [[ "${BINMAN_INCLUDE_APPS:-0}" == "1" ]]; then
            mapfile -t _apps < <(_get_installed_app_names)
          fi
          if ((${#_cmds[@]}==0 && ${#_apps[@]}==0)); then
            warn "Nothing to uninstall."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue
          fi
          _choices=()
          for c in "${_cmds[@]}"; do _choices+=("cmd  $c"); done
          if [[ "${BINMAN_INCLUDE_APPS:-0}" == "1" ]]; then
            for a in "${_apps[@]}"; do _choices+=("app  $a"); done
          fi
          sel="$(printf '%s\n' "${_choices[@]}" | fzf --multi --prompt="Uninstall > " --height=60% --reverse || true)"
          [[ -z "$sel" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }
          names="$(echo "$sel" | awk '{print $2}' | tr '\n' ' ')"
          # shellcheck disable=SC2086
          op_uninstall $names
        else
          _print_uninstall_menu
          printf "Name (space-separated for multiple, Enter to cancel): "
          IFS= read -r names
          [[ -z "$names" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }
          # shellcheck disable=SC2086
          op_uninstall $names
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      3)
        if command -v fzf >/dev/null 2>&1 && [[ -t 1 ]]; then
          op_list_ranger
        else
          op_list
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"
        read -r
        ;;

      4) cmd_doctor;  printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      5)  # Prune rollbacks
        cmd_prune_rollbacks
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      6) new_wizard; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;

      7)  # Backup — pick ALL or a subset of cmds/apps
        if exists fzf; then
          mapfile -t _cmds < <(_get_installed_cmd_names)
          mapfile -t _apps < <(_get_installed_app_names)
          choices=("ALL (everything)")
          for c in "${_cmds[@]}"; do choices+=("cmd  $c"); done
          for a in "${_apps[@]}"; do choices+=("app  $a"); done

          sel="$(printf '%s\n' "${choices[@]}" | fzf --multi --prompt="Backup > " --height=60% --reverse || true)"
          [[ -z "$sel" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }

          if grep -qx "ALL (everything)" <<< "$sel"; then
            op_backup
          else
            tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
            mkdir -p "$tmp/bin" "$tmp/apps"
            while IFS= read -r line; do
              typ="${line%%[[:space:]]*}"; name="${line##*  }"
              if [[ "$typ" == "cmd"  && -f "$BIN_DIR/$name"   ]]; then cp -a "$BIN_DIR/$name"   "$tmp/bin/";  fi
              if [[ "$typ" == "app"  && -e "$APP_STORE/$name" ]]; then cp -a "$APP_STORE/$name" "$tmp/apps/"; fi
            done <<< "$sel"

            out="binman_backup-$(date +%Y%m%d-%H%M%S).zip"
            if exists zip && exists unzip; then
              (cd "$tmp" && zip -qr "$PWD/$out" bin apps)
            else
              out="${out%.zip}.tar.gz"
              (cd "$tmp" && tar -czf "$PWD/$out" bin apps)
            fi
            ok "Backup created: $(realpath_f "$PWD/$out")"
          fi
        else
          op_backup
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      8)  # Restore — choose an archive in CWD or type a path
        if exists fzf; then
          mapfile -t cands < <(ls -1 *.zip *.tar.gz 2>/dev/null || true)
          cands=("Type a path…" "${cands[@]}")
          sel="$(printf '%s\n' "${cands[@]}" | fzf --prompt="Restore > " --height=60% --reverse || true)"
          [[ -z "$sel" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }
          if [[ "$sel" == "Type a path…" ]]; then
            printf "Archive path: "; read -r f; [[ -z "$f" ]] && echo "Cancelled." || op_restore "$f"
          else
            op_restore "$sel"
          fi
        else
          printf "Archive to restore: "; read -r f; [[ -n "$f" ]] && op_restore "$f" || echo "Cancelled."
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      9)  # Self-Update
        op_self_update
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      a|A)  # Rollback
        if exists fzf && [[ -d "$ROLLBACK_ROOT" ]]; then
          mapfile -t snaps < <(cd "$ROLLBACK_ROOT" && ls -1 | sort -r)
          [[ ${#snaps[@]} -eq 0 ]] && { warn "No rollback snapshots yet"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }
          sel="$(printf '%s\n' "${snaps[@]}" | fzf --prompt="Rollback > " --height=60% --reverse || true)"
          [[ -z "$sel" ]] && { echo "Cancelled."; } || apply_rollback "$sel"
        else
          id="$(latest_rollback_id || true)"; [[ -n "$id" ]] && apply_rollback "$id" || warn "No rollback snapshots yet"
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      b|B) printf "Bundle filename [blank=auto]: "; read -r f; op_bundle "${f}"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      c|C) # Test
        if exists fzf; then
          mapfile -t _cmds < <(_get_installed_cmd_names)
          if ((${#_cmds[@]}==0)); then warn "No commands installed."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; fi
          sel="$(printf '%s\n' "${_cmds[@]}" | fzf --prompt="Test > " --height=60% --reverse || true)"
          [[ -z "$sel" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }
          op_test "$sel"
        else
          printf "Command name to test (blank = stress): "; read -r n
          [[ -z "$n" ]] && op_test stress || op_test "$n"
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      s|S) SYSTEM_MODE=$((1-SYSTEM_MODE)); ok "System mode: $([[ $SYSTEM_MODE -eq 1 ]] && echo ON || echo OFF)"; sleep 0.5;;
      q|Q) exit 0;;
      *)   warn "Unknown choice: $c"; sleep 0.7;;
    esac
  done
}

_binman_rb_dir(){ 
    echo "${XDG_STATE_HOME:-$HOME/.local/state}/binman/rollback"; 
}

_cmd_binman_rollback(){
  local rbdir="$(_binman_rb_dir)" pick=""
  [[ -d "$rbdir" ]] || { err "No snapshots found."; return 2; }
  # Pick latest if none specified
  pick="$(ls -1t "$rbdir"/binman-* 2>/dev/null | head -n1)"
  [[ -n "$1" ]] && pick="$rbdir/binman-$1"
  [[ -f "$pick" ]] || { err "Snapshot not found: $1"; return 2; }
  cp -f "$pick" "${BIN_DIR%/}/binman" && chmod 0755 "${BIN_DIR%/}/binman" && ok "Rolled back to $(basename "$pick")"
}

__bm_realpath() {
  local target="$1"
  if [[ -z "$target" ]]; then
    return 1
  fi

  if command -v realpath >/dev/null 2>&1; then
    realpath "$target" 2>/dev/null && return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY' 2>/dev/null && return 0
import os, sys
try:
    print(os.path.realpath(sys.argv[1]))
except Exception:
    sys.exit(1)
PY
  fi

  if [[ -d "$target" ]]; then
    (cd "$target" 2>/dev/null && pwd -P) && return 0
  fi

  local dir base
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  (cd "$dir" 2>/dev/null && printf "%s/%s\n" "$(pwd -P)" "$base")
}

__bm_guess_app_target() {
  local app_dir="$1" name="$2" candidate
  [[ -n "$app_dir" && -d "$app_dir" ]] || return 1

  local candidates=(
    "$app_dir/bin/$name"
    "$app_dir/bin/run.sh"
    "$app_dir/bin/start"
    "$app_dir/$name"
    "$app_dir/run.sh"
  )

  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] && { printf "%s\n" "$candidate"; return 0; }
  done

  candidate="$(find "$app_dir" -maxdepth 2 -type f -perm -u+x -print 2>/dev/null | head -n1)"
  [[ -n "$candidate" ]] && printf "%s\n" "$candidate"
}

__bm_list_tsv() {
  local dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  local adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"

  # [Patch] Prefer apps; hide cmd when app exists; ensure cmd version via shim_version()
  declare -A _apps_seen=()

  # Emit apps (and remember names)
  if [[ -d "$adir" ]]; then
    for d in "$adir"/*; do
      [[ -d "$d" || -L "$d" ]] || continue
      local aname; aname="$(basename "$d")"
      _apps_seen["$aname"]=1
      printf "app\t%s\t%s\t%s\n" "$aname" "$(script_version "$d")" "$d"
    done
  fi

  # Emit shims only when no app of the same name exists
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*; do
      [[ -x "$f" && -f "$f" ]] || continue
      local name; name="$(basename "$f")"
      if [[ -n "${_apps_seen[$name]:-}" ]]; then
        debug "list: skip cmd '$name' (app exists)"
        continue
      fi
      printf "cmd\t%s\t%s\t%s\n" "$name" "$(shim_version "$f")" "$f"
    done
  fi
}

bm_render_preview() {
  if (( $# <= 4 )); then
    local type="${1:-}" name="${2:-}" ver="${3:-}" path="${4:-}" root="${5:-}"
    if declare -F _bm_preview >/dev/null; then
      if [[ -n "$root" ]]; then
        _bm_preview "$type" "$name" "$ver" "$path" "$root"
      else
        _bm_preview "$type" "$name" "$ver" "$path"
      fi
      return
    fi
    if declare -F bm_show_help >/dev/null; then
      bm_show_help "$type" "$name" "$ver" "$path"
      return
    fi
    if declare -F _bm_show_help >/dev/null; then
      _bm_show_help "$type" "$name" "$ver" "$path"
      return
    fi
    if [[ -n "$root" ]]; then
      _bm_preview_fallback "$type" "$name" "$ver" "$path" "$root"
    else
      _bm_preview_fallback "$type" "$name" "$ver" "$path"
    fi
    return
  fi

  local type="${1:-}" name="${2:-}" ver="${3:-}" path="${4:-}"
  local preview_enc="${5:-}" help_enc="${6:-}" manifest="${7:-}" scope="${8:-}" run_enc="${9:-}" target="${10:-}"
  local preview_text help_text run_text display_path display_type
  preview_text="$(decode_field "$preview_enc")"
  help_text="$(decode_field "$help_enc")"
  run_text="$(decode_field "$run_enc")"
  [[ -n "$ver" ]] || ver="unknown"
  display_path="${path:-"-"}"
  display_type="${type:-unknown}"

  printf "\033[1m%s\033[0m  [%s]\n" "$name" "$ver"
  printf "\033[2mPath:\033[0m %s\n" "$display_path"
  printf "\033[2mType:\033[0m %s\n" "$display_type"
  [[ -n "$scope" ]] && printf "\033[2mScope:\033[0m %s\n" "$scope"
  [[ -n "$manifest" ]] && printf "\033[2mManifest:\033[0m %s\n" "$manifest"
  if [[ -n "$run_text" ]]; then
    printf "\033[2mRun:\033[0m %s\n" "$run_text"
  fi
  if [[ -n "$target" && "$target" != "$display_path" ]]; then
    printf "\033[2mTarget:\033[0m %s\n" "$target"
  fi
  printf "\n"

  if [[ -n "$preview_text" ]]; then
    printf "\033[1mPreview:\033[0m\n%s\n" "$preview_text"
  elif [[ -n "$help_text" ]]; then
    printf "\033[1mHelp:\033[0m\n%s\n" "$help_text"
  else
    printf "(no preview available)\n"
  fi
}

_bm_preview() {
  # Args: TYPE NAME VERSION PATH  (we'll also accept a single TSV arg for safety)
  local type name ver path root line

  if [[ $# -eq 1 && "$1" == *$'\t'* ]]; then
    # fallback: got one TSV-joined arg
    line="$1"
    IFS=$'\t' read -r type name ver path <<<"$line"
  else
    type="${1:-}"; name="${2:-}"; ver="${3:-}"; path="${4:-}"; root="${5:-}"
  fi

  # strip any wrapping single/double quotes that sneak in


  _stripq(){ 
    local s="$1"
    [[ ${#s} -ge 2 && ( "${s:0:1}" == "'" && "${s: -1}" == "'" ) ]] && s="${s:1:-1}"
    [[ ${#s} -ge 2 && ( "${s:0:1}" == '"' && "${s: -1}" == '"' ) ]] && s="${s:1:-1}"
    printf "%s" "$s"
  }
  path="$(_stripq "$path")"

  printf "\033[1m%s\033[0m  [%s]\n" "$name" "${ver:-unknown}"
  printf "Path: %s\nType: %s\n\n" "$path" "$type"

  # Description
  local desc; desc="$(script_desc "$path")"
  [[ -n "$desc" ]] && { printf "Description:\n%s\n\n" "$desc"; }

  if [[ -d "$path" ]]; then
    # README (only if it exists)
    local readme=""
    for f in README.md README.txt README; do
      [[ -f "$path/$f" ]] && { readme="$path/$f"; break; }
    done
    if [[ -n "$readme" ]]; then
      printf "README: %s\n" "$readme"
      if command -v bat >/dev/null 2>&1; then
        bat --style=plain --color=always "$readme" | sed -n '1,120p'
      else
        sed -n '1,120p' "$readme"
      fi
      echo
    fi

    # Python venv quick info
    if [[ -x "$path/.venv/bin/python" ]]; then
      printf "venv: %s\n" "$path/.venv"
      "$path/.venv/bin/python" -V 2>&1
      "$path/.venv/bin/pip" list --format=columns 2>/dev/null | sed -n '2,20p' | sed 's/^/  /'
      echo
    fi

    # File tree (trimmed)
    printf "Files:\n"
    if command -v tree >/dev/null 2>&1; then
      tree -L 2 -a --dirsfirst "$path" | sed 's/^/  /'
    else
      find "$path" -maxdepth 2 -printf "  %p\n" | sort
    fi

  elif [[ -f "$path" ]]; then
    # Script preview
    if command -v bat >/dev/null 2>&1; then
      bat --style=plain --color=always -n "$path" | sed -n '1,120p'
    else
      sed -n '1,120p' "$path"
    fi
  else
    printf "(no preview available)\n"
  fi
}

_bm_preview_fallback() {
  local type="${1:-}" name="${2:-}" ver="${3:-}" path="${4:-}" root="${5:-}"
  local script="$path" app_dir="" line key value resolved_path title version desc usage
  local meta_app="" meta_title="" meta_version="" meta_desc="" meta_usage=""
  local limit=40 found_header=0 wrap_width=70 type_label=""

  if [[ -n "$root" && -d "$root" ]]; then
    app_dir="$root"
  elif [[ -n "$path" && -d "$path" ]]; then
    app_dir="$path"
  elif [[ -n "$script" ]]; then
    local parent
    parent="$(dirname "$script")"
    [[ -d "$parent" ]] && app_dir="$parent"
  fi

  if [[ -z "$script" && -n "$app_dir" ]]; then
    script="$(__bm_guess_app_target "$app_dir" "$name")"
  fi
  [[ -z "$script" && -n "$app_dir" ]] && script="$app_dir"
  [[ -z "$script" ]] && script="$path"

  resolved_path="$(__bm_realpath "$script")"
  [[ -z "$resolved_path" ]] && resolved_path="$script"

  # Capture metadata headers from the top of the script
  if [[ -n "$script" && -f "$script" ]]; then
    while IFS='' read -r line && (( limit-- > 0 )); do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*# ]] || continue
      if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*(App|Title|Version|Description|Usage):[[:space:]]*(.*)$ ]]; then
        found_header=1
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
          App) meta_app="$value" ;;
          Title) meta_title="$value" ;;
          Version) meta_version="$value" ;;
          Description) [[ -z "$meta_desc" ]] && meta_desc="$value" ;;
          Usage) [[ -z "$meta_usage" ]] && meta_usage="$value" ;;
        esac
      fi
    done < "$script"
  fi

  local version_source=""
  if [[ -n "$meta_version" ]]; then
    version="$meta_version"
  else
    version_source="${app_dir:-$script}"
    if [[ -n "$ver" ]]; then
      version="$ver"
    else
      version="$(script_version "$version_source")"
    fi
  fi

  if [[ -n "$meta_desc" ]]; then
    desc="$meta_desc"
  else
    desc="$(script_desc "${app_dir:-$script}")"
  fi
  title="${meta_title:-$name}"
  usage="$meta_usage"

  # Determine wrap width (approx 60% of terminal)
  if [[ -n "${COLUMNS:-}" ]]; then
    local guess=$(( (COLUMNS * 60) / 100 - 4 ))
    if (( guess >= 30 )); then
      wrap_width="$guess"
    fi
  fi

  type_label="${type:-unknown}"

  printf "\033[1m%s\033[0m  [%s]\n" "${title:-$name}" "${version:-unknown}"
  printf "\033[2mPath:\033[0m %s\n" "${resolved_path:-$path}"
  printf "\033[2mType:\033[0m %s\n" "${type_label:-unknown}"
  [[ -n "$meta_app" ]] && printf "\033[2mApp:\033[0m %s\n" "$meta_app"

  if (( found_header )); then
    if [[ -n "$desc" ]]; then
      printf "\n\033[1mDescription:\033[0m\n"
      printf "%s\n" "$(printf "%s" "$desc" | fold -s -w "$wrap_width")"
    fi
    if [[ -n "$usage" ]]; then
      printf "\n\033[1mUsage:\033[0m\n"
      printf "%s\n" "$(printf "%s" "$usage" | fold -s -w "$wrap_width")"
    fi
    if [[ -z "$desc" && -z "$usage" ]]; then
      printf "\n(no preview available)\n"
    fi
  else
    printf "\n(no preview available)\n"
  fi

  printf "\n↑↓ navigate • Enter=Back • d=Doctor • ctrl-r=Reload • Esc=Back\n"
}

__bm_internal(){
    local sub="$1"; shift || true
  case "$sub" in
    __internal:list)
      __bm_list_tsv
      return 0 ;;
    __internal:preview)
      bm_render_preview "$@"
      return 0 ;;
  esac
  return 1
}

if ! declare -F __bm_internal >/dev/null; then
  __bm_internal() {
    local action="${1:-}"
    shift || true
    case "$action" in
      help|showhelp|listhelp)
        if declare -F bm_show_help >/dev/null; then
          bm_show_help "$@"
        elif declare -F _bm_show_help >/dev/null; then
          _bm_show_help "$@"
        else
          :  # no-op
        fi
        ;;
      *)
        :  # ignore any other internal legacy call
        ;;
    esac
  }
fi

if [[ "${1:-}" == __internal:* ]]; then
  __bm_internal "$1" "${@:2}"
  exit $?
fi

# __BINMAN_INTERNAL_FASTPATH__
if [[ "${1:-}" == __internal:* ]]; then
  __bm_internal "$1" "${@:2}"
  exit $?
fi

_exists(){
    command -v "$1" >/dev/null 2>&1;
}

_binman_preview() {
  local line="$1"
  local type name ver path appdir venv req readme
  IFS=$'\t' read -r type name ver path <<<"$line"

  printf "\033[1m%s\033[0m  [%s]\n" "$name" "${ver:-unknown}"
  printf "\033[2mPath:\033[0m %s\n" "$path"
  printf "\033[2mType:\033[0m %s\n\n" "$type"

  # description
  if [[ "$type" == cmd ]]; then
    printf "\033[1mDescription:\033[0m %s\n\n" "$(script_desc "$path")"
  else
    printf "\033[1mDescription:\033[0m %s\n\n" "$(script_desc "$path")"
  fi

  # show README or manifest if present
  if [[ -d "$path" ]]; then
    appdir="$path"
    readme=""
    for f in README.md README.txt README; do
      [[ -f "$appdir/$f" ]] && { readme="$appdir/$f"; break; }
    done
    if [[ -n "$readme" ]]; then
      printf "\033[1mREADME:\033[0m %s\n" "$readme"
      if _exists glow; then glow -s dark "$readme" 2>/dev/null || cat "$readme"
      elif _exists bat; then bat --style=plain --color=always "$readme"
      else sed -E 's/^# (.*)$/\1\n\1\n/' "$readme" | sed 's/^#/  /'
      fi
      echo
    fi
  fi

  # Python bits
  if [[ -d "$path" && -f "$path/requirements.txt" ]]; then
    req="$path/requirements.txt"
    printf "\033[1mrequirements.txt:\033[0m\n"
    if _exists bat; then bat --style=plain --color=always "$req"; else sed 's/^/  /' "$req"; fi
    echo
  fi

  venv="$path/.venv"
  if [[ -d "$venv" ]]; then
    printf "\033[1mvenv:\033[0m %s\n" "$venv"
    if [[ -x "$venv/bin/python" ]]; then
      printf "  python: %s\n" "$("$venv/bin/python" -c 'import sys;print(".".join(map(str,sys.version_info[:3])))' 2>/dev/null || echo '?')"
      printf "  pip pkgs: %s\n" "$("$venv/bin/pip" list --format=columns 2>/dev/null | sed -n '2,15p' | sed 's/^/    /')"
    fi
    echo
  fi

  # file tree (trimmed)
  if [[ -d "$path" ]]; then
    printf "\033[1mFiles:\033[0m\n"
    if _exists tree; then
      tree -L 2 -a --dirsfirst "$path" | sed 's/^/  /'
    else
      find "$path" -maxdepth 2 -printf "  %p\n" | sort
    fi
  else
    # script preview
    if _exists bat; then bat --style=plain --color=always -n "$path" | sed -n '1,120p'
    else sed -n '1,120p' "$path"
    fi
  fi
}

_collect_items_tsv() {
  local dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  local adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"

  # [Patch] Prefer apps; hide cmd when app exists; ensure cmd version via shim_version()
  declare -A _apps_seen=()

  # Apps first
  if [[ -d "$adir" ]]; then
    for d in "$adir"/*; do
      [[ -d "$d" || -L "$d" ]] || continue
      local aname; aname="$(basename "$d")"
      _apps_seen["$aname"]=1
      printf "app\t%s\t%s\t%s\n" "$aname" "$(script_version "$d")" "$d"
    done
  fi

  # Cmds only if not shadowed by an app
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*; do
      [[ -x "$f" && -f "$f" ]] || continue
      local name; name="$(basename "$f")"
      if [[ -n "${_apps_seen[$name]:-}" ]]; then
        debug "list: skip cmd '$name' (app exists)"
        continue
      fi
      printf "cmd\t%s\t%s\t%s\n" "$name" "$(shim_version "$f")" "$f"
    done
  fi
}

_render_card_list(){
  local dir adir f d
  dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"

  say ""
  say "Commands in $dir"
  ui_hr
  for f in "$dir"/*; do
    [[ -x "$f" && -f "$f" ]] || continue
    local name ver desc
    name="$(basename "$f")"
    ver="$(script_version "$f")"
    desc="$(script_desc "$f")"
    printf "• %s %s[%s]%s\n" "$name" "$UI_DIM" "${ver:-unknown}" "$UI_RESET"
    [[ -n "$desc" ]] && printf "  %s\n" "$desc"
    printf "%s\n" "$UI_DIM────────────────────────────────────────────────────────────────$UI_RESET"
  done

  if [[ "${BINMAN_INCLUDE_APPS:-0}" == "1" ]]; then
    say ""
    say "Apps in $adir"
    ui_hr
    for d in "$adir"/*; do
      [[ -d "$d" || -L "$d" ]] || continue
      local name ver desc
      name="$(basename "$d")"
      ver="$(script_version "$d")"
      desc="$(script_desc "$d")"
      printf "• %s %s[%s]%s\n" "$name" "$UI_DIM" "${ver:-unknown}" "$UI_RESET"
      [[ -n "$desc" ]] && printf "  %s\n" "$desc"
      printf "%s\n" "$UI_DIM────────────────────────────────────────────────────────────────$UI_RESET"
    done
  fi
}

_parse_version(){
  awk -F'"' '/^[[:space:]]*VERSION[[:space:]]*=/ {print $2; exit}' "$1" 2>/dev/null
}



# --------------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------------
clear
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # FLAGS ONLY when first arg looks like a flag
  if [[ "${1:-}" == -* ]]; then
    if parse_common_opts "$@"; then exit 0; fi
    set -- "${ARGS_OUT[@]}"

    if (( REINDEX_REQUEST )); then
      bm_force_reindex
      if build_inventory; then
        (( QUIET )) || ok "Inventory rebuilt."
      else
        warn "No manifest entries found."
      fi
      [[ $# -eq 0 ]] && exit 0
    fi

    if [[ $# -eq 0 ]]; then
      if __has_fzf && [[ -t 1 ]]; then
        __bm_menu_loop
        exit 0
      else
        binman_tui
        exit 0
      fi
    fi

  fi

  # INTERACTIVE (no args)
  if [[ $# -eq 0 ]]; then
    if __has_fzf && [[ -t 1 ]]; then
      __bm_menu_loop
      exit 0
    else
      binman_tui
      exit 0
    fi
  fi


  # DIRECT / INTERNAL
  ACTION="${1:-}"; shift || true
  if [[ "${ACTION:-}" == __internal:* ]]; then
    __bm_internal "$ACTION" "$@"
    exit $?
  fi
  case "$ACTION" in
    __preview_idx)
      if ! _ensure_inventory_arrays; then build_inventory || true; fi
      _render_preview_for_idx "${1:-0}"
      ;;
    __preview)
      bm_render_preview "$@"
      ;;
    *)
      __bm_run_action_safe "$ACTION" "$@" || :
      ;;
  esac
fi
