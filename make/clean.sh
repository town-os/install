#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:?IMAGE is required}"
VM_NAME="${VM_NAME:?VM_NAME is required}"

rm -f "${IMAGE}" disk0.img disk1.img disk2.img disk3.img

if command -v VBoxManage >/dev/null 2>&1; then
  VBoxManage unregistervm "${VM_NAME}" --delete 2>/dev/null || true
fi

rm -f "${VM_NAME}-boot.vdi" \
  "${VM_NAME}-disk0.vdi" "${VM_NAME}-disk1.vdi" \
  "${VM_NAME}-disk2.vdi" "${VM_NAME}-disk3.vdi"

sudo -E rm -f qemu.pid
