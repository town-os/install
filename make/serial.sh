#!/usr/bin/env bash
set -euo pipefail

SOCK="${1:-/tmp/town-os-serial.sock}"

if [ ! -S "${SOCK}" ]; then
  echo "No serial socket at ${SOCK}" >&2
  echo "Is the VM running? Start with: make qemu" >&2
  exit 1
fi

echo "Connecting to serial console (Ctrl-] to disconnect)..."
exec sudo -E socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:"${SOCK}"
