#!/usr/bin/env bash
# copy — resumable copy with progress (files or directories)
# Usage: copy SRC... DEST
VERSION="0.1.0"
set -Eeuo pipefail

if (( $# < 2 )); then
  echo "Usage: copy SRC... DEST" >&2
  exit 1
fi

DEST="${@: -1}"; SRCS=("${@:1:$#-1}")

# If DEST is not a directory and we have multiple SRCs, error.
if (( ${#SRCS[@]} > 1 )) && [ ! -d "$DEST" ]; then
  echo "copy: DEST must be a directory when copying multiple sources" >&2
  exit 2
fi

# Ensure DEST exists (dir parent for file, dir itself otherwise)
if [ -d "$DEST" ]; then
  mkdir -p "$DEST"
else
  mkdir -p "$(dirname "$DEST")"
fi

# rsync each source with resume + progress
for SRC in "${SRCS[@]}"; do
  rsync -aHAX --partial --inplace --human-readable --info=progress2 \
    "$SRC" "$DEST"
done

