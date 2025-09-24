#!/usr/bin/env bash
# binman.sh — Personal CLI utility manager for your ~/bin toys
# Manage install/uninstall/list/update for single-file scripts AND multi-file apps.
# TUI, generator, wizard, backup/restore, self-update, system installs, rollbacks, remotes, manifests, bundles, tests.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="binman"
VERSION="1.6.1"

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
  local targets=("$@")
  [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] || { err "Nothing to install"; return 2; }

  stash_before_change >/dev/null

  local count=0
  for src in "${targets[@]}"; do
    if is_url "$src"; then
      local fetched; fetched=$(fetch_remote "$src") || { warn "Fetch failed: $src"; continue; }
      src="$fetched"
    fi
    if [[ -d "$src" ]]; then
      if (( SYSTEM_MODE )); then _install_app_system "$src"; else _install_app "$src"; fi
      count=$((count+1)); continue
    fi
    [[ -f "$src" ]] || { warn "Skip (not a file): $src"; continue; }
    local base dst
    base=$(basename "$src"); dst="${BIN_DIR}/${base%.*}"
    if (( SYSTEM_MODE )); then dst="${SYSTEM_BIN}/${base%.*}"; ensure_system_write; ensure_system_dirs; fi
    [[ -e "$dst" && $FORCE -ne 1 ]] && { warn "Exists: $(basename "$dst") (use --force)"; continue; }
    if [[ "$COPY_MODE" == "link" && $SYSTEM_MODE -eq 0 ]]; then ln -sf "$src" "$dst"; else cp "$src" "$dst"; chmod +x "$dst"; fi
    ok "Installed: $dst (v$(script_version "$src"))"; count=$((count+1))
  done
  if (( SYSTEM_MODE )); then :; else ! in_path && warn "${BIN_DIR} not in PATH. Run: export PATH=\"${BIN_DIR}:$PATH\""; fi
  rehash_shell; say "$count item(s) installed."
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
      if [[ $with_venv -eq 1 ]]; then
        python3 -m venv "$appdir/.venv"
        cat > "$appdir/bin/$cmdname" <<'PY'
#!/usr/bin/env bash
# Description: Hello from app (venv)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/.venv/bin/activate"
python - <<'EOF'
__version__ = "0.1.0"
def main():
    print(f"Hello from __APPNAME__ v{__version__} (venv)")
if __name__ == "__main__":
    main()
EOF
PY
      else
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
      fi
      sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
      chmod +x "$appdir/bin/$cmdname"
    fi
    ok "App scaffolded: $appdir"
  else
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
  say ""; ok "🧙  BinMan Project Wizard"; say "Press Enter to accept [brackets] defaults."
  local name kind lang target_dir="$PWD" _td desc author venv="n"
  read -rp "Project name (no spaces) [MyTool]: " name; name=${name:-MyTool}
  read -rp "Type: (s)ingle-file or (a)pp? [a]: " kind; kind=${kind:-a}; [[ "${kind,,}" =~ ^s ]] && kind="single" || kind="app"
  read -rp "Language: (b)ash or (p)ython? [b]: " lang; lang=${lang:-b}; [[ "${lang,,}" =~ ^p ]] && lang="python" || lang="bash"
  if [[ "$lang" == "python" && "$kind" == "app" ]]; then read -rp "Create venv? (y/N) [n]: " venv; venv=${venv:-n}; fi
  read -rp "Create in directory [${target_dir}]: " _td; [[ -n "$_td" ]] && target_dir="$_td"; mkdir -p "$target_dir"
  read -rp "Short description [A neat little tool]: " desc; desc=${desc:-A neat little tool}
  read -rp "Author [${USER}]: " author; author=${author:-$USER}
  say ""; ok "Generating…"
  local filename path
  if [[ "$kind" == "single" ]]; then
    filename="$name"; [[ "$lang" == "bash" ]] && [[ "$filename" != *.sh ]] && filename="${filename}.sh"
    [[ "$lang" == "python" ]] && [[ "$filename" != *.py ]] && filename="${filename}.py"
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
    ok "README.md created"
  else
    local vflag=()
    [[ "${venv,,}" == "y" ]] && vflag+=(--venv)
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
    ok "README.md created"
  fi
  say ""; local install_now="y" link_mode="n"
  read -rp "Install now? (y/N) [y]: " install_now; install_now=${install_now:-y}
  if [[ "${install_now,,}" == "y" ]]; then
    read -rp "Use symlink instead of copy? (y/N) [n]: " link_mode; link_mode=${link_mode:-n}
    local saved_mode="$COPY_MODE"; [[ "${link_mode,,}" == "y" ]] && COPY_MODE="link" || COPY_MODE="copy"
    op_install "$path"; COPY_MODE="$saved_mode"
  fi
  say ""; local do_git="n"
  read -rp "Initialize a git repo here with gitprep? (y/N) [n]: " do_git; do_git=${do_git:-n}
  if [[ "${do_git,,}" == "y" ]]; then
    if exists gitprep; then
      local gp_branch="main" gp_remote="" gp_push="n"
      read -rp "Default branch name [main]: " gp_branch; gp_branch=${gp_branch:-main}
      read -rp "Remote (git@... or https://...) [blank to skip]: " gp_remote
      read -rp "Push after setup? (y/N) [n]: " gp_push; gp_push=${gp_push:-n}
      (
        cd "$path" 2>/dev/null || cd "$target_dir"
        if [[ -n "$gp_remote" && "${gp_push,,}" == "y" ]]; then gitprep --branch "$gp_branch" --remote "$gp_remote" --push
        elif [[ -n "$gp_remote" ]]; then gitprep --branch "$gp_branch" --remote "$gp_remote"
        else gitprep --branch "$gp_branch"; fi
      )
    else
      warn "gitprep not found; skipping git init (install with: binman install gitprep.sh)"
    fi
  fi
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
