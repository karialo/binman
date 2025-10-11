#!/usr/bin/env bash
# prep-headless <boot-partition> <SSID> <PSK> [COUNTRY]
VERSION="0.1.0"

set -euo pipefail

if (( $# < 3 )); then echo "Usage: prep-headless <boot-part> <SSID> <PSK> [COUNTRY]" >&2; exit 1; fi
BOOT="$1"; SSID="$2"; PSK="$3"; COUNTRY="${4:-GB}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sudo mount "$BOOT" "$tmp"
sudo touch "$tmp/ssh"
sudo tee "$tmp/wpa_supplicant.conf" >/dev/null <<EOF
country=${COUNTRY}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
  ssid="${SSID}"
  psk="${PSK}"
  key_mgmt=WPA-PSK
}
EOF
sync
sudo umount "$tmp"
echo "Wrote ssh and wpa_supplicant.conf to $BOOT"
