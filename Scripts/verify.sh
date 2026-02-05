#!/usr/bin/env bash
# Verify — checksum + virus scan in one command (+ watch mode)
#
# Usage:
#   verify <file|dir>
#   verify <file> <expected-checksum>
#   verify <file> <checksumfile>
#
# Watch mode (recursive by default; NEW files only):
#   verify --watch <dir> [--verbose]
#
# Exit codes (normal mode):
#   0 = checksum OK (if verified) AND scan clean
#   1 = checksum mismatch OR infected
#   2 = usage / error
#   3 = scan error (scanner failed)
#   4 = no checksum available to verify (scan still ran)

VERSION="0.5.1"
set -Eeuo pipefail

PROG="verify"

die() { echo "$PROG: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }
blank() { printf '\n'; }

usage() {
  cat <<EOF
Verify v$VERSION
Usage:
  verify <file|dir>
  verify <file> <expected-checksum>
  verify <file> <checksumfile>

Watch mode (recursive by default; new files only):
  verify --watch <dir> [--verbose]

Notes:
  - Directories: checksum verification is skipped (scan still runs).
  - Watch mode prints a "Watching:" header once, then per-item blocks.
  - Watch mode ignores checksum manifests and common temp download files.
EOF
}

need_hash_tool() { need "${1}sum"; }

hash_file() {
  local algo="$1" path="$2"
  need_hash_tool "$algo"
  "${algo}sum" -- "$path" | awk '{print $1}'
}

is_temp_download_name() {
  case "$1" in
    *.part|*.partial|*.tmp|*.crdownload|*.download) return 0 ;;
    *) return 1 ;;
  esac
}

is_checksum_manifest_name() {
  case "$1" in
    *.CHECKSUM|*.checksum|*CHECKSUMS*|*SHA256SUMS*|*.sha256|*.sha256sum|*.SHA256|*.SHA256SUMS) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_settle() {
  local f="$1"
  local tries=90 last=-1 cur=0
  for ((i=0; i<tries; i++)); do
    [[ -f "$f" ]] || return 1
    cur="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
    if [[ "$cur" == "$last" && "$cur" -gt 0 ]]; then
      return 0
    fi
    last="$cur"
    sleep 1
  done
  return 0
}

is_checksum_string() {
  local s="$1"
  s="${s//$'\r'/}"
  s="$(echo "$s" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"
  [[ "$s" =~ ^([A-Za-z0-9_-]+):([A-Fa-f0-9]+)$ ]] && return 0
  local first="${s%% *}"
  [[ "$first" =~ ^[A-Fa-f0-9]+$ ]] || return 1
  case "${#first}" in 32|40|64|128) return 0 ;; *) return 1 ;; esac
}

normalize_expected() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  raw="$(echo "$raw" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"

  local prefix=""
  if [[ "$raw" =~ ^([A-Za-z0-9_-]+):([A-Fa-f0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"
  else
    local first="${raw%% *}"
    [[ "$first" =~ ^[A-Fa-f0-9]+$ ]] && raw="$first"
  fi

  local algo=""
  case "${#raw}" in
    32) algo="md5" ;;
    40) algo="sha1" ;;
    64) algo="sha256" ;;
    128) algo="sha512" ;;
    *) algo="" ;;
  esac

  if [[ -n "$prefix" ]]; then
    prefix="$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
    case "$prefix" in md5|sha1|sha256|sha512) algo="$prefix" ;; *) die "unknown checksum prefix '$prefix'" ;; esac
  fi

  [[ -n "$algo" ]] || die "could not detect algorithm from checksum length (${#raw})"
  need_hash_tool "$algo"
  echo "$algo $(echo "$raw" | tr '[:upper:]' '[:lower:]')"
}

