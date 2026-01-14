#!/usr/bin/env bash
# move — safe resumable move with progress (rsync + verify + remove)
# Usage: move [--dry-run|-n] SRC... DEST
VERSION="0.2.0"
set -Eeuo pipefail

die() { echo "move: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need rsync

DRY_RUN=0
ARGS=()

while (( $# )); do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      cat <<EOF
move v$VERSION
Usage: move [--dry-run|-n] SRC... DEST

Moves using rsync (resume + progress), verifies via checksum dry-run,
then deletes source on success.
EOF
      exit 0
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# Add any remaining args after --
if (( $# )); then
  ARGS+=("$@")
fi

(( ${#ARGS[@]} >= 2 )) || die "Usage: move [--dry-run|-n] SRC... DEST"

DEST="${ARGS[-1]}"
SRCS=("${ARGS[@]:0:${#ARGS[@]}-1}")

if (( ${#SRCS[@]} > 1 )) && [[ ! -d "$DEST" ]]; then
  die "DEST must be a directory when moving multiple sources"
fi

# Ensure destination exists appropriately
if [[ -d "$DEST" ]]; then
  mkdir -p -- "$DEST"
else
  mkdir -p -- "$(dirname -- "$DEST")"
fi

copy_args=(
  -aHAX
  --partial
  --inplace
  --human-readable
  --info=progress2
)

verify_args=(
  -aHAX
  --checksum
  --dry-run
  --itemize-changes
  --out-format='%i %n%L'
  --quiet
)

for SRC in "${SRCS[@]}"; do
  # 1) Transfer with resume + progress
  if (( DRY_RUN )); then
    rsync "${copy_args[@]}" --dry-run -- "$SRC" "$DEST"
  else
    rsync "${copy_args[@]}" -- "$SRC" "$DEST"
  fi

  # 2) Verify (only checks "is SRC present at DEST", does NOT care about extra files already in DEST)
  #    If rsync reports any changes would occur, verification failed.
  diffout="$(rsync "${verify_args[@]}" -- "$SRC" "$DEST" || true)"
  if [[ -n "$diffout" ]]; then
    echo "move: verification failed for '$SRC' → '$DEST' (not deleting source)" >&2
    echo "$diffout" >&2
    exit 3
  fi

  # 3) Remove original (skip if dry-run)
  if (( DRY_RUN )); then
    echo "move: (dry-run) would delete: $SRC" >&2
    continue
  fi

  if [[ -d "$SRC" && ! -L "$SRC" ]]; then
    rm -rf --one-file-system -- "$SRC"
  else
    rm -f -- "$SRC"
  fi
done
