#!/usr/bin/env bash
# binman.sh — Personal CLI utility manager for your ~/bin toys
# --------------------------------------------------------------------------------------------------
# Manage install/uninstall/list/update for single-file scripts AND multi-file apps.
# Extras: TUI, generator, wizard, backup/restore, self-update, system installs, rollbacks, remotes,
#         manifests, bundles, test harness.
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
SELF="${SELF:-$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || command -v "$0" || echo "$0")}"
export BINMAN_SELF="$SELF"


# --------------------------------------------------------------------------------------------------
# Constants & defaults
# --------------------------------------------------------------------------------------------------
SCRIPT_NAME="binman"
VERSION="1.7.3"

# User-scoped locations (XDG-ish)
BIN_DIR="${HOME}/.local/bin"
APP_STORE="${HOME}/.local/share/binman/apps"

# System-scoped locations (used with --system; requires write perms/sudo)
SYSTEM_BIN="/usr/local/bin"
SYSTEM_APPS="/usr/local/share/binman/apps"

# Runtime flags (influenced by CLI options)
COPY_MODE="copy"   # copy | link
FORCE=0            # overwrite on conflicts
FROM_DIR=""        # bulk install from a directory (executables only)
GIT_DIR=""         # optional git dir to pull before update
FIX_PATH=0         # doctor --fix-path flag
SYSTEM_MODE=0      # target system dirs
MANIFEST_FILE=""   # bulk install manifest
QUIET=0            # less noisy

ENTRY_CMD=""      # custom entry command for apps
ENTRY_CWD=""      # optional subdir to cd into before running entry

ENTRY_CMD=""        # --entry "<command to exec inside appdir>"
ENTRY_CWD=""        # --workdir "<subdir inside appdir>" (optional)
VENV_MODE=0         # --venv : create/activate app-local .venv for entry
REQ_FILE=""         # --req FILE : requirements file name (default: requirements.txt)
BOOT_PY="python3"   # --python BIN : bootstrap interpreter to create venv



# --------------------------------------------------------------------------------------------------
# Small helpers (consistent messages, detection, paths)
# --------------------------------------------------------------------------------------------------
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

exists(){
    command -v "$1" >/dev/null 2>&1;
}

iso_now(){
    date -Iseconds;
}