expected_from_checksum_file() {
  local target="$1" sumfile="$2"
  local base base_re line hash algo
  base="$(basename -- "$target")"
  base_re="${base//./\\.}"
  [[ -f "$sumfile" ]] || return 1

  # GNU style, including full paths
  line="$(grep -E "^[A-Fa-f0-9]{32,128}[[:space:]]+\*?(.*/)?${base_re}$" "$sumfile" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    hash="$(echo "$line" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
    case "${#hash}" in
      32) echo "md5 $hash" ;;
      40) echo "sha1 $hash" ;;
      64) echo "sha256 $hash" ;;
      128) echo "sha512 $hash" ;;
      *) return 1 ;;
    esac
    return 0
  fi

  # BSD style
  line="$(grep -E "^[A-Za-z0-9_-]+[[:space:]]*\\(${base_re}\\)[[:space:]]*=[[:space:]]*[A-Fa-f0-9]{32,128}" "$sumfile" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    algo="$(echo "$line" | sed -E 's/^([A-Za-z0-9_-]+).*/\1/' | tr '[:upper:]' '[:lower:]')"
    hash="$(echo "$line" | sed -E 's/.*=[[:space:]]*([A-Fa-f0-9]+).*/\1/' | tr '[:upper:]' '[:lower:]')"
    case "$algo" in md5|sha1|sha256|sha512) ;; *) return 1 ;; esac
    echo "$algo $hash"
    return 0
  fi

  # Single raw hash fallback
  hash="$(grep -Eo '^[A-Fa-f0-9]{32,128}$' "$sumfile" | head -n1 || true)"
  if [[ -n "$hash" ]]; then
    hash="$(echo "$hash" | tr '[:upper:]' '[:lower:]')"
    case "${#hash}" in
      32) echo "md5 $hash" ;;
      40) echo "sha1 $hash" ;;
      64) echo "sha256 $hash" ;;
      128) echo "sha512 $hash" ;;
      *) return 1 ;;
    esac
    return 0
  fi

  return 1
}

auto_find_checksum_file() {
  # Prefer checksum files clearly related to this target, then fall back to generic.
  local target="$1"
  local dir base
  dir="$(dirname -- "$target")"
  base="$(basename -- "$target")"

  local candidates=(
    "$dir/${base}.CHECKSUM"
    "$dir/${base}.checksum"
    "$dir/${base}.sha256"
    "$dir/${base}.sha256sum"
    "$dir/${base}.SHA256"
    "$dir/${base}.SHA256SUMS"
  )
  local f
  for f in "${candidates[@]}"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done

  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -qF -- "$base" "$f" 2>/dev/null && { echo "$f"; return 0; }
  done < <(find "$dir" -maxdepth 1 -type f \
          \( -iname '*checksum*' -o -iname '*sha256*' -o -iname '*sums*' \) \
          -size -512k 2>/dev/null)

  local generic=(
    "$dir/CHECKSUM"
    "$dir/CHECKSUMS"
    "$dir/SHA256SUMS"
    "$dir/SHA256SUMS.txt"
    "$dir/SHA256SUMS.asc"
    "$dir/sha256sums"
    "$dir/sha256sums.txt"
  )
  for f in "${generic[@]}"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done

  return 1
}

run_virus_scan() {
  local path="$1"
  if command -v clamscan >/dev/null 2>&1; then
    if [[ -d "$path" ]]; then
      clamscan -r --infected --no-summary -- "$path"
      return $?
    else
      clamscan --infected --no-summary -- "$path"
      return $?
    fi
  fi
  return 0
}

# Globals for reporting
V_TARGET="" V_IS_DIR=0 V_VERIFIED=0 V_ALGO="" V_EXPECTED="" V_ACTUAL="" V_SUMFILE="" V_SCAN_RC=0

