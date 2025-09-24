#!/usr/bin/env bash
# binman.sh — Personal CLI utility manager for your ~/bin toys
# Manage install/uninstall/list/update for single-file scripts AND multi-file apps.
# TUI, generator, wizard, backup/restore, self-update, system installs, rollbacks, remotes, manifests, bundles, tests.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="binman"
VERSION="1.6.3"

# Default (user) locations
BIN_DIR="${HOME}/.local/bin"
APP_STORE="${HOME}/.local/share/binman/apps"

# System locations (when --system)
SYSTEM_BIN="/usr/local/bin"
SYSTEM_APPS="/usr/local/share/binman/apps"

COPY_MODE="copy"   # or link
FORCE=0
FROM_DIR=""
GIT_DIR=""
FIX_PATH=0
SYSTEM_MODE=0
MANIFEST_FILE=""
QUIET=0

say(){ printf "%s\n" "$*"; }
err(){ printf "\e[31m%s\e[0m\n" "$*" 1>&2; }
warn(){ printf "\e[33m%s\e[0m\n" "$*" 1>&2; }
ok(){ printf "\e[32m%s\e[0m\n" "$*"; }
exists(){ command -v "$1" >/dev/null 2>&1; }
iso_now(){ date -Iseconds; }
realpath_f(){ python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || readlink -f "$1"; }

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

Examples:
  ${SCRIPT_NAME} install albumforge.sh
  ${SCRIPT_NAME} install mytool/                      # app dir (expects bin/mytool)
  ${SCRIPT_NAME} install https://.../script.sh        # remote file
  ${SCRIPT_NAME} install --manifest tools.txt         # bulk installs
  ${SCRIPT_NAME} backup ; ${SCRIPT_NAME} restore file.zip
  ${SCRIPT_NAME} self-update
USAGE
}

rehash_shell(){
  if [ -n "${ZSH_VERSION:-}" ]; then hash -r || true; rehash || true; fi
  if [ -n "${BASH_VERSION:-}" ]; then hash -r || true; fi
}

# Path helpers
in_path(){ case ":$PATH:" in *":${BIN_DIR}:"*) return 0;; *) return 1;; esac; }
ensure_dir(){ mkdir -p "$1"; }
ensure_bin(){ ensure_dir "$BIN_DIR"; }
ensure_apps(){ ensure_dir "$APP_STORE"; }
ensure_system_dirs(){ ensure_dir "$SYSTEM_BIN"; ensure_dir "$SYSTEM_APPS"; }

# Rollback stash
ROLLBACK_ROOT="${HOME}/.local/share/binman/rollback"

stash_before_change(){
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local root="${ROLLBACK_ROOT}/${ts}"
  mkdir -p "${root}/bin" "${root}/apps" "${root}/meta"
  [[ -d "$BIN_DIR" ]] && cp -a "$BIN_DIR"/. "${root}/bin" 2>/dev/null || true
  [[ -d "$APP_STORE" ]] && cp -a "$APP_STORE"/. "${root}/apps" 2>/dev/null || true
  printf "Created: %s\nBinMan: %s\nBIN_DIR: %s\nAPP_STORE: %s\n" "$(iso_now)" "${VERSION}" "$BIN_DIR" "$APP_STORE" > "${root}/meta/info.txt"
  ! (( QUIET )) && ok "Rollback snapshot: ${ts}"
  echo "${ts}"
}

latest_rollback_id(){
  [[ -d "$ROLLBACK_ROOT" ]] || return 1
  (cd "$ROLLBACK_ROOT" && ls -1 | sort -r | head -n1)
}

apply_rollback(){
  local id="$1"
  local src="${ROLLBACK_ROOT}/${id}"
  [[ -d "$src" ]] || { err "No rollback id: $id"; return 2; }
  _merge_dir "${src}/bin" "$BIN_DIR"
  _merge_dir "${src}/apps" "$APP_STORE"
  rehash_shell
  ok "Rollback applied: $id"
}