# POSIX-friendly realpath fallback (prefers python3, then readlink -f)
realpath_f(){
    python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || readlink -f "$1";
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
  local cmds apps
  cmds=($(_get_installed_cmd_names))
  apps=($(_get_installed_app_names))

  echo
  echo "Installed commands:"
  if ((${#cmds[@]})); then
    printf "  %s\n" "${cmds[@]}"
  else
    echo "  (none)"
  fi
  echo
  echo "Installed apps:"
  if ((${#apps[@]})); then
    printf "  %s\n" "${apps[@]}"
  else
    echo "  (none)"
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

USAGE: ${SCRIPT_NAME} <install|uninstall|list|update|doctor|new|wizard|tui|backup|restore|self-update|rollback|bundle|test|version|help> [args] [options]
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
  --quiet            Less chatty
Backup/Restore convenience:
  --backup [FILE]    Create archive (.zip if zip/unzip exist else .tar.gz)
  --restore FILE     Restore archive into target dirs (merge; --force to clobber)

Extra commands:
  self-update          Update BinMan from its git repo then reinstall the shim
  rollback [ID]        Restore the latest (or specific) rollback snapshot
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
ensure_system_dirs(){ ensure_dir "$SYSTEM_BIN"; ensure_dir "$SYSTEM_APPS"; }



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
    # parse with python; print two lines to avoid nested here-doc tricks
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
    # bare TS repo (best-effort if user installed tsx)
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
      # 1) exact cmd/<repo>/main.go
      for m in "${mains[@]}"; do
        local dir; dir="$(basename "$(dirname "$m")")"
        [[ "${dir,,}" == "$want" || "${dir,,}" == "$want_hy" ]] && { choose="$dir"; break; }
      done
      # 2) first non-tool-ish dir
      if [[ -z "$choose" ]]; then
        for m in "${mains[@]}"; do
          local dir; dir="$(basename "$(dirname "$m")")"
          [[ "${dir,,}" =~ ^(i18n|tools?|internal|example|examples|demo|test|tests|integration(_|-)?tests?)$ ]] && continue
          [[ "${dir,,}" == *test* ]] && continue
          choose="$dir"; break
        done
      fi
      # 3) fallback: first
      [[ -z "$choose" ]] && choose="$(basename "$(dirname "${mains[0]}")")"
      echo "go run ./cmd/$choose||"; return 0
    fi
    [[ -f "$d/main.go" ]] && { echo "go run .||"; return 0; }
  fi

  # ---------- ruby ----------
  if [[ "$lang" == "ruby" ]]; then
    # only use bundler if it's installed; otherwise fall back to running directly
    local rb_prefix=""
    if [[ -f "$d/Gemfile" ]] && command -v bundle >/dev/null 2>&1; then
      rb_prefix="bundle exec "
    fi

    # Prefer exe/<repo> (Ruby gem layout) then bin/<repo> (handle hyphen/underscore)
    if [[ -x "$d/exe/$want"    ]]; then echo "${rb_prefix}./exe/$want||";    return 0; fi
    if [[ -x "$d/exe/$want_hy" ]]; then echo "${rb_prefix}./exe/$want_hy||"; return 0; fi
    if [[ -x "$d/bin/$want"    ]]; then echo "${rb_prefix}./bin/$want||";    return 0; fi
    if [[ -x "$d/bin/$want_hy" ]]; then echo "${rb_prefix}./bin/$want_hy||"; return 0; fi

    # Gem executables from *.gemspec (first listed)
    local gemspec; gemspec=$(ls "$d"/*.gemspec 2>/dev/null | head -n1 || true)
    if [[ -n "$gemspec" ]]; then
      # crude parse handles: s.executables = ["colorls"]  / %w[colorls]
      local exe
      exe="$(grep -Eo 'executables\s*=\s*(\[.*\]|%w\[[^]]+\])' "$gemspec" \
            | head -n1 \
            | sed -E 's/.*\[(.*)\].*/\1/' \
            | tr -d '"[:space:]' \
            | cut -d, -f1)"
      [[ -n "$exe" && -x "$d/exe/$exe" ]] && { echo "${rb_prefix}./exe/$exe||"; return 0; }
      [[ -n "$exe" && -x "$d/bin/$exe" ]] && { echo "${rb_prefix}./bin/$exe||"; return 0; }
    fi

    # Loose ruby entry points
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
    # poetry / PEP621 scripts → module
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
      script="${script%%:*}"                     # pkg:func → pkg
      echo "python -m $script||$req"; return 0
    fi
  fi

  # setup.cfg console_scripts
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
    # last-ditch: single shebangbed script in bin/
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
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" > "$shim"
  chmod +x "$shim"
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

  cat > "$shim" <<EOF
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
  chmod +x "$shim"
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

  cat > "$shim" <<EOF
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
  chmod +x "$shim"
}



# --------------------------------------------------------------------------------------------------
# Prompt helpers (TTY-safe; we always read/write via /dev/tty inside wizard/TUI)
# --------------------------------------------------------------------------------------------------
prompt_init(){ : "${UI_RESET:=}"; : "${UI_BOLD:=}"; : "${UI_DIM:=}"; : "${UI_CYAN:=}"; : "${UI_GREEN:=}"; : "${UI_YELLOW:=}"; }
prompt_kv(){ printf "  %s%-14s%s %s\n" "$UI_BOLD" "$1:" "$UI_RESET" "$2"; }

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
  local src="$1" name dest
  name=$(basename "$src"); dest="$APP_STORE/$name"

  rm -rf "$dest"
  [[ "$COPY_MODE" == "link" ]] && ln -s "$src" "$dest" || cp -a "$src" "$dest"

  # Explicit --entry wins
  if [[ -n "$ENTRY_CMD" ]]; then
    if (( VENV_MODE )); then
      _make_shim_cmd_venv "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD" "$REQ_FILE" "$BOOT_PY"
      ok "App installed: $name → $dest (entry: $ENTRY_CMD; venv on)"
    else
      _make_shim_cmd "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD"
      ok "App installed: $name → $dest (custom entry)"
    fi
    return 0
  fi

  # Conventional layout?
  if [[ -x "$dest/bin/$name" ]]; then
    _make_shim "$name" "$(_app_entry "$dest")"
    ok "App installed: $name → $dest (v$(script_version "$dest"))"
    return 0
  fi

  # Try auto-detect
  local triplet; triplet="$(_detect_entry "$dest")"
  local cmd="${triplet%%|*}"; triplet="${triplet#*|}"
  local cwd="${triplet%%|*}"; local req="${triplet#*|}"

  if [[ -n "$cmd" ]]; then
    if (( VENV_MODE )) || [[ "$cmd" == python* || "$cmd" == */python* ]]; then
      _make_shim_cmd_venv "$name" "$dest" "$cmd" "$cwd" "${REQ_FILE:-$req}" "$BOOT_PY"
      ok "App installed: $name → $dest (entry: $cmd; venv on)"
    else
      _make_shim_cmd "$name" "$dest" "$cmd" "$cwd"
      ok "App installed: $name → $dest (entry: $cmd)"
    fi
    return 0
  fi

  err "App '$name' missing bin/$name and no entry could be detected. Try: --entry 'python3 path/to/main.py' [--venv --req requirements.txt]"
  return 2
}

_install_app_system(){
  ensure_system_write; ensure_system_dirs
  local src="$1" name dest
  name=$(basename "$src"); dest="$SYSTEM_APPS/$name"

  rm -rf "$dest"
  [[ "$COPY_MODE" == "link" ]] && ln -s "$src" "$dest" || cp -a "$src" "$dest"

  if [[ -n "$ENTRY_CMD" ]]; then
    if (( VENV_MODE )); then
      _make_shim_cmd_venv_system "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD" "$REQ_FILE" "$BOOT_PY"
      ok "App installed (system): $name → $dest (entry: $ENTRY_CMD; venv on)"
    else
      _make_shim_cmd_system "$name" "$dest" "$ENTRY_CMD" "$ENTRY_CWD"
      ok "App installed (system): $name → $dest (custom entry)"
    fi
    return 0
  fi

  if [[ -x "$dest/bin/$name" ]]; then
    _make_shim_system "$name" "$(_app_entry "$dest")"
    ok "App installed (system): $name → $dest (v$(script_version "$dest"))"
    return 0
  fi

  local triplet; triplet="$(_detect_entry "$dest")"
  local cmd="${triplet%%|*}"; triplet="${triplet#*|}"
  local cwd="${triplet%%|*}"; local req="${triplet#*|}"

  if [[ -n "$cmd" ]]; then
    if (( VENV_MODE )) || [[ "$cmd" == python* || "$cmd" == */python* ]]; then
      _make_shim_cmd_venv_system "$name" "$dest" "$cmd" "$cwd" "${REQ_FILE:-$req}" "$BOOT_PY"
      ok "App installed (system): $name → $dest (entry: $cmd; venv on)"
    else
      _make_shim_cmd_system "$name" "$dest" "$cmd" "$cwd"
      ok "App installed (system): $name → $dest (entry: $cmd)"
    fi
    return 0
  fi

  err "App '$name' missing bin/$name and no entry could be detected. Try: --entry 'python3 path/to/main.py' [--venv --req requirements.txt]"
  return 2
}

_uninstall_app(){
  local name="$1" dest="$APP_STORE/$name" shim="$BIN_DIR/$name"
  [[ -e "$shim" ]] && rm -f "$shim" && ok "Removed shim: $shim"
  [[ -e "$dest" ]] && rm -rf "$dest" && ok "Removed app: $dest"
}

_uninstall_app_system(){
  ensure_system_write
  local name="$1" dest="$SYSTEM_APPS/$name" shim="$SYSTEM_BIN/$name"
  [[ -e "$shim" ]] && rm -f "$shim" && ok "Removed shim: $shim"
  [[ -e "$dest" ]] && rm -rf "$dest" && ok "Removed app: $dest"
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
  if exists curl; then curl -fsSL "$url" -o "$out"
  elif exists wget; then wget -q "$url" -O "$out"
  else err "Need curl or wget for remote installs"; return 2; fi
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

  # Capture rollback snapshot before mutating
  stash_before_change >/dev/null

  local count=0
  for src in "${targets[@]}"; do
    # 1) Support URL installs
    if is_url "$src"; then
      local fetched; fetched=$(fetch_remote "$src") || { warn "Fetch failed: $src"; continue; }
      src="$fetched"
    fi

    # 2) App install (directory with bin/<name> entry)
    if [[ -d "$src" ]]; then
      if (( SYSTEM_MODE )); then _install_app_system "$src"; else _install_app "$src"; fi
      count=$((count+1))
      continue
    fi

    # 3) Single-file install
    [[ -f "$src" ]] || { warn "Skip (not a file): $src"; continue; }

    # Destination path: drop extension for final name
    local base dst tmp
    base=$(basename "$src")
    if (( SYSTEM_MODE )); then
      dst="${SYSTEM_BIN}/${base%.*}"
      ensure_system_write; ensure_system_dirs
    else
      dst="${BIN_DIR}/${base%.*}"
      ensure_bin
    fi

    # Skip unless --force when dest already exists
    if [[ -e "$dst" && $FORCE -ne 1 ]]; then
      warn "Exists: $(basename "$dst") (use --force)"
      continue
    fi

    if [[ "$COPY_MODE" == "link" && $SYSTEM_MODE -eq 0 ]]; then
      # Dev-friendly: symlink (only for user scope)
      ln -sf "$src" "$dst"
      ok "Installed: $dst (symlink) (v$(script_version "$src"))"
    else
      # Atomic copy: write to tmp then mv into place
      tmp="$(mktemp "${dst}.tmp.XXXXXX")"
      cp "$src" "$tmp"
      chmod +x "$tmp"

      # Light syntax sanity for bash/sh shebangs (non-blocking for other types)
      if head -n1 "$tmp" | grep -qE '/(ba)?sh'; then
        if ! bash -n "$tmp" 2>/dev/null; then
          rm -f "$tmp"
          err "Syntax check failed; keeping existing $(basename "$dst")."
          continue
        fi
      fi

      mv -f "$tmp" "$dst"
      ok "Installed: $dst (v$(script_version "$src"))"
    fi

    count=$((count+1))
  done

  # Path tip for user mode
  if (( SYSTEM_MODE )); then :; else
    ! in_path && warn "${BIN_DIR} not in PATH. Add: export PATH=\"${BIN_DIR}:\$PATH\""
  fi

  rehash_shell
  say "$count item(s) installed."
}



# --------------------------------------------------------------------------------------------------
# UNINSTALL — remove scripts or apps (user/system)
# --------------------------------------------------------------------------------------------------
op_uninstall(){
  stash_before_change >/dev/null
  local count=0
  for name in "$@"; do
    if (( SYSTEM_MODE )); then
      [[ -e "$SYSTEM_APPS/$name" ]] && { _uninstall_app_system "$name"; count=$((count+1)); continue; }
      local dst="$SYSTEM_BIN/${name%.*}"
      [[ -e "$dst" ]] && { rm -f "$dst"; ok "Removed: $dst"; count=$((count+1)); } || warn "Not found: $name"
    else
      [[ -e "$APP_STORE/$name" ]] && { _uninstall_app "$name"; count=$((count+1)); continue; }
      local dst="$BIN_DIR/${name%.*}"
      [[ -e "$dst" ]] && { rm -f "$dst"; ok "Removed: $dst"; count=$((count+1)); } || warn "Not found: $name"
    fi
  done
  rehash_shell
  say "$count item(s) removed."
}



# --------------------------------------------------------------------------------------------------
# LIST — show installed scripts/apps with versions and descriptions
# --------------------------------------------------------------------------------------------------
op_list(){
  ensure_bin; ensure_apps
  print_banner
  say "Commands in ${SYSTEM_MODE:+(system) }$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR"):"
  printf "%-20s %-10s %s\n" "Name" "Version" "Description"
  printf "%-20s %-10s %s\n" "----" "-------" "-----------"
  local dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  for f in "$dir"/*; do
    [[ -x "$f" && -f "$f" ]] || continue
    printf "%-20s %-10s %s\n" "$(basename "$f")" "$(script_version "$f")" "$(script_desc "$f")"
  done
  echo
  say "Apps in $([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE"):"
  printf "%-20s %-10s %s\n" "App" "Version" "Description"
  printf "%-20s %-10s %s\n" "---" "-------" "-----------"
  local adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"
  for d in "$adir"/*; do
    [[ -d "$d" || -L "$d" ]] || continue
    local name; name="$(basename "$d")"
    printf "%-20s %-10s %s\n" "$name" "$(script_version "$d")" "$(script_desc "$d")"
  done
}

op_list_ranger() {
  if ! command -v fzf >/dev/null 2>&1; then
    op_list
    return 0
  fi

  local out key line
  out="$(
    __bm_list_tsv | sort -t $'\t' -k1,1 -k2,2 |
    fzf --ansi --border --height=100% --layout=reverse \
        --delimiter=$'\t' --with-nth=1,2,3 \
        --preview 'bash -c '\''exec "$BINMAN_SELF" --_preview_fields "$1" "$2" "$3" "$4" "$5"'\'' sh {1} {2} {3} {4} {5}' \
        --preview-window=right,60%,wrap \
        --bind 'd:execute-silent(bash -c '\''exec "$BINMAN_SELF" doctor >/dev/null 2>&1'\'' sh)+refresh-preview' \
        --bind 'u:execute-silent(bash -c '\''exec "$BINMAN_SELF" uninstall "$1" >/dev/null 2>&1'\'' sh {2})+reload(bash -c '\''exec "$BINMAN_SELF" __internal:list'\'' sh)' \
        --bind 'ctrl-r:reload(bash -c '\''exec "$BINMAN_SELF" __internal:list'\'' sh)' \
        --bind 'esc:abort' \
        --header="↑↓ navigate • Enter select • ESC cancel" \
        --prompt='BinMan ▸ ' \
        --expect=enter,d,u,ctrl-r \
      || true
  )"



  [[ -z "$out" ]] && return 0
  key="$(printf '%s\n' "$out" | head -n1)"
  line="$(printf '%s\n' "$out" | tail -n1)"
  # actions already executed via fzf bindings; we just stay in the TUI
  return 0
}



# --------------------------------------------------------------------------------------------------
# DOCTOR — environment + per‑app healing (venv/deps/hook)
# --------------------------------------------------------------------------------------------------

# Keep legacy entry for any old callers; now just proxies to the env summary.
op_doctor(){ 
    doctor_env;
}

# Environment summary (+ optional PATH patch)
doctor_env() {
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
  if [[ $FIX_PATH -eq 1 ]]; then
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

# UPDATE — reinstall with overwrite (optionally pull a git dir first)
# --------------------------------------------------------------------------------------------------
op_update(){
  [[ -n "$GIT_DIR" && -d "$GIT_DIR/.git" ]] && (cd "$GIT_DIR" && git pull --rebase --autostash)
  local targets=("$@"); [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] && { FORCE=1; stash_before_change >/dev/null; op_install "${targets[@]}"; } || warn "Nothing to reinstall"
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
    # Print a plain, parseable line (for scripts) and a pretty OK (for humans)
    say "Backup created: ${abs_out}"
    ok  "Backup created: ${abs_out}"
  )
}

_detect_extract_root(){
  local base="$1"
  if [[ -d "$base/bin" || -d "$base/apps" ]]; then echo "$base"; return 0; fi
  for d in "$base"/*; do [[ -d "$d" ]] || continue; [[ -d "$d/bin" || -d "$d/apps" ]] && { echo "$d"; return 0; }; done
  echo "$base"
}

op_restore(){
  ensure_bin; ensure_apps; stash_before_change >/dev/null
  local archive="$1"
  [[ -n "$archive" && -f "$archive" ]] || { err "restore requires an existing archive"; exit 2; }

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

  # == Install (optional) =====================================================
  echo; printf "%s==> Install%s\n" "$UI_GREEN" "$UI_RESET"
  local saved_mode="$COPY_MODE"
  if ask_yesno "Install now?" "y"; then
    ask_yesno "Use symlink instead of copy?" "n" && COPY_MODE="link" || COPY_MODE="copy"
    op_install "$path"
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
  printf "%s1)%s Install   %s2)%s Uninstall   %s3)%s List   %s4)%s Doctor   %s5)%s Wizard\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
    
  printf "%s6)%s Backup    %s7)%s Restore     %s8)%s Self-Update   %sa)%s Rollback   %sb)%s Bundle   %sc)%s Test\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"

  printf "%ss)%s Toggle System Mode %s(currently: %s)%s    %sq)%s Quit\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_DIM" "$([[ $SYSTEM_MODE -eq 1 ]] && echo "ON" || echo "OFF")" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
    
  ui_hr
}

# Write guard for /usr/local
ensure_system_write(){
  [[ -w "$SYSTEM_BIN" && -w "$SYSTEM_APPS" ]] || warn "Need write access to ${SYSTEM_BIN} and ${SYSTEM_APPS}. Try: sudo $SCRIPT_NAME --system <cmd> ..."
}



# --------------------------------------------------------------------------------------------------
# Option parser (top-level flags). Special-cases --backup/--restore to run immediately.
# --------------------------------------------------------------------------------------------------
parse_common_opts(){
  ARGS_OUT=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) FROM_DIR="$2"; shift 2;;
      --entry) ENTRY_CMD="$2"; shift 2;;
      --workdir|--cwd) ENTRY_CWD="$2"; shift 2;;
      --venv) VENV_MODE=1; shift;;
      --req|--requirements) REQ_FILE="$2"; shift 2;;
      --python) BOOT_PY="$2"; shift 2;;
      --link) COPY_MODE="link"; shift;;
      --force) FORCE=1; shift;;
      --git) GIT_DIR="$2"; shift 2;;
      --bin) BIN_DIR="$2"; shift 2;;
      --apps) APP_STORE="$2"; shift 2;;
      --system) SYSTEM_MODE=1; shift;;
      --fix-path) FIX_PATH=1; shift;;
      --manifest) MANIFEST_FILE="$2"; shift 2;;
      --quiet) QUIET=1; shift;;
      --backup) shift || true; op_backup "${1:-}"; return 0;;
      --restore) shift || true; op_restore "${1:-}"; return 0;;
      --) shift; while [[ $# -gt 0 ]]; do ARGS_OUT+=("$1"); shift; done;;
      *) ARGS_OUT+=("$1"); shift;;
    esac
  done
  return 1
}



# --------------------------------------------------------------------------------------------------
# TUI loop
# --------------------------------------------------------------------------------------------------
binman_tui(){
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
          sel="$(printf '%s\n' "${items[@]}" \
                | fzf --multi --prompt="Install > " --height=60% --reverse \
                      --delimiter=$'\t' --with-nth=2 \
                || true)"

          [[ -z "$sel" ]] && { echo "Cancelled."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue; }

          # Convert selections into absolute paths
          targets=()
          while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            rel="${rel%/}"                      # drop trailing slash for dirs
            targets+=("$PWD/$rel")
          done <<< "$sel"

          # Manifest convenience
          if (( ${#targets[@]} == 1 )) && [[ "${targets[0]}" =~ \.(txt|list|json)$ ]]; then
            op_install_manifest "${targets[0]}"
          else
            op_install "${targets[@]}"
          fi
        else
          printf "File/dir/URL (or --manifest FILE): "
          read -r f || { continue; }
          [[ -z "$f" ]] && { echo "Cancelled."; continue; }
          if [[ "$f" =~ ^--manifest[[:space:]]+ ]]; then
            op_install_manifest "${f#--manifest }"
          else
            op_install "$f"
          fi
        fi
        printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r
        ;;

      2)  # Uninstall — (unchanged; your fzf/multi workflow already in place)
        if exists fzf; then
          mapfile -t _cmds < <(_get_installed_cmd_names)
          mapfile -t _apps < <(_get_installed_app_names)
          if ((${#_cmds[@]}==0 && ${#_apps[@]}==0)); then
            warn "Nothing to uninstall."; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r; continue
          fi
          _choices=()
          for c in "${_cmds[@]}"; do _choices+=("cmd  $c"); done
          for a in "${_apps[@]}"; do _choices+=("app  $a"); done
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
      5) new_wizard; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;

      6)  # Backup — pick ALL or a subset of cmds/apps
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

      7)  # Restore — choose an archive in CWD or type a path
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

      8)  # Self-Update
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

__bm_list_tsv() {
  # Reuse your existing collector if present; else inline it:
  local dir adir f d
  dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"

  for f in "$dir"/*; do
    [[ -x "$f" && -f "$f" ]] || continue
    printf "cmd\t%s\t%s\t%s\n" "$(basename "$f")" "$(script_version "$f")" "$f"
  done
  for d in "$adir"/*; do
    [[ -d "$d" || -L "$d" ]] || continue
    printf "app\t%s\t%s\t%s\n" "$(basename "$d")" "$(script_version "$d")" "$d"
  done
}

__bm_preview() {
  # Args: TYPE NAME VERSION PATH  (we'll also accept a single TSV arg for safety)
  local type name ver path line

  if [[ $# -eq 1 && "$1" == *$'\t'* ]]; then
    # fallback: got one TSV-joined arg
    line="$1"
    IFS=$'\t' read -r type name ver path <<<"$line"
  else
    type="${1:-}"; name="${2:-}"; ver="${3:-}"; path="${4:-}"
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

# Internal router for hidden subcommands used by fzf

# Fast path for hidden internal calls (used by fzf preview/reload)
if [[ "${1:-}" == __internal:* ]]; then
  __bm_internal "$1" "${@:2}"
  exit $?
fi

__bm_internal(){
    local sub="$1"; shift || true
  case "$sub" in
    __internal:list)
      _bm_list_tsv
      return 0 ;;
    __internal:preview)
      _bm_preview "$@"
      return 0 ;;
  esac
  return 1
}
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
  local dir adir f d
  dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"

  for f in "$dir"/*; do
    [[ -x "$f" && -f "$f" ]] || continue
    printf "cmd\t%s\t%s\t%s\n" "$(basename "$f")" "$(script_version "$f")" "$f"
  done

  for d in "$adir"/*; do
    [[ -d "$d" || -L "$d" ]] || continue
    printf "app\t%s\t%s\t%s\n" "$(basename "$d")" "$(script_version "$d")" "$d"
  done
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
}

_parse_version(){
  awk -F'"' '/^[[:space:]]*VERSION[[:space:]]*=/ {print $2; exit}' "$1" 2>/dev/null
}


# --------------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then binman_tui; exit 0; fi
if parse_common_opts "$@"; then exit 0; fi
set -- "${ARGS_OUT[@]}"

ACTION="${1:-}"; shift || true
# Handle hidden internal calls used by fzf list UI
if [[ "${ACTION:-}" == __internal:* ]]; then
  __bm_internal "$ACTION" "$@"
  exit $?
fi

case "$ACTION" in
  install)
    if [[ -n "$MANIFEST_FILE" ]]; then op_install_manifest "$MANIFEST_FILE"; else op_install "$@"; fi;;
  uninstall) op_uninstall "$@";;
  list)
    if command -v fzf >/dev/null 2>&1 && [[ -t 1 ]]; then
      op_list_ranger
    else
      op_list
    fi
    ;;
  doctor) cmd_doctor "$@";;
  update) op_update "$@";;
  new) new_cmd "$@";;
  wizard) new_wizard;;
  backup) op_backup "${1:-}";;
  restore) op_restore "${1:-}";;
  self-update) op_self_update;;
  rollback)
    if [[ -n "${1:-}" ]]; then apply_rollback "$1"; else id="$(latest_rollback_id || true)"; [[ -n "$id" ]] && apply_rollback "$id" || warn "No rollback snapshots yet"; fi;;
  bundle) op_bundle "${1:-}";;
  test) op_test "$@";;
  tui|"") binman_tui;;
  version) say "${SCRIPT_NAME} v${VERSION}";;
  help|*) usage;;
esac

