#!/usr/bin/env bash
# Description: Download and run Tailscale's official installation script.
VERSION="0.1.0"
set -Eeuo pipefail

curl -fsSL https://tailscale.com/install.sh | sh
