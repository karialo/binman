#!/usr/bin/env bash
# binman.sh — Personal CLI utility manager for your ~/bin toys
# Manage install/uninstall/list/update for single-file scripts AND multi-file apps.
# Includes a TUI menu, a generator, and an interactive wizard.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="binman"
VERSION="1.3.0"
BIN_DIR="${HOME}/.local/bin"
APP_STORE="${HOME}/.local/share/binman/apps"
COPY_MODE="copy"   # or link
FORCE=0
FROM_DIR=""
GIT_DIR=""
FIX_PATH=0

say(){ printf "%s\n" "$*"; }
err(){ printf "\e[31m%s\e[0m\n" "$*" 1>&2; }
warn(){ printf "\e[33m%s\e[0m\n" "$*" 1>&2; }
ok(){ printf "\e[32m%s\e[0m\n" "$*"; }
exists(){ command -v "$1" >/dev/null 2>&1; }
iso_now(){ date -Iseconds; }

usage(){ cat <<USAGE
${SCRIPT_NAME} v${VERSION}
Manage your personal CLI scripts in ${BIN_DIR} and apps in ${APP_STORE}

USAGE: ${SCRIPT_NAME} <install|uninstall|list|update|doctor|new|wizard|tui|version|help> [args] [options]

Options:
  --from DIR       Operate on all executable files in DIR
  --link           Symlink instead of copying
  --force          Overwrite existing files in bin/app store
  --git DIR        For update: git pull in DIR before install
  --bin DIR        Override bin directory (default: ${BIN_DIR})
  --apps DIR       Override apps directory (default: ${APP_STORE})
  --fix-path       (doctor) Append ~/.local/bin to zsh PATH (~/.zshrc & ~/.zprofile)

new (generator) options:
  ${SCRIPT_NAME} new <name[.sh|.py]> [--app] [--lang bash|python] [--dir DIR]

Examples:
  ${SCRIPT_NAME} install albumforge.sh
  ${SCRIPT_NAME} install mytool/                  # installs an app dir (expects bin/mytool)
  ${SCRIPT_NAME} uninstall albumforge mytool
  ${SCRIPT_NAME} list
  ${SCRIPT_NAME} doctor --fix-path
  ${SCRIPT_NAME} new smartassapp.py
  ${SCRIPT_NAME} wizard                           # interactive project generator
  ${SCRIPT_NAME} tui
USAGE
}

rehash_shell(){
  if [ -n "${ZSH_VERSION:-}" ]; then hash -r || true; rehash || true; fi
  if [ -n "${BASH_VERSION:-}" ]; then hash -r || true; fi
}

in_path(){ case ":$PATH:" in *":${BIN_DIR}:"*) return 0;; *) return 1;; esac; }
ensure_bin(){ mkdir -p "$BIN_DIR"; }
ensure_apps(){ mkdir -p "$APP_STORE"; }

# ---- Version detection ----
script_version(){
  local f="$1"
  if [[ -d "$f" ]]; then
    [[ -f "$f/VERSION" ]] && { head -n1 "$f/VERSION" | tr -d '\r'; return; }
    local name=$(basename "$f")
    [[ -f "$f/bin/$name" ]] && grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f/bin/$name" \
      | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' && return
    echo "unknown"; return
  fi
  local v
  v=$(grep -m1 -E '^(VERSION=|# *Version:|__version__ *=)' "$f" 2>/dev/null || true)
  [[ -n "$v" ]] && echo "$v" | sed -E 's/^[# ]*Version:? *//; s/^VERSION=//; s/__version__ *= *//; s/[\"\x27]//g' || echo "unknown"
}

# ---- Target list ----
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