verify_core() {
  V_TARGET="$1"
  shift || true

  V_IS_DIR=0
  [[ -d "$V_TARGET" ]] && V_IS_DIR=1
  V_VERIFIED=0
  V_ALGO="" V_EXPECTED="" V_ACTUAL="" V_SUMFILE=""
  V_SCAN_RC=0

  [[ -e "$V_TARGET" ]] || return 2

  if (( V_IS_DIR )); then
    V_VERIFIED=0
  else
    if [[ "${1:-}" == "" ]]; then
      if V_SUMFILE="$(auto_find_checksum_file "$V_TARGET")"; then
        if parsed="$(expected_from_checksum_file "$V_TARGET" "$V_SUMFILE")"; then
          V_VERIFIED=1
          V_ALGO="${parsed%% *}"
          V_EXPECTED="${parsed#* }"
          V_ACTUAL="$(hash_file "$V_ALGO" "$V_TARGET")"
        fi
      fi
    else
      local arg2="$1"
      local expected_raw="$1"

      if (( $# > 1 )); then
        expected_raw="$*"
        expected_raw="${expected_raw#"$V_TARGET "}"
        arg2="$expected_raw"
      fi

      if [[ -f "$arg2" ]]; then
        V_SUMFILE="$arg2"
        parsed="$(expected_from_checksum_file "$V_TARGET" "$arg2")" || return 2
        V_VERIFIED=1
        V_ALGO="${parsed%% *}"
        V_EXPECTED="${parsed#* }"
        V_ACTUAL="$(hash_file "$V_ALGO" "$V_TARGET")"
      else
        is_checksum_string "$expected_raw" || return 2
        parsed="$(normalize_expected "$expected_raw")"
        V_VERIFIED=1
        V_ALGO="${parsed%% *}"
        V_EXPECTED="${parsed#* }"
        V_ACTUAL="$(hash_file "$V_ALGO" "$V_TARGET")"
      fi
    fi
  fi

  # --- FIXED: clamscan exit-code handling (works with set -e) ---
  if command -v clamscan >/dev/null 2>&1; then
    local rc=0
    run_virus_scan "$V_TARGET" || rc=$?
    case "$rc" in
      0) V_SCAN_RC=0 ;;  # clean
      1) V_SCAN_RC=1 ;;  # infected
      2) V_SCAN_RC=2 ;;  # scan error
      *) V_SCAN_RC=2 ;;  # unknown -> error
    esac
  fi
  # ------------------------------------------------------------

  if (( V_VERIFIED == 1 )) && [[ "$V_ACTUAL" != "$V_EXPECTED" ]]; then
    return 1
  fi
  if [[ $V_SCAN_RC -eq 1 ]]; then
    return 1
  elif [[ $V_SCAN_RC -eq 2 ]]; then
    return 3
  fi
  if (( V_IS_DIR == 0 )) && (( V_VERIFIED == 0 )); then
    return 4
  fi
  return 0
}

result_line() {
  local rc="$1"
  case "$rc" in
    0) echo "$PROG: RESULT: ✅ clean" ;;
    1)
      if (( V_VERIFIED == 1 )) && [[ "$V_ACTUAL" != "$V_EXPECTED" ]]; then
        echo "$PROG: RESULT: ❌ checksum mismatch"
      else
        echo "$PROG: RESULT: ❌ infected"
      fi
      ;;
    3) echo "$PROG: RESULT: ⚠️ scan error" ;;
    4) echo "$PROG: RESULT: ⚠️ scan clean, checksum not verified" ;;
    *) echo "$PROG: RESULT: ⚠️ error" ;;
  esac
}

