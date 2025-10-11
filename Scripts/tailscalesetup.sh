#!/usr/bin/env bash
# Description: Hello from script
VERSION="0.1.0"
set -Eeuo pipefail

curl -fsSL https://tailscale.com/install.sh | sh
