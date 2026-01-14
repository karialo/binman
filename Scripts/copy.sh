#!/usr/bin/env bash
# copy — resumable copy with progress (files or directories)
# Usage: copy [--dry-run|-n] SRC... DEST
VERSION="0.2.0"
set -Eeuo pipefail

die() { echo "copy: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need rsync

DRY_RUN=0
ARGS=()

while (( $# )); do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      cat <<EOF
copy v$VERSION
Usage: copy [--dry-run|-n] SRC... DEST

Copies files/dirs using rsync (resume + progress).
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

(( ${#ARGS[@]} >= 2 )) || die "Usage: copy [--dry-run|-n] SRC... DEST"

DEST="${ARGS[-1]}"
SRCS=("${ARGS[@]:0:${#ARGS[@]}-1}")

# If DEST is not a directory and we have multiple SRCs, error.
if (( ${#SRCS[@]} > 1 )) && [[ ! -d "$DEST" ]]; then
  die "DEST must be a directory when copying multiple sources"
fi

# Ensure DEST exists (dir parent for file, dir itself otherwise)
if [[ -d "$DEST" ]]; then
  mkdir -p -- "$DEST"
else
  mkdir -p -- "$(dirname -- "$DEST")"
fi

rsync_args=(
  -aHAX
  --partial
  --inplace
  --human-readable
  --info=progress2
)

(( DRY_RUN )) && rsync_args+=(--dry-run)

for SRC in "${SRCS[@]}"; do
  rsync "${rsync_args[@]}" -- "$SRC" "$DEST"
done
