#!/usr/bin/env bash
set -euo pipefail

stopped=0

if [ -f qemu.pid ]; then
  IMAGE="${IMAGE}" "${PWD}/make/stop-qemu.sh"
  stopped=1
fi

if command -v VBoxManage &>/dev/null && \
   VBoxManage showvminfo "${VM_NAME}" &>/dev/null; then
  VM_NAME="${VM_NAME}" "${PWD}/make/stop-virtualbox.sh"
  stopped=1
fi

if [ "${stopped}" -eq 0 ]; then
  echo "No tracked VMs found"
fi
