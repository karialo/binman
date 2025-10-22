#!/usr/bin/env bash
# move — safe resumable move with progress (rsync + verify + remove)
# Usage: move SRC... DEST
VERSION="0.1.1"

set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: move SRC... DEST" >&2
  exit 1
fi

DEST="${@: -1}"; SRCS=("${@:1:$#-1}")

if (( ${#SRCS[@]} > 1 )) && [ ! -d "$DEST" ]; then
  echo "move: DEST must be a directory when moving multiple sources" >&2
  exit 2
fi

# Ensure destination exists appropriately
if [ -d "$DEST" ]; then
  mkdir -p "$DEST"
else
  mkdir -p "$(dirname "$DEST")"
fi

for SRC in "${SRCS[@]}"; do
  # 1) Transfer with resume + progress
  rsync -aHAX --partial --inplace --human-readable --info=progress2 \
    "$SRC" "$DEST"

  # 2) Verify with checksum dry-run (no changes expected)
  if rsync -aHAX --checksum --dry-run --delete --itemize-changes "$SRC" "$DEST" | grep -q '^[^ ]'; then
    echo "move: verification failed for '$SRC' → '$DEST' (not deleting source)" >&2
    exit 3
  fi

  # 3) Remove original
  if [ -d "$SRC" ] && [ ! -L "$SRC" ]; then
    rm -rf --one-file-system "$SRC"
  else
    rm -f "$SRC"
  fi
done