# ---- App helpers ----
_app_entry(){ local appdir="$1"; local name=$(basename "$appdir"); echo "$appdir/bin/$name"; }
_make_shim(){ local name="$1" entry="$2" shim="$BIN_DIR/$name"; printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$entry" > "$shim"; chmod +x "$shim"; }

_install_app(){
  ensure_apps; ensure_bin
  local src="$1"; local name=$(basename "$src"); local dest="$APP_STORE/$name"
  [[ -x "$src/bin/$name" ]] || { err "App '$name' missing bin/$name"; return 2; }
  rm -rf "$dest"
  [[ "$COPY_MODE" == "link" ]] && ln -s "$src" "$dest" || cp -a "$src" "$dest"
  _make_shim "$name" "$(_app_entry "$dest")"
  ok "App installed: $name → $dest (v$(script_version "$dest"))"
}

_uninstall_app(){
  local name="$1"; local dest="$APP_STORE/$name"; local shim="$BIN_DIR/$name"
  [[ -e "$shim" ]] && rm -f "$shim" && ok "Removed shim: $shim"
  [[ -e "$dest" ]] && rm -rf "$dest" && ok "Removed app: $dest"
}

# ---- Single-file install/uninstall ----
op_install(){
  ensure_bin
  local count=0
  for src in "$@"; do
    if [[ -d "$src" ]]; then _install_app "$src"; count=$((count+1)); continue; fi
    local base=$(basename "$src"); local dst="$BIN_DIR/${base%.*}"
    [[ -f "$src" ]] || { warn "Skip (not a file): $src"; continue; }
    [[ -e "$dst" && $FORCE -ne 1 ]] && { warn "Exists: $(basename "$dst")"; continue; }
    [[ "$COPY_MODE" == "link" ]] && ln -sf "$src" "$dst" || { cp "$src" "$dst"; chmod +x "$dst"; }
    ok "Installed: $dst (v$(script_version "$src"))"; count=$((count+1))
  done
  ! in_path && warn "${BIN_DIR} not in PATH. Run: export PATH=\"${BIN_DIR}:$PATH\""
  rehash_shell; say "$count item(s) installed."
}

op_uninstall(){
  local count=0
  for name in "$@"; do
    [[ -e "$APP_STORE/$name" ]] && { _uninstall_app "$name"; count=$((count+1)); continue; }
    local dst="$BIN_DIR/${name%.*}"
    [[ -e "$dst" ]] && { rm -f "$dst"; ok "Removed: $dst"; count=$((count+1)); } || warn "Not found: $name"
  done
  rehash_shell; say "$count item(s) removed."
}

op_list(){
  ensure_bin; ensure_apps
  print_banner
  say "Commands in $BIN_DIR:"; printf "%-20s %s\n" "Name" "Version"; printf "%-20s %s\n" "----" "-------"
  for f in "$BIN_DIR"/*; do [[ -x "$f" && -f "$f" ]] && printf "%-20s %s\n" "$(basename "$f")" "$(script_version "$f")"; done
  echo; say "Apps in $APP_STORE:"; printf "%-20s %s\n" "App" "Version"; printf "%-20s %s\n" "---" "-------"
  for d in "$APP_STORE"/*; do [[ -d "$d" || -L "$d" ]] && printf "%-20s %s\n" "$(basename "$d")" "$(script_version "$d")"; done
}

op_doctor(){
  ensure_bin; ensure_apps
  say "BIN_DIR: $BIN_DIR"; say "APP_STORE: $APP_STORE"
  in_path && ok "PATH ok" || warn "PATH missing ${BIN_DIR}"
}

op_update(){
  [[ -n "$GIT_DIR" && -d "$GIT_DIR/.git" ]] && (cd "$GIT_DIR" && git pull --rebase --autostash)
  local targets=("$@"); [[ -n "$FROM_DIR" ]] && mapfile -t targets < <(list_targets)
  [[ ${#targets[@]} -gt 0 ]] && FORCE=1 op_install "${targets[@]}" || warn "Nothing to reinstall"
}

# ---- Generator (bash/python) ----
new_cmd(){
  local name="$1"; shift || true
  local lang="bash" make_app=0 target_dir="$PWD"
  [[ "$name" == *".py" ]] && lang="python"
  [[ "$name" == *".sh" ]] && lang="bash"
  local cmdname="${name%.*}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app) make_app=1; shift;;
      --lang) lang="$2"; shift 2;;
      --dir) target_dir="$2"; shift 2;;
      *) shift;;
    esac
  done

  if [[ $make_app -eq 1 ]]; then
    # App scaffold
    local appdir="$target_dir/$cmdname"
    mkdir -p "$appdir/bin" "$appdir/src"
    echo "0.1.0" > "$appdir/VERSION"
    if [[ "$lang" == "bash" ]]; then
      cat > "$appdir/bin/$cmdname" <<'BASH'
#!/usr/bin/env bash
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from __APPNAME__ v$VERSION"
BASH
      sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
    else
      cat > "$appdir/bin/$cmdname" <<'PY'
#!/usr/bin/env python3
__version__ = "0.1.0"

def main():
    print(f"Hello from __APPNAME__ v{__version__}")
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
PY
      sed -i "s/__APPNAME__/$cmdname/g" "$appdir/bin/$cmdname"
    fi
    chmod +x "$appdir/bin/$cmdname"
    ok "App scaffolded: $appdir"
  else
    # Single-file scaffold
    mkdir -p "$target_dir"
    if [[ "$lang" == "bash" ]]; then
      [[ "$name" != *.sh ]] && name="${name}.sh"
      cat > "$target_dir/$name" <<'BASH'
#!/usr/bin/env bash
VERSION="0.1.0"
set -Eeuo pipefail
echo "Hello from __SCRIPTNAME__ v$VERSION"
BASH
      sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
    else
      [[ "$name" != *.py ]] && name="${name}.py"
      cat > "$target_dir/$name" <<'PY'
#!/usr/bin/env python3
__version__ = "0.1.0"

def main():
    print(f"Hello from __SCRIPTNAME__ v{__version__}")
    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
PY
      sed -i "s/__SCRIPTNAME__/$cmdname/g" "$target_dir/$name"
    fi
    chmod +x "$target_dir/$name"
    ok "Script scaffolded: $target_dir/$name"
  fi
}

# ---- Wizard (interactive project creator) ----
new_wizard(){
  say ""
  ok "🧙  BinMan Project Wizard"
  say "Press Enter to accept [brackets] defaults."

  # Name
  local name
  read -rp "Project name (no spaces) [MyTool]: " name
  name=${name:-MyTool}

  # Single vs App
  local kind
  read -rp "Type: (s)ingle-file or (a)pp? [a]: " kind
  kind=${kind:-a}
  [[ "${kind,,}" =~ ^s ]] && kind="single" || kind="app"

  # Language
  local lang
  read -rp "Language: (b)ash or (p)ython? [b]: " lang
  lang=${lang:-b}
  [[ "${lang,,}" =~ ^p ]] && lang="python" || lang="bash"

  # Target directory
  local target_dir="$PWD" _td
  read -rp "Create in directory [${target_dir}]: " _td
  [[ -n "$_td" ]] && target_dir="$_td"
  mkdir -p "$target_dir"

  # Description + Author
  local desc author
  read -rp "Short description [A neat little tool]: " desc
  desc=${desc:-A neat little tool}
  read -rp "Author [${USER}]: " author
  author=${author:-$USER}

  # Generate via new_cmd
  say ""; ok "Generating…"
  local filename path
  if [[ "$kind" == "single" ]]; then
    filename="$name"
    [[ "$lang" == "bash" ]] && [[ "$filename" != *.sh ]] && filename="${filename}.sh"
    [[ "$lang" == "python" ]] && [[ "$filename" != *.py ]] && filename="${filename}.py"
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
    ok "README.md created"
  else
    new_cmd "$name" --app --lang "$lang" --dir "$target_dir"
    path="${target_dir}/${name}"

    # README
    cat > "${path}/README.md" <<EOF
# ${name}

${desc}

Author: ${author}

## Layout

\`\`\`
${name}/
├─ bin/${name}    # entrypoint
├─ src/           # your modules
└─ VERSION
\`\`\`

## Run

\`\`\`
${name} [args]
\`\`\`
EOF
    ok "README.md created"
  fi

  # Install now?
  say ""
  local install_now="y" link_mode="n"
  read -rp "Install now? (y/N) [y]: " install_now
  install_now=${install_now:-y}
  if [[ "${install_now,,}" == "y" ]]; then
    read -rp "Use symlink instead of copy? (y/N) [n]: " link_mode
    link_mode=${link_mode:-n}
    local saved_mode="$COPY_MODE"
    [[ "${link_mode,,}" == "y" ]] && COPY_MODE="link" || COPY_MODE="copy"
    op_install "$path"
    COPY_MODE="$saved_mode"
  fi

  # Git init with gitprep?
  say ""
  local do_git="n"
  read -rp "Initialize a git repo here with gitprep? (y/N) [n]: " do_git
  do_git=${do_git:-n}
  if [[ "${do_git,,}" == "y" ]]; then
    if exists gitprep; then
      local gp_branch="main" gp_remote="" gp_push="n"
      read -rp "Default branch name [main]: " gp_branch; gp_branch=${gp_branch:-main}
      read -rp "Remote (git@... or https://...) [blank to skip]: " gp_remote
      read -rp "Push after setup? (y/N) [n]: " gp_push; gp_push=${gp_push:-n}

      if [[ -d "$path" && -d "$path/.git" ]]; then
        warn "Looks like a repo already exists in $path; skipping gitprep."
      else
        (
          # cd into the project root
          if [[ "$kind" == "app" ]]; then cd "$path"; else cd "$target_dir"; fi
          if [[ -n "$gp_remote" && "${gp_push,,}" == "y" ]]; then
            gitprep --branch "$gp_branch" --remote "$gp_remote" --push
          elif [[ -n "$gp_remote" ]]; then
            gitprep --branch "$gp_branch" --remote "$gp_remote"
          else
            gitprep --branch "$gp_branch"
          fi
        )
      fi
    else
      warn "gitprep not found; skipping git init (install with: binman install gitprep.sh)"
    fi
  fi

  ok "Wizard complete. Happy hacking, ${author}! ✨"
}

# ---- Banner ----
print_banner(){
  tput clear || clear
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
  printf "   v%s\n\nHome: %s\nApps: %s\n\n" "$VERSION" "$BIN_DIR" "$APP_STORE"
}

# ---- TUI ----
binman_tui(){
  while :; do
    print_banner
    echo "1) Install  2) Uninstall  3) List  4) Doctor  5) New  6) Wizard  q) Quit"
    read -rp "Choice: " c
    case "$c" in
      1) read -rp "File/dir: " f; op_install "$f"; read -rp "Enter...";;
      2) read -rp "Name: " n; op_uninstall "$n"; read -rp "Enter...";;
      3) op_list; read -rp "Enter...";;
      4) op_doctor; read -rp "Enter...";;
      5) read -rp "Name: " n; new_cmd "$n"; read -rp "Enter...";;
      6) new_wizard; read -rp "Enter...";;
      q|Q) exit 0;;
      *) warn "Unknown choice: $c"; sleep 0.7;;
    esac
  done
}

# ---- Main ----
ACTION="${1:-}"; shift || true
case "$ACTION" in
  install) op_install "$@";;
  uninstall) op_uninstall "$@";;
  list) op_list;;
  doctor) op_doctor;;
  update) op_update "$@";;
  new) new_cmd "$@";;
  wizard) new_wizard;;
  tui|"") binman_tui;;
  version) say "${SCRIPT_NAME} v${VERSION}";;
  help|*) usage;;
esac