print_watch_block() {
  local rc="$1"
  hr
  echo "Checking: $(basename -- "$V_TARGET")"
  blank

  if (( V_IS_DIR )); then
    echo "$PROG: checksum: skipped (directory)"
    blank
  else
    if (( V_VERIFIED == 1 )); then
      if [[ -n "$V_SUMFILE" ]]; then
        echo "$PROG: found checksum file:"
        echo "  $V_SUMFILE"
        blank
      fi
      echo "$PROG: checksum ($V_ALGO):"
      echo "  expected: $V_EXPECTED"
      echo "    actual: $V_ACTUAL"
      blank
      if [[ "$V_ACTUAL" == "$V_EXPECTED" ]]; then
        echo "$PROG: checksum: OK"
      else
        echo "$PROG: checksum: FAIL" >&2
      fi
      blank
    else
      echo "$PROG: no checksum to verify — sha256 for manual compare:"
      echo "  $(hash_file sha256 "$V_TARGET")"
      blank
    fi
  fi

  if command -v clamscan >/dev/null 2>&1; then
    case "$V_SCAN_RC" in
      0) echo "Virus Scan: CLEAN" ;;
      1) echo "Virus Scan: INFECTED" >&2 ;;
      2) echo "Virus Scan: ERROR" >&2 ;;
    esac
  else
    echo "Virus Scan: SKIPPED (clamscan not found)" >&2
  fi

  hr
  echo "$(result_line "$rc")"
  hr
  blank
  hr
  blank
}

print_full_report() {
  local rc="$1"
  blank
  hr
  echo "Verify v$VERSION"
  echo "Target: $V_TARGET"
  hr
  blank
  print_watch_block "$rc"
}

# --- Watch event dedupe ---
DEDUP_WINDOW=2
declare -A _DEDUP_LAST=()

dedupe_should_skip() {
  local path="$1"
  local now last
  now="$(date +%s)"
  last="${_DEDUP_LAST[$path]:-0}"
  if (( now - last < DEDUP_WINDOW )); then
    return 0
  fi
  _DEDUP_LAST["$path"]="$now"
  return 1
}

verify_once_watch() {
  local path="$1" verbose="$2"

  [[ -e "$path" ]] || return 0
  is_temp_download_name "$path" && return 0
  is_checksum_manifest_name "$path" && return 0
  dedupe_should_skip "$path" && return 0

  if [[ -f "$path" ]]; then
    wait_for_settle "$path" || true
  fi

  if verify_core "$path"; then rc=0; else rc=$?; fi

  if [[ "$verbose" == "1" ]]; then
    print_full_report "$rc"
  else
    print_watch_block "$rc"
  fi
}

watch_header() {
  local dir="$1"
  hr
  echo "Verify v$VERSION"
  echo "Watching: $dir"
  hr
  blank
}

watch_inotify() {
  local dir="$1" verbose="$2"
  watch_header "$dir"

  inotifywait -m -r -e create -e moved_to -e close_write --format '%w%f' -- "$dir" 2>/dev/null |
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    verify_once_watch "$path" "$verbose"
  done
}

watch_polling() {
  local dir="$1" verbose="$2"
  watch_header "$dir"

  # Prime: mark all existing paths as seen so we ONLY process new ones.
  declare -A seen=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    seen["$p"]=1
  done < <(find "$dir" -mindepth 1 -print 2>/dev/null)

  while true; do
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      [[ -e "$p" ]] || continue
      if [[ -z "${seen[$p]+x}" ]]; then
        seen["$p"]=1
        verify_once_watch "$p" "$verbose"
      fi
    done < <(find "$dir" -mindepth 1 -print 2>/dev/null)
    sleep 2
  done
}

main() {
  [[ "${1:-}" != "" ]] || { usage; exit 2; }
  [[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }

  if [[ "${1:-}" == "--watch" ]]; then
    dir="${2:-}"
    [[ -n "$dir" ]] || die "missing directory for --watch"
    [[ -d "$dir" ]] || die "not a directory: $dir"
    verbose=0
    [[ "${3:-}" == "--verbose" ]] && verbose=1

    if command -v inotifywait >/dev/null 2>&1; then
      watch_inotify "$dir" "$verbose"
    else
      watch_polling "$dir" "$verbose"
    fi
    exit 0
  fi

  target="$1"
  [[ -e "$target" ]] || die "path not found: $target"

  if verify_core "$@"; then rc=0; else rc=$?; fi
  print_full_report "$rc"
  exit "$rc"
}

main "$@"
