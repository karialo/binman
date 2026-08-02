#!/usr/bin/env bash
# Description: List whole-disk removable and NVMe candidates with size, model, rotation, type, and mountpoint details.
VERSION="0.1.0"

lsblk -pn -o NAME,SIZE,MODEL,ROTA,TYPE,MOUNTPOINT | awk '
  /disk/ && $0 ~ /sd|mmcblk|nvme/ {print}
' | column -t
