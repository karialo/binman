#!/usr/bin/env bash
# flash-confirm <image.xz> <device>
VERSION="0.1.0"

lsblk -pn -o NAME,SIZE,MODEL,ROTA,TYPE,MOUNTPOINT | awk '
  /disk/ && $0 ~ /sd|mmcblk|nvme/ {print}
' | column -t
