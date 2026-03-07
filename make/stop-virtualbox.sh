#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:?VM_NAME is required}"

command -v VBoxManage >/dev/null 2>&1 || { echo "This make task requires virtualbox"; exit 1; }

if VBoxManage controlvm "${VM_NAME}" poweroff 2>/dev/null; then
  echo "Stopped VirtualBox VM '${VM_NAME}'"
else
  echo "VirtualBox VM '${VM_NAME}' is not running"
fi
