#!/bin/bash
# Chay 1 module cai dat trong tien trinh rieng voi errexit day du.
# Duoc install.sh goi: bash lib/run-module.sh <hermes|n8n|openclaw>
set -euo pipefail
export HOME="${HOME:-/root}"
export DEBIAN_FRONTEND=noninteractive

name="$1"
source "${SELF_DIR}/lib/common.sh"
source "${SELF_DIR}/lib/caddy.sh"
source "${SELF_DIR}/modules/${name}.sh"
"install_${name}"
