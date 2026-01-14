#!/usr/bin/env bash
# checksum — hash or verify a file
# Usage:
#   checksum <file>                      # prints sha256(file)
#   checksum <file> <expected-checksum>  # verifies against expected
#   checksum <file> <checksumfile>       # verifies using entry in checksum file
#
# Examples:
#   checksum archlinux.iso
#   checksum archlinux.iso e3b0...b855
#   checksum archlinux.iso SHA256:e3b0...b855
#   checksum archlinux.iso "e3b0...b855  archlinux.iso"   # pasted from website/file
#   checksum bazzite.iso bazzite.iso-CHECKSUM             # checksum file downloaded alongside ISO
#
VERSION="0.2.0"
set -Eeuo pipefail

die() { echo "checksum: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

usage() {
  cat <<EOF
checksum v$VERSION
Usage:
  checksum <file>
  checksum <file> <expected-checksum>
  checksum <file> <checksumfile>

Notes:
  - Default hash for printing is SHA-256.
  - Verification auto-detects algorithm from checksum length:
      32=MD5, 40=SHA1, 64=SHA256, 128=SHA512
  - You can also prefix expected with algo, e.g. sha256:<hash>
  - For checksum files, supports common formats:
      GNU:  <hash>  <filename>   or <hash> *<filename>
      BSD:  SHA256 (filename) = <hash>

Exit codes:
  0 = match / success
  1 = mismatch
  2 = usage / error
EOF
}

normalize_expected() {
  # Takes a string which may contain algo prefix and/or filename.
  # Outputs: "<algo> <hash>"
  local raw="$1"
  raw="${raw//$'\r'/}"          # drop CR if copied from Windows site
  raw="$(echo "$raw" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"  # trim + squeeze

  # If it looks like "algo:hash" (sha256:..., SHA256:..., md5:...)
  local prefix=""
  if [[ "$raw" =~ ^([A-Za-z0-9_-]+):([A-Fa-f0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    raw="${BASH_REMATCH[2]}"
  else
    # If pasted like "HASH filename" or "HASH  *filename", grab first token if it's hex
    local first="${raw%% *}"
    if [[ "$first" =~ ^[A-Fa-f0-9]+$ ]]; then
      raw="$first"
    fi
  fi

  # Decide algo
  local len="${#raw}"
  local algo=""
  case "$len" in
    32)  algo="md5" ;;
    40)  algo="sha1" ;;
    64)  algo="sha256" ;;
    128) algo="sha512" ;;
    *)   algo="" ;;
  esac

  # If prefix provided, honor it (normalize)
  if [[ -n "$prefix" ]]; then
    prefix="$(echo "$prefix" | tr '[:upper:]' '[:lower:]')"
    case "$prefix" in
      md5|sha1|sha256|sha512) algo="$prefix" ;;
      *) die "unknown checksum prefix '$prefix' (use md5/sha1/sha256/sha512)" ;;
    esac
  fi

  [[ -n "$algo" ]] || die "could not detect algorithm from checksum length ($len). Try prefix like sha256:<hash>"

  # Ensure tool exists
  need "${algo}sum"

  # Output normalized algo + lowercase hash
  echo "$algo $(echo "$raw" | tr '[:upper:]' '[:lower:]')"
}

hash_file() {
  local algo="$1"
  local file="$2"
  need "${algo}sum"
  "${algo}sum" -- "$file" | awk '{print $1}'
}

is_checksum_string() {
  # Returns 0 if arg looks like a checksum (or algo:checksum), else 1
  local s="$1"
  s="${s//$'\r'/}"
  s="$(echo "$s" | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//')"

  # algo:hash
  if [[ "$s" =~ ^([A-Za-z0-9_-]+):([A-Fa-f0-9]+)$ ]]; then
    return 0
  fi

  # allow "HASH filename" (grab first token)
  local first="${s%% *}"
  [[ "$first" =~ ^[A-Fa-f0-9]+$ ]] || return 1

  case "${#first}" in
    32|40|64|128) return 0 ;;
    *) return 1 ;;
  esac
}

