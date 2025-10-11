#!/usr/bin/env bash
# rsync-backup SRC DEST_MOUNTPOINT
VERSION="0.1.0"

set -euo pipefail
if (( $# != 2 )); then echo "Usage: rsync-backup SRC DEST_MOUNT"; exit 1; fi
SRC="$1"; DESTM="$2"
if [ ! -d "$DESTM" ]; then echo "Destination mountpoint not found: $DESTM"; exit 2; fi
STAMP=$(date +%Y%m%d-%H%M)
DEST="${DESTM%/}/backup-$STAMP"
mkdir -p "$DEST"
rsync -aHAX --delete --info=progress2 --human-readable "$SRC" "$DEST"
echo "Backup finished: $DEST"
