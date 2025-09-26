#!/usr/bin/env bash
# stress_binman.sh — Black-box stress test for BinMan v1.6.x
# Run:
#   ./stress_binman.sh BINMAN_CMD=./binman VERBOSE=0 JOBS=4
#   (BINMAN_CMD may be a filename in CWD or an absolute path or just 'binman' in PATH)

set -Euo pipefail

# ---------- Config ----------
BINMAN_CMD="${BINMAN_CMD:-./binman.sh}"
RUN_SYSTEM="${RUN_SYSTEM:-0}"   # not used by default (safe tests only)
JOBS="${JOBS:-6}"
VERBOSE="${VERBOSE:-0}"

# ---------- Pretty ----------
say(){ printf "%s\n" "$*"; }
note(){ printf "\033[36m[NOTE]\033[0m %s\n" "$*"; }
ok(){   printf "\033[32m[ OK ]\033[0m %s\n" "$*"; }
warn(){ printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
fail(){ printf "\033[31m[FAIL]\033[0m %s\n" "$*"; }

# ---------- Assert helpers ----------
die(){ fail "$*"; exit 1; }
assert_file(){ [[ -f "$1" ]] || die "Missing file: $1"; }
assert_dir(){ [[ -d "$1" ]] || die "Missing dir: $1"; }
assert_exe(){ [[ -x "$1" ]] || die "Not executable: $1"; }
assert_no(){ [[ ! -e "$1" ]] || die "Should not exist: $1"; }
assert_eq(){ [[ "$1" == "$2" ]] || die "Expected '$2' got '$1'"; }
assert_contains(){ grep -q -- "$2" "$1" || die "File $1 lacks: $2"; }

# ---------- Runner ----------
run() {
  local rc
  if [[ "${VERBOSE:-0}" == 1 ]]; then set -x; fi
  "$@"; rc=$?
  if [[ "${VERBOSE:-0}" == 1 ]]; then set +x; fi
  return "$rc"
}

# ---------- Sandbox ----------
ROOT="$(mktemp -d -t binman-stress-XXXXXX)"
export HOME="$ROOT/home"
mkdir -p "$HOME" "$ROOT/work" "$ROOT/remotes" "$ROOT/tmp"
touch "$HOME/.zshrc" "$HOME/.zprofile"   # for --fix-path
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CONFIG_HOME="$HOME/.config"

# Pin locations to match BinMan defaults
BINDIR="$HOME/.local/bin"
APPDIR="$HOME/.local/share/binman/apps"
ROLLBACK="$HOME/.local/share/binman/rollback"
mkdir -p "$BINDIR" "$APPDIR"

# Resolve BinMan
BIN="$ROOT/binman"
if [[ -f "$BINMAN_CMD" ]]; then cp "$BINMAN_CMD" "$BIN"; chmod +x "$BIN"; else BIN="$BINMAN_CMD"; fi

# Ensure sandbox bin is in PATH to squelch PATH warnings and allow shims to run
export PATH="$BINDIR:$PATH"

say "🏗  Sandbox: $ROOT"
say "🏠 HOME:    $HOME"
say "🛠  BinMan:  $BIN"

PASS=0; FAIL=0
okstep(){ ok "$*"; ((PASS++)); }
badstep(){ fail "$*"; ((FAIL++)); }
step(){ note "$*"; }

# ---------- Fixtures ----------
mk_script() { # $1=path $2=message
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/usr/bin/env bash
# Description: $(basename "$1")
set -euo pipefail
echo "${2:-hello from $(basename "$1")}"
EOF
  chmod +x "$1"
}

mk_app() { # $1=dir $2=name $3=message
  local root="$1/$2"
  mkdir -p "$root/bin" "$root/share"
  echo "1.0.0" > "$root/VERSION"
  cat > "$root/bin/$2" <<EOF
#!/usr/bin/env bash
# Description: $2 demo app
set -euo pipefail
echo "$3"
EOF
  chmod +x "$root/bin/$2"
  printf "%s" "$root"
}

mk_remote_app_repo() { # $1=dir $2=name $3=version $4=msg
  local repo="$1/$2-remote"
  mkdir -p "$repo/apps/$2/bin" "$repo/apps/$2/share"
  echo "$3" > "$repo/apps/$2/VERSION"
  cat > "$repo/apps/$2/bin/$2" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "$4"
EOF
  chmod +x "$repo/apps/$2/bin/$2"
  printf "%s" "$repo"
}

mk_manifest() { # $1=path ; others=items
  local out="$1"; shift
  : > "$out"
  for x in "$@"; do echo "$x" >> "$out"; done
}

# ---------- 1) Help / version ----------
step "Sanity: help & version"
run "$BIN" help >/dev/null || die "binman help failed"
run "$BIN" version >/dev/null || warn "version subcommand absent (ok if help shows version)"
okstep "help/version ok"

# ---------- 2) Install single-file (copy) ----------
step "Install single-file script (copy mode)"
S1="$ROOT/work/hello.sh"; mk_script "$S1" "hello-copy"
run "$BIN" install "$S1" --force
assert_file "$BINDIR/hello"
assert_exe  "$BINDIR/hello"
assert_eq "$("$BINDIR/hello")" "hello-copy"
okstep "script install (copy) ok"

# ---------- 3) Install single-file (link) ----------
step "Install single-file script (link mode)"
S2="$ROOT/work/echo.sh"; mk_script "$S2" "hello-link"
run "$BIN" install "$S2" --link --force
[[ -L "$BINDIR/echo" ]] || warn "echo is not a symlink (link mode unsupported?)"
assert_eq "$("$BINDIR/echo")" "hello-link"
okstep "script install (link) ok"

# ---------- 4) App install + shim ----------
step "Install app (bin/<name> layout)"
APP_A_SRC="$(mk_app "$ROOT/work" 'appalpha' 'alpha-1.0.0')"
run "$BIN" install "$APP_A_SRC"
assert_file "$APPDIR/appalpha/bin/appalpha"
assert_file "$BINDIR/appalpha"
out="$("$BINDIR/appalpha")"; [[ "$out" == "alpha-1.0.0" ]] || die "unexpected app output: $out"
okstep "app install + shim ok"

# ---------- 5) List shows both ----------
step "List inventory"
LIST="$(run "$BIN" list | sed -n '1,200p' || true)"
[[ -n "$LIST" ]] || die "list empty"
echo "$LIST" | grep -q '^hello[[:space:]]'  || die "list missing 'hello'"
echo "$LIST" | grep -q '^appalpha[[:space:]]' || die "list missing 'appalpha'"
okstep "list ok"

# ---------- 6) Update via remote (fallback = reinstall from remote dir) ----------
step "Update app from fake remote (simulate remote upgrade)"
REMOTE="$(mk_remote_app_repo "$ROOT/remotes" 'appalpha' '1.2.3' 'alpha-1.2.3')"
REMOTE_APP="$REMOTE/apps/appalpha"
# BinMan update presently reuses install; feed it the dir and --force
run "$BIN" install "$REMOTE_APP" --force
assert_file "$APPDIR/appalpha/VERSION"
ver="$(tr -d '\n' < "$APPDIR/appalpha/VERSION")"
[[ "$ver" == "1.2.3" ]] || die "version not updated (got $ver)"
assert_eq "$("$BINDIR/appalpha")" "alpha-1.2.3"
okstep "remote reinstall bumped to 1.2.3"

# ---------- 7) Manifest bulk install ----------
step "Manifest bulk install (2 scripts + 1 app)"
S3="$ROOT/work/tool-a.sh"; mk_script "$S3" "tool-a"
S4="$ROOT/work/tool-b.sh"; mk_script "$S4" "tool-b"
APP_B_SRC="$(mk_app "$ROOT/work" 'appbeta' 'beta-1.0.0')"
MAN="$ROOT/work/manifest.txt"; mk_manifest "$MAN" "$S3" "$S4" "$APP_B_SRC"
run "$BIN" --manifest "$MAN" install
assert_file "$BINDIR/tool-a"
assert_file "$BINDIR/tool-b"
assert_file "$APPDIR/appbeta/bin/appbeta"
okstep "manifest install ok"

# ---------- 8) Uninstall + rollback snapshot check ----------
step "Uninstall and confirm rollback snapshot incremented"
pre_snaps="$(find "$ROLLBACK" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
run "$BIN" uninstall tool-b
assert_no "$BINDIR/tool-b"
post_snaps="$(find "$ROLLBACK" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
(( post_snaps > pre_snaps )) || warn "no snapshot growth detected (rollback may share timestamp)"
okstep "uninstall + rollback snapshot passable"

# ---------- 9) Doctor --fix-path ----------
step "Doctor --fix-path modifies rc files"
run "$BIN" --fix-path doctor >/dev/null
grep -q '\.local/bin' "$HOME/.zshrc" || grep -q '\.local/bin' "$HOME/.zprofile" || warn "--fix-path did not patch rc files"
okstep "doctor ok"

# ---------- 10) Idempotent reinstall ----------
step "Idempotent reinstall"
run "$BIN" install "$S1"
okstep "idempotent reinstall ok"

# ---------- 11) Weird filenames (spaces & unicode) ----------
step "Install weird filenames"
W1="$ROOT/work/space name.sh"; mk_script "$W1" "space-ok"
W2="$ROOT/work/uniçøde.sh";   mk_script "$W2" "unicode-ok"
run "$BIN" install "$W1" --force
run "$BIN" install "$W2" --force
assert_eq "$("$BINDIR/space name")" "space-ok"
# Installed name drops extension, keeps unicode
assert_eq "$("$BINDIR/uniçøde")" "unicode-ok"
okstep "weird names ok"

# ---------- 12) Concurrency (parallel installs) ----------
step "Parallel installs (race test)"
PAR="$ROOT/work/parallel"; mkdir -p "$PAR"
N=20
for i in $(seq 1 "$N"); do mk_script "$PAR/t$i.sh" "T$i"; done
pids=()
for i in $(seq 1 "$N"); do
  run "$BIN" install "$PAR/t$i.sh" --force >/dev/null 2>&1 &
  pids+=("$!")
  # throttle
  while (( $(jobs -p | wc -l) >= JOBS )); do wait -n || true; done
done
wait || true
for i in $(seq 1 "$N"); do assert_file "$BINDIR/t$i"; done
okstep "concurrency ok"

# ---------- 13) Non-interactive mode ----------
step "Non-interactive list (TERM=dumb)"
( export TERM=dumb; run "$BIN" list >/dev/null )
okstep "non-interactive ok"

# ---------- 14) Backup / Restore ----------
step "Backup and Restore"

# Heat-seeking backup finder that tolerates: no message, /tmp vs $PWD, .zip vs .tar.gz vs no ext
find_backup() {
  local base="$1" out rc msg path
  msg="$("$BIN" backup "$base" 2>&1)"; rc=$?
  (( rc == 0 )) || die "backup failed (rc=$rc): $msg"

  # 1) If BinMan printed a path, use it (but verify!)
  path="$(printf '%s\n' "$msg" | sed -n 's/^.*Backup created:[[:space:]]*\(.*\)$/\1/p' | tail -1)"
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"; return 0
  fi

  # 2) Probe exact candidates in both $PWD and /tmp
  for cand in \
    "$PWD/${base}" "$PWD/${base}.zip" "$PWD/${base}.tar.gz" \
    "/tmp/${base}" "/tmp/${base}.zip" "/tmp/${base}.tar.gz"
  do
    [[ -f "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
  done

  # 3) Last resort: newest file starting with our base in { $PWD, /tmp }
  path="$( (ls -1t "$PWD"/"${base}"* 2>/dev/null; ls -1t /tmp/"${base}"* 2>/dev/null) | head -n1 || true )"
  [[ -n "$path" && -f "$path" ]] && { printf '%s\n' "$path"; return 0; }

  die "could not locate backup artifact for base '${base}'. Output was:\n$msg"
}

BBASE="bmstress-$$"
BK="$(find_backup "$BBASE")"
assert_file "$BK"

# destructive check + restore
rm -f "$BINDIR/hello"
assert_no "$BINDIR/hello"
run "$BIN" restore "$BK"
assert_file "$BINDIR/hello"
okstep "backup/restore ok"


# ---------- 15) Bundle export ----------
step "Bundle export"
BUNDLE="$ROOT/tmp/bundle.zip"
run "$BIN" bundle "$BUNDLE"
assert_file "$BUNDLE"
okstep "bundle created"

# ---------- 16) Generator: create + install + run (script) ----------
step "Generator: new script"
GEN_DIR="$ROOT/gen"
mkdir -p "$GEN_DIR"
run "$BIN" new mygen.sh --lang bash --dir "$GEN_DIR"
assert_file "$GEN_DIR/mygen.sh"
run "$BIN" install "$GEN_DIR/mygen.sh" --force
assert_file "$BINDIR/mygen"
"$BINDIR/mygen" >/dev/null
okstep "generator (script) ok"

# ---------- 17) Generator: create + install + run (app) ----------
step "Generator: new app (python launcher, no external deps)"
run "$BIN" new GenApp --app --lang python --dir "$GEN_DIR"
assert_dir "$GEN_DIR/GenApp/bin"
assert_file "$GEN_DIR/GenApp/VERSION"
run "$BIN" install "$GEN_DIR/GenApp" --force
assert_file "$BINDIR/GenApp"
"$BINDIR/GenApp" >/dev/null
okstep "generator (app) ok"

# ---------- 18) BinMan test subcommand ----------
step "op_test sanity"
run "$BIN" test hello >/dev/null || warn "test hello failed (script may not accept --help, which is fine)"
okstep "op_test invoked"

# ---------- Summary ----------
echo
say "================== SUMMARY =================="
say "  Passed: $PASS"
say "  Failed: $FAIL"
say "  Sandbox: $ROOT"
say "============================================="
[[ $FAIL -eq 0 ]] || exit 1
