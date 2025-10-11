#!/usr/bin/env bash
# find-pi - finds devices with raspberry pi OUI/vendor
VERSION="0.1.0"
if command -v arp-scan >/dev/null 2>&1; then
  sudo arp-scan --localnet | egrep -i 'raspberry|b8:27:eb|dc:a6:32|raspberrypi'
else
  echo "arp-scan missing, falling back to nmap (slower)"
  if ! command -v nmap >/dev/null 2>&1; then echo "Install arp-scan or nmap." >&2; exit 1; fi
  sudo nmap -sn --max-retries 1 --host-timeout 200ms $(ip -4 -o addr show scope global | awk '{print $4}') | egrep -B2 -i 'raspberry'
fi