# Version detection & description
script_version(){
  local f="$1"
  if [[ -d "$f" ]]; then
    [[ -f "$f/VERSION" ]] && { head -n1 "$f/VERSION" | tr -d '\r'; return; }
    local name; name=$(basename "$f")
    [[ -f "$f/bin/$name" ]] && grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f/bin/$name" \
      | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' && return
    echo "unknown"; return
  fi
  local v
  v=$(grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f" 2>/dev/null || true)
  [[ -n "$v" ]] && echo "$v" | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' || echo "unknown"
}

script_desc(){
  local f="$1"
  if [[ -d "$f" ]]; then
    local name; name=$(basename "$f")
    f="$f/bin/$name"
  fi
  [[ -f "$f" ]] || { echo ""; return; }
  local line
  line=$(grep -m1 -E '^(# *[^!/].*|# *Description:.*)' "$f" 2>/dev/null | sed -E 's/^# *//; s/^Description: *//')
  echo "${line:-}"
}

# Target list
list_targets(){
  local arr=()
  if [[ -n "$FROM_DIR" ]]; then
    while IFS= read -r -d '' f; do arr+=("$f"); done < <(find "$FROM_DIR" -maxdepth 1 -type f -perm -u+x -print0)
  else
    [[ $# -eq 0 ]] && { err "No scripts specified, and --from not set."; exit 2; }
    for s in "$@"; do arr+=("$s"); done
  fi
  printf '%s\n' "${arr[@]}"
}

# ---- UI helpers --------------------------------------------------------------
ui_init(){
  if [[ -t 1 && -z "${NO_COLOR:-}" && "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    UI_BOLD="$(tput bold)"; UI_DIM="$(tput dim)"; UI_RESET="$(tput sgr0)"
    UI_CYAN="$(tput setaf 6)"; UI_GREEN="$(tput setaf 2)"; UI_YELLOW="$(tput setaf 3)"; UI_MAGENTA="$(tput setaf 5)"
  else
    UI_BOLD=""; UI_DIM=""; UI_RESET=""; UI_CYAN=""; UI_GREEN=""; UI_YELLOW=""; UI_MAGENTA=""
  fi
  UI_WIDTH=${COLUMNS:-80}
}
ui_hr(){ printf "%s\n" "$(printf '─%.0s' $(seq 1 "${1:-$UI_WIDTH}"))"; }
shorten_path(){
  local p="$1" max="${2:-$((UI_WIDTH-10))}"
  local n=${#p}
  if (( n <= max )); then echo "$p"; else
    local keep=$(( (max-3)/2 )); echo "${p:0:keep}...${p:(-keep)}"
  fi
}
ui_kv(){ printf "%s%-10s%s %s\n" "$UI_DIM" "$1" "$UI_RESET" "$2"; }

# App helpers
_app_entry(){ local appdir="$1"; local name; name=$(basename "$appdir"); echo "$appdir/bin/$name"; }
_make_shim(){ local name="$1" entry="$2" shim="$BIN_DIR/$name"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" > "$shim"; chmod +x "$shim"; }
_make_shim_system(){ local name="$1" entry="$2" shim="$SYSTEM_BIN/$name"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" > "$shim"; chmod +x "$shim"; }

# Prompt helpers (TTY-safe)
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

_install_app(){
  ensure_apps; ensure_bin
  local src="$1"; local name; name=$(basename "$src"); local dest="$APP_STORE/$name"
  [[ -x "$src/bin/$name" ]] || { err "App '$name' missing bin/$name"; return 2; }
  rm -rf "$dest"
  [[ "$COPY_MODE" == "link" ]] && ln -s "$src" "$dest" || cp -a "$src" "$dest"
  _make_shim "$name" "$(_app_entry "$dest")"
  ok "App installed: $name → $dest (v$(script_version "$dest"))"
}
_install_app_system(){
  ensure_system_write
  ensure_system_dirs
  local src="$1"; local name; name=$(basename "$src"); local dest="$SYSTEM_APPS/$name"
  [[ -x "$src/bin/$name" ]] || { err "App '$name' missing bin/$name"; return 2; }
  rm -rf "$dest"
  [[ "$COPY_MODE" == "link" ]] && ln -s "$src" "$dest" || cp -a "$src" "$dest"
  _make_shim_system "$name" "$(_app_entry "$dest")"
  ok "App installed (system): $name → $dest"
}
_uninstall_app(){
  local name="$1"; local dest="$APP_STORE/$name"; local shim="$BIN_DIR/$name"
  [[ -e "$shim" ]] && rm -f "$shim" && ok "Removed shim: $shim"
  [[ -e "$dest" ]] && rm -rf "$dest" && ok "Removed app: $dest"
}
_uninstall_app_system(){
  ensure_system_write
  local name="$1"; local dest="$SYSTEM_APPS/$name"; local shim="$SYSTEM_BIN/$name"
  [[ -e "$shim" ]] && rm -f "$shim" && ok "Removed shim: $shim"
  [[ -e "$dest" ]] && rm -rf "$dest" && ok "Removed app: $dest"
}

# Remote fetch
is_url(){ [[ "$1" =~ ^https?:// ]]; }
fetch_remote(){
  local url="$1"; local outdir; outdir=$(mktemp -d)
  local fname="${2:-$(basename "${url%%\?*}")}"
  local out="${outdir}/${fname}"
  if exists curl; then
    curl -fsSL "$url" -o "$out"
  elif exists wget; then
    wget -q "$url" -O "$out"
  else
    err "Need curl or wget for remote installs"; return 2
  fi
  echo "$out"
}

# Merge/copy helpers
_merge_dir(){
  local src_dir="$1" dst_dir="$2"
  [[ -d "$src_dir" ]] || return 0
  mkdir -p "$dst_dir"
  shopt -s dotglob
  for p in "$src_dir"/*; do
    [[ -e "$p" ]] || continue
    local name; name="$(basename "$p")"
    local dst="$dst_dir/$name"
    if [[ -e "$dst" && $FORCE -ne 1 ]]; then
      warn "Skip existing: $dst (use --force to overwrite)"
      continue
    fi
    rm -rf "$dst" 2>/dev/null || true
    cp -a "$p" "$dst"
  done
}
_chmod_bin_execs(){
  if [[ -d "$BIN_DIR" ]]; then
    find "$BIN_DIR" -maxdepth 1 -type f -exec chmod +x {} \; 2>/dev/null || true
  fi
}

# Install / Uninstall
op_install(){
  # Build the target list (from args or --from DIR)
  local targets=("$@")
  [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] || { err "Nothing to install"; return 2; }

  # Snapshot current state so rollback can undo a bad batch
  stash_before_change >/dev/null || true

  local count=0
  for src in "${targets[@]}"; do
    # Allow remote URLs (curl/wget). We fetch to a temp file first.
    if is_url "$src"; then
      local fetched
      if ! fetched=$(fetch_remote "$src"); then
        warn "Fetch failed: $src"
        continue
      fi
      src="$fetched"
    fi

    # App install (directory containing bin/<appname>)
    if [[ -d "$src" ]]; then
      if (( SYSTEM_MODE )); then
        _install_app_system "$src"
      else
        _install_app "$src"
      fi
      count=$((count+1))
      continue
    fi

    # Single-file install
    if [[ ! -f "$src" ]]; then
      warn "Skip (not a file): $src"
      continue
    fi

    local base dst tmp
    base=$(basename "$src")                    # e.g., binman.sh
    dst="${BIN_DIR}/${base%.*}"                # → ~/.local/bin/binman

    # System-wide target?
    if (( SYSTEM_MODE )); then
      dst="${SYSTEM_BIN}/${base%.*}"           # → /usr/local/bin/binman
      ensure_system_write
      ensure_system_dirs
    fi

    # Protect existing unless --force
    if [[ -e "$dst" && $FORCE -ne 1 ]]; then
      warn "Exists: $(basename "$dst") (use --force)"
      continue
    fi

    # Symlink mode (dev-friendly), only for user installs
    if [[ "$COPY_MODE" == "link" && $SYSTEM_MODE -eq 0 ]]; then
      ln -sf "$src" "$dst"
      ok "Installed: $dst (symlink) (v$(script_version "$src"))"
      count=$((count+1))
      continue
    fi

    # Copy mode: write atomically via temp file
    if ! tmp="$(mktemp "${dst}.tmp.XXXXXX")"; then
      err "mktemp failed for $dst"
      continue
    fi
    if ! cp -f "$src" "$tmp"; then
      rm -f "$tmp"
      warn "Copy failed: $src"
      continue
    fi
    chmod +x "$tmp" 2>/dev/null || true

    # Light sanity check: if it looks like a shell script, run bash -n
    if head -n1 "$tmp" | grep -qiE '^#!.*(bash|sh)'; then
      if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        err "Syntax check failed; keeping existing $(basename "$dst")."
        continue
      fi
    fi

    # Atomic replace
    if mv -f "$tmp" "$dst"; then
      ok "Installed: $dst (v$(script_version "$src"))"
      count=$((count+1))
    else
      rm -f "$tmp"
      warn "Failed to install: $src"
    fi
  done

  # PATH hint (user mode only)
  if (( ! SYSTEM_MODE )) && ! in_path; then
    warn "${BIN_DIR} not in PATH. Run: export PATH=\"${BIN_DIR}:\$PATH\""
  fi

  rehash_shell
  say "$count item(s) installed."
}


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
  rehash_shell; say "$count item(s) removed."
}

op_list(){
  ensure_bin; ensure_apps
  print_banner
  say "Commands in ${SYSTEM_MODE:+(system) }$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR"):"
  printf "%-20s %-10s %s\n" "Name" "Version" "Description"; printf "%-20s %-10s %s\n" "----" "-------" "-----------"
  local dir="$BIN_DIR"; (( SYSTEM_MODE )) && dir="$SYSTEM_BIN"
  for f in "$dir"/*; do
    [[ -x "$f" && -f "$f" ]] || continue
    printf "%-20s %-10s %s\n" "$(basename "$f")" "$(script_version "$f")" "$(script_desc "$f")"
  done
  echo
  say "Apps in $([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE"):"
  printf "%-20s %-10s %s\n" "App" "Version" "Description"; printf "%-20s %-10s %s\n" "---" "-------" "-----------"
  local adir="$APP_STORE"; (( SYSTEM_MODE )) && adir="$SYSTEM_APPS"
  for d in "$adir"/*; do
    [[ -d "$d" || -L "$d" ]] || continue
    local name; name="$(basename "$d")"
    printf "%-20s %-10s %s\n" "$name" "$(script_version "$d")" "$(script_desc "$d")"
  done
}

op_doctor(){
  say "Mode      : $([[ $SYSTEM_MODE -eq 1 ]] && echo system || echo user)"
  say "BIN_DIR   : $([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR")"
  say "APP_STORE : $([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE")"
  (( SYSTEM_MODE )) || { in_path && ok "PATH ok" || warn "PATH missing ${BIN_DIR}"; }
  exists zip   && ok "zip: present"   || warn "zip: not found (fallback to .tar.gz)"
  exists unzip && ok "unzip: present" || warn "unzip: not found (needed to restore .zip)"
  exists tar   && ok "tar: present"   || warn "tar: not found (needed to restore .tar.gz)"
  if [[ $FIX_PATH -eq 1 ]]; then
    for f in "$HOME/.zshrc" "$HOME/.zprofile"; do
      if [[ -f "$f" ]] && ! grep -qE '(^|:)\$HOME/\.local/bin(:|$)' "$f"; then
        printf '\n# Added by binman doctor\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$f"
        ok "Patched PATH in $f"
      fi
    done
  fi
}

op_update(){
  [[ -n "$GIT_DIR" && -d "$GIT_DIR/.git" ]] && (cd "$GIT_DIR" && git pull --rebase --autostash)
  local targets=("$@"); [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] && { FORCE=1; stash_before_change >/dev/null; op_install "${targets[@]}"; } || warn "Nothing to reinstall"
}

# Backup/Restore
_backup_filename_default(){ local ext="$1"; local ts; ts=$(date +%Y%m%d-%H%M%S); echo "binman_backup-${ts}.${ext}"; }
op_backup(){
  ensure_bin; ensure_apps
  local prefer_zip=1 ext
  if exists zip && exists unzip; then ext="zip"; else prefer_zip=0; ext="tar.gz"; warn "zip/unzip not fully available; using .tar.gz"; fi
  local outfile="${1:-$(_backup_filename_default "$ext")}"
  [[ "$outfile" != *.zip && "$outfile" != *.tar.gz && "$outfile" != *.tgz ]] && outfile="${outfile}.${ext}"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp"/{bin,apps,meta}
  [[ -d "$BIN_DIR" ]]  && cp -a "$BIN_DIR"/.  "$tmp/bin"  2>/dev/null || true
  [[ -d "$APP_STORE" ]]&& cp -a "$APP_STORE"/. "$tmp/apps" 2>/dev/null || true
  cat > "$tmp/meta/info.txt" <<EOF
Created: $(iso_now)
BinMan:  ${SCRIPT_NAME} v${VERSION}
BIN_DIR: ${BIN_DIR}
APP_STORE: ${APP_STORE}
Host: $(uname -a)
EOF
  if [[ $prefer_zip -eq 1 ]]; then (cd "$tmp" && zip -qr "../$outfile" bin apps meta); else (cd "$tmp" && tar -czf "../$outfile" bin apps meta); fi
  local abs_out; abs_out="$(cd "$(dirname "$tmp/../$outfile")" && pwd)/$(basename "$outfile")"
  ok "Backup created: ${abs_out}"
}
_detect_extract_root(){
  local base="$1"
  if [[ -d "$base/bin" || -d "$base/apps" ]]; then echo "$base"; return 0; fi
  for d in "$base"/*; do [[ -d "$d" ]] || continue; [[ -d "$d/bin" || -d "$d/apps" ]] && { echo "$d"; return 0; }; done
  echo "$base"
}
op_restore(){
  ensure_bin; ensure_apps; stash_before_change >/dev/null
  local archive="$1"; [[ -n "$archive" && -f "$archive" ]] || { err "restore requires an existing archive"; exit 2; }
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  case "$archive" in
    *.zip) exists unzip || { err "unzip not available"; exit 2; }; unzip -q "$archive" -d "$tmp";;
    *.tar.gz|*.tgz) exists tar || { err "tar not available"; exit 2; }; tar -xzf "$archive" -C "$tmp";;
    *) err "Unknown archive type (use .zip or .tar.gz): $archive"; exit 2;;
  esac
  local root; root="$(_detect_extract_root "$tmp")"
  [[ -d "$root/bin"  ]] && { say "Restoring scripts to ${BIN_DIR}..."; _merge_dir "$root/bin" "$BIN_DIR"; }
  [[ -d "$root/apps" ]] && { say "Restoring apps to ${APP_STORE}..."; _merge_dir "$root/apps" "$APP_STORE"; }
  _chmod_bin_execs; rehash_shell; ok "Restore complete."
}

# Self-update
op_self_update(){
  local script_path repo root
  script_path="$(realpath_f "$0" || echo "$0")"
  root="$(dirname "$script_path")"
  repo="$root"
  if [[ -d "$repo/.git" ]]; then
    ( cd "$repo" && git pull --rebase --autostash )
    ok "Repo updated."
  elif [[ -n "$GIT_DIR" && -d "$GIT_DIR/.git" ]]; then
    ( cd "$GIT_DIR" && git pull --rebase --autostash )
    repo="$GIT_DIR"
    ok "Repo updated (GIT_DIR)."
  else
    err "Cannot find git repo for self-update. Use --git DIR."
    return 2
  fi
  local self="$repo/binman.sh"
  [[ -f "$self" ]] || { err "binman.sh not found in repo root"; return 2; }
  FORCE=1 op_install "$self"
  ok "Self-update complete."
}

# Bundle export (bin+apps+manifest)
op_bundle(){
  ensure_bin; ensure_apps
  local out="${1:-binman_bundle-$(date +%Y%m%d-%H%M%S).zip}"
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp"/{bin,apps}
  [[ -d "$BIN_DIR" ]]  && cp -a "$BIN_DIR"/.  "$tmp/bin"  2>/dev/null || true
  [[ -d "$APP_STORE" ]]&& cp -a "$APP_STORE"/. "$tmp/apps" 2>/dev/null || true
  {
    echo "# BinMan bundle manifest"
    echo "created=$(iso_now)"
    echo "bin_dir=$BIN_DIR"
    echo "app_store=$APP_STORE"
    echo
    echo "[bin]"
    find "$tmp/bin" -maxdepth 1 -type f -printf "%f\n" 2>/dev/null || true
    echo
    echo "[apps]"
    find "$tmp/apps" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null || true
  } > "$tmp/manifest.txt"
  if exists zip; then (cd "$tmp" && zip -qr "../$out" bin apps manifest.txt); else (cd "$tmp" && tar -czf "../${out%.zip}.tar.gz" bin apps manifest.txt; out="${out%.zip}.tar.gz"); fi
  ok "Bundle created: $(realpath_f "$tmp/../$out")"
}

# Testing harness
op_test(){
  local name="$1"; shift || true
  [[ -n "$name" ]] || { err "test requires a command name"; return 2; }
  local path
  if (( SYSTEM_MODE )); then path="$SYSTEM_BIN/$name"; else path="$BIN_DIR/$name"; fi
  [[ -x "$path" ]] || { err "not installed or not executable: $name"; return 2; }
  local args=("$@"); [[ ${#args[@]} -eq 0 ]] && args=(--help)
  "$path" "${args[@]}" >/dev/null 2>&1 && ok "PASS: $name ${args[*]}" || { local rc=$?; warn "FAIL: $name (exit $rc)"; return $rc; }
}

# Manifest install (line list; optional JSON with jq)
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

# Generator (bash/python) with optional venv for python apps
new_cmd(){
  local name="$1"; shift || true
  local lang="bash" make_app=0 target_dir="$PWD" with_venv=0
  [[ "$name" == *".py" ]] && lang="python"
  [[ "$name" == *".sh" ]] && lang="bash"
  local cmdname="${name%.*}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) make_app=1; shift;;
      --lang) lang="$2"; shift 2;;
      --dir) target_dir="$2"; shift 2;;
      --venv) with_venv=1; shift;;
      *) shift;;
    esac
  done

  if [[ $make_app -eq 1 ]]; then
    local appdir="$target_dir/$cmdname"
    mkdir -p "$appdir/bin" "$appdir/src"
    echo "0.1.0" > "$appdir/VERSION"

    if [[ "$lang" == "bash" ]]; then
      # Bash app entry
      cat > "$appdir/bin/$cmdname" <<'BASH'
#!/usr/bin/env bash
# Description: Hello from app
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from __APPNAME__ v$VERSION"
BASH
      sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
      chmod +x "$appdir/bin/$cmdname"

    else
      # Python app
      if [[ $with_venv -eq 1 ]]; then
        # Create venv and modern Python package layout
        python3 -m venv "$appdir/.venv"

        # Package scaffold
        mkdir -p "$appdir/src/$cmdname"
        cat > "$appdir/src/$cmdname/__init__.py" <<'PY'
__version__ = "0.1.0"
PY
        cat > "$appdir/src/$cmdname/__main__.py" <<'PY'
from . import __version__

def main():
    print(f"Hello from __APPNAME__ v{__version__} (venv)")

if __name__ == "__main__":
    main()
PY
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/src/$cmdname/__main__.py"

        # Empty requirements placeholder
        cat > "$appdir/requirements.txt" <<'REQ'
# Add your dependencies here, one per line, e.g.:
# scapy
REQ

        # Launcher (venv + auto-install requirements + PYTHONPATH=src + run module)
        cat > "$appdir/bin/$cmdname" <<'BASH'
#!/usr/bin/env bash
# Description: __APPNAME__ (venv launcher)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure venv exists (idempotent)
if [[ ! -x "$HERE/.venv/bin/python" ]]; then
  python3 -m venv "$HERE/.venv"
fi

# shellcheck source=/dev/null
source "$HERE/.venv/bin/activate"

# Auto-install requirements if present (quiet; non-fatal)
if [[ -f "$HERE/requirements.txt" ]]; then
  "$HERE/.venv/bin/pip" install -r "$HERE/requirements.txt" >/dev/null 2>&1 || true
fi

# Make package under src/ importable
export PYTHONPATH="$HERE/src${PYTHONPATH:+:$PYTHONPATH}"

# Run the package as a module
exec python -m __APPNAME__ "$@"
BASH
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
        chmod +x "$appdir/bin/$cmdname"

      else
        # Simple Python entry without venv
        cat > "$appdir/bin/$cmdname" <<'PY'
#!/usr/bin/env python3
# Description: Hello from app
__version__ = "0.1.0"
def main():
    print(f"Hello from __APPNAME__ v{__version__}")
    return 0
if __name__ == "__main__":
    import sys
    sys.exit(main())
PY
        sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
        chmod +x "$appdir/bin/$cmdname"
      fi
    fi

    ok "App scaffolded: $appdir"

  else
    # Single-file script
    mkdir -p "$target_dir"
    if [[ "$lang" == "bash" ]]; then
      [[ "$name" != *.sh ]] && name="${name}.sh"
      cat > "$target_dir/$name" <<'BASH'
#!/usr/bin/env bash
# Description: Hello from script
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from __SCRIPTNAME__ v$VERSION"
BASH
      sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
      chmod +x "$target_dir/$name"
    else
      [[ "$name" != *.py ]] && name="${name}.py"
      cat > "$target_dir/$name" <<'PY'
#!/usr/bin/env python3
# Description: Hello from script
__version__ = "0.1.0"
def main():
    print(f"Hello from __SCRIPTNAME__ v{__version__}")
    return 0
if __name__ == "__main__":
    import sys
    sys.exit(main())
PY
      sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
      chmod +x "$target_dir/$name"
    fi
    ok "Script scaffolded: $target_dir/$name"
  fi
}

# Wizard
new_wizard(){
  ui_init; prompt_init
  tput clear 2>/dev/null || clear
  echo
  printf "%s🧙  BinMan Project Wizard%s\n" "$UI_BOLD" "$UI_RESET"
  printf "%sPress Enter to accept defaults in %s[brackets]%s.%s\n\n" "$UI_DIM" "$UI_BOLD" "$UI_RESET" "$UI_RESET"

  # Section: Basics
  printf "%s==> Basics%s\n" "$UI_GREEN" "$UI_RESET"
  local name kind lang target_dir desc author
  name="$(ask "Project name (no spaces)" "MyTool")"

  # choose kind
  kind="$(ask_choice "Type" "single/app" "app")"
  [[ "${kind,,}" =~ ^s ]] && kind="single" || kind="app"

  # language
  lang="$(ask_choice "Language" "bash/python" "bash")"
  [[ "${lang,,}" =~ ^p ]] && lang="python" || lang="bash"

  # destination
  target_dir="$(ask "Create in directory" "$PWD")"
  mkdir -p "$target_dir"

  desc="$(ask "Short description" "A neat little tool")"
  author="$(ask "Author" "${USER}")"

  # Python venv toggle (only for app+python)
  local with_venv="n"
  if [[ "$kind" == "app" && "$lang" == "python" ]]; then
    printf "\n%s==> Python options%s\n" "$UI_GREEN" "$UI_RESET"
    if ask_yesno "Create virtual environment (.venv)?" "y"; then with_venv="y"; fi
  fi

  # Preview summary
  printf "\n%s==> Summary%s\n" "$UI_GREEN" "$UI_RESET"
  prompt_kv "Name"        "$name"
  prompt_kv "Type"        "$kind"
  prompt_kv "Language"    "$lang"
  prompt_kv "Directory"   "$target_dir"
  prompt_kv "Description" "$desc"
  prompt_kv "Author"      "$author"
  [[ "$with_venv" == "y" ]] && prompt_kv "Python venv" "enabled"

  echo
  if ! ask_yesno "Proceed with generation?" "y"; then
    warn "Aborted by user."
    return 1
  fi

  echo; ok "Generating…"

  # Generate via new_cmd
  local filename path
  if [[ "$kind" == "single" ]]; then
    filename="$name"
    [[ "$lang" == "bash"   && "$filename" != *.sh ]] && filename="${filename}.sh"
    [[ "$lang" == "python" && "$filename" != *.py ]] && filename="${filename}.py"
    new_cmd "$filename" --lang "$lang" --dir "$target_dir"
    path="${target_dir}/${filename}"

    # README
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
    local vflag=()
    [[ "${with_venv,,}" == "y" ]] && vflag+=(--venv)
    new_cmd "$name" --app --lang "$lang" --dir "$target_dir" "${vflag[@]}"
    path="${target_dir}/${name}"

    # README
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

  # Install now?
  echo
  printf "%s==> Install%s\n" "$UI_GREEN" "$UI_RESET"
  local saved_mode="$COPY_MODE"
  if ask_yesno "Install now?" "y"; then
    if ask_yesno "Use symlink instead of copy?" "n"; then COPY_MODE="link"; else COPY_MODE="copy"; fi
    op_install "$path"
  fi
  COPY_MODE="$saved_mode"

  # ─────────────────────────────────────────────────────────────
  # Git setup (auto-friendly, but never blocks)
  # ─────────────────────────────────────────────────────────────
  echo
  printf "%s==> Git%s\n" "$UI_GREEN" "$UI_RESET"
  if ask_yesno "Initialize a git repo here?" "y"; then
    local repo_root
    [[ "$kind" == "app" ]] && repo_root="$path" || repo_root="$target_dir"

    # Initialize with gitprep if available, else plain git
    if exists gitprep; then
      ( cd "$repo_root" && gitprep --branch main )
    else
      warn "gitprep not found; doing a plain git init"
      (
        cd "$repo_root"
        git init -b main >/dev/null 2>&1 || { git init >/dev/null; git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1 || true; }
        git add -A
        git commit -m "init: ${name} (wizard)" >/dev/null 2>&1 || true
      )
    fi

    # Decide remote flow
    local have_gh=0
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      have_gh=1
    fi

    echo
    say "Git setup options:"
    if (( have_gh )); then
      say "  A) Create GitHub repo now (auto)"
    fi
    say "  B) Add an existing remote URL (SSH/HTTPS)"
    say "  C) Local only (skip remote)"

    local default_choice="C"
    (( have_gh )) && default_choice="A"
    local choice; choice="$(ask "Choose [A/B/C]" "$default_choice")"
    choice="${choice^^}"

    (
      cd "$repo_root"
      case "$choice" in
        A)
          if (( have_gh )); then
            local owner repo visflag
            owner="$(gh api user -q .login 2>/dev/null || echo "")"
            repo="${name}"
            visflag="--public"
            ask_yesno "Create as private?" "n" && visflag="--private"

            if gh repo create "${owner}/${repo}" $visflag --source . --push >/dev/null 2>&1; then
              ok "Created GitHub repo ${owner}/${repo} and pushed."
            else
              warn "GitHub create/push failed (auth/perm/network?)."
              warn "Leaving repo local-only. You can add a remote later."
              say  "Try: gh repo create ${owner}/${repo} $visflag --source . --push"
            fi
          else
            warn "'gh' not available or not authenticated; remaining local-only."
          fi
          ;;
        B)
          local remote_url
          remote_url="$(ask "Remote URL (git@... or https://...)" "")"

          if [[ -z "$remote_url" ]]; then
            warn "No URL given; remaining local-only."
            break
          fi

          # If user pasted a GitHub HTTPS URL, offer to convert to SSH
          if [[ "$remote_url" =~ ^https://github\.com/([^/]+)/([^/.]+)(\.git)?$ ]]; then
            local gh_owner="${BASH_REMATCH[1]}"
            local gh_repo="${BASH_REMATCH[2]}"
            local ssh_url="git@github.com:${gh_owner}/${gh_repo}.git"

            # Check if SSH is likely to work
            local can_ssh=0
            if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
              can_ssh=1
            elif ssh -T git@github.com -o BatchMode=yes >/dev/null 2>&1; then
              can_ssh=1
            fi

            if (( can_ssh )) && ask_yesno "Use SSH instead of HTTPS for GitHub? ($ssh_url)" "y"; then
              remote_url="$ssh_url"
            else
              warn "Keeping HTTPS. Note: pushes will prompt for a Personal Access Token."
            fi
          fi

          if git remote get-url origin >/dev/null 2>&1; then
            git remote set-url origin "$remote_url"
          else
            git remote add origin "$remote_url"
          fi

          # First push
          git push -u origin main || warn "Push failed. If using HTTPS, use a PAT as the password."
          ok "Remote set and push attempted."
          ;;

        *)
          say ""
          say "Next steps:"
          say "  • Set remote: git remote add origin <git@... or https://...>"
          say "  • Then push: git push -u origin main"
          say "  • Or use:    gh repo create <owner>/<repo> --source . --push"
          ;;
      esac
    )
  else
    warn "Skipping git init."
  fi

  echo
  ok "Wizard complete. Happy hacking, ${author}! ✨"
}


# Banner
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
  home_path="$(shorten_path "$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_BIN" || echo "$BIN_DIR")" 60)"
  apps_path="$(shorten_path "$([[ $SYSTEM_MODE -eq 1 ]] && echo "$SYSTEM_APPS" || echo "$APP_STORE")" 60)"
  sys_path="$(shorten_path "$SYSTEM_BIN" 60)"

  ui_kv "Home:"  "$home_path"
  ui_kv "Apps:"  "$apps_path"
  ui_kv "System:" "$sys_path"
  ui_hr
  printf "%s1)%s Install   %s2)%s Uninstall   %s3)%s List   %s4)%s Doctor   %s5)%s New   %s6)%s Wizard\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
  printf "%s7)%s Backup    %s8)%s Restore     %s9)%s Self-Update   %sa)%s Rollback   %sb)%s Bundle   %sc)%s Test\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
  printf "%ss)%s Toggle System Mode %s(currently: %s)%s    %sq)%s Quit\n" \
    "$UI_CYAN" "$UI_RESET" "$UI_DIM" "$([[ $SYSTEM_MODE -eq 1 ]] && echo "ON" || echo "OFF")" "$UI_RESET" "$UI_CYAN" "$UI_RESET"
  ui_hr
}

# System write guard
ensure_system_write(){
  [[ -w "$SYSTEM_BIN" && -w "$SYSTEM_APPS" ]] || warn "Need write access to ${SYSTEM_BIN} and ${SYSTEM_APPS}. Try: sudo $SCRIPT_NAME --system <cmd> ..."
}

# Option parsing (also handles --backup/--restore immediate)
parse_common_opts(){
  ARGS_OUT=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) FROM_DIR="$2"; shift 2;;
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

# TUI
binman_tui(){
  while :; do
    print_banner
    printf "%sChoice:%s " "$UI_BOLD" "$UI_RESET"
    IFS= read -r c
    case "$c" in
      1) printf "File/dir/URL (or --manifest FILE): "; read -r f
         if [[ "$f" =~ ^--manifest[[:space:]]+ ]]; then op_install_manifest "${f#--manifest }"; else op_install "$f"; fi
         printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      2) printf "Name: "; read -r n; op_uninstall "$n"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      3) op_list; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      4) op_doctor; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      5) printf "Name: "; read -r n; new_cmd "$n"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      6) new_wizard; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      7) printf "Output file [blank=auto]: "; read -r f; op_backup "${f}"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      8) printf "Archive to restore: "; read -r f; op_restore "$f"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      9) op_self_update; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      a|A) id="$(latest_rollback_id || true)"; [[ -n "$id" ]] && apply_rollback "$id" || warn "No rollback snapshots yet"
           printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      b|B) printf "Bundle filename [blank=auto]: "; read -r f; op_bundle "${f}"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      c|C) printf "Command name to test: "; read -r n; op_test "$n"; printf "%sPress Enter...%s" "$UI_DIM" "$UI_RESET"; read -r;;
      s|S) SYSTEM_MODE=$((1-SYSTEM_MODE)); ok "System mode: $([[ $SYSTEM_MODE -eq 1 ]] && echo ON || echo OFF)"; sleep 0.5;;
      q|Q) exit 0;;
      *) warn "Unknown choice: $c"; sleep 0.7;;
    esac
  done
}

# ---- Main ----
if [[ $# -eq 0 ]]; then binman_tui; exit 0; fi

# Parse opts (also handles --backup/--restore immediate)
if parse_common_opts "$@"; then exit 0; fi
set -- "${ARGS_OUT[@]}"

ACTION="${1:-}"; shift || true

case "$ACTION" in
  install)
    if [[ -n "$MANIFEST_FILE" ]]; then op_install_manifest "$MANIFEST_FILE"; else op_install "$@"; fi;;
  uninstall) op_uninstall "$@";;
  list) op_list;;
  doctor) op_doctor;;
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