expected_from_checksum_file() {
  # Extract expected checksum for target file from a checksum file.
  # Outputs: "<algo> <hash>"
  local target="$1"
  local sumfile="$2"
  local base
  base="$(basename -- "$target")"

  [[ -f "$sumfile" ]] || return 1

  local line hash algo

  # 1) GNU style: "<hash>  <filename>" or "<hash> *<filename>"
  # Match basename at end of line (most common for downloads)
  line="$(grep -E "^[A-Fa-f0-9]{32,128}[[:space:]]+\*?${base//./\\.}$" "$sumfile" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    hash="$(echo "$line" | awk '{print $1}')"
    hash="$(echo "$hash" | tr '[:upper:]' '[:lower:]')"
    case "${#hash}" in
      32)  echo "md5 $hash" ;;
      40)  echo "sha1 $hash" ;;
      64)  echo "sha256 $hash" ;;
      128) echo "sha512 $hash" ;;
      *)   return 1 ;;
    esac
    return 0
  fi

  # 2) BSD style: "SHA256 (filename) = <hash>"
  line="$(grep -E "^[A-Za-z0-9_-]+[[:space:]]*\\(${base//./\\.}\\)[[:space:]]*=[[:space:]]*[A-Fa-f0-9]{32,128}" "$sumfile" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    algo="$(echo "$line" | sed -E 's/^([A-Za-z0-9_-]+).*/\1/' | tr '[:upper:]' '[:lower:]')"
    hash="$(echo "$line" | sed -E 's/.*=[[:space:]]*([A-Fa-f0-9]+).*/\1/' | tr '[:upper:]' '[:lower:]')"
    case "$algo" in
      md5|sha1|sha256|sha512) ;;
      *) return 1 ;;
    esac
    echo "$algo $hash"
    return 0
  fi

  # 3) Fallback: if the checksum file contains a single raw hash, accept it
  local only
  only="$(grep -Eo '^[A-Fa-f0-9]{32,128}$' "$sumfile" | head -n1 || true)"
  if [[ -n "$only" ]]; then
    only="$(echo "$only" | tr '[:upper:]' '[:lower:]')"
    case "${#only}" in
      32)  echo "md5 $only" ;;
      40)  echo "sha1 $only" ;;
      64)  echo "sha256 $only" ;;
      128) echo "sha512 $only" ;;
      *)   return 1 ;;
    esac
    return 0
  fi

  return 1
}

main() {
  [[ "${1:-}" != "" ]] || { usage; exit 2; }
  [[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }

  local file="$1"
  [[ -f "$file" ]] || die "file not found: $file"

  # Print mode
  if [[ "${2:-}" == "" ]]; then
    local h
    h="$(hash_file sha256 "$file")"
    echo "$h  $file"
    exit 0
  fi

  # Verify mode (string OR checksum file)
  local arg2="$2"
  local expected_raw="$2"

  # If they passed more than 2 args, treat it as one expected string (handles spaces)
  if (( $# > 2 )); then
    expected_raw="$*"
    expected_raw="${expected_raw#"$file "}"  # strip leading "<file> "
    arg2="$expected_raw"
  fi

  local parsed algo expected
  if [[ -f "$arg2" ]]; then
    parsed="$(expected_from_checksum_file "$file" "$arg2")" \
      || die "could not find a matching checksum for '$(basename -- "$file")' in '$arg2'"
  else
    is_checksum_string "$expected_raw" || die "second argument is neither a checksum nor a file: $expected_raw"
    parsed="$(normalize_expected "$expected_raw")"
  fi

  algo="${parsed%% *}"
  expected="${parsed#* }"

  local actual
  actual="$(hash_file "$algo" "$file")"

  if [[ "$actual" == "$expected" ]]; then
    echo "$file: OK ($algo)"
    exit 0
  else
    echo "$file: FAIL ($algo)" >&2
    echo " expected: $expected" >&2
    echo "   actual: $actual" >&2
    exit 1
  fi
}

main "$@"
