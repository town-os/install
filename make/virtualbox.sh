#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: virtualbox.sh IMAGE}"
VM_DISK_SIZE="${VM_DISK_SIZE:?VM_DISK_SIZE is required}"
VM_BRIDGE="${VM_BRIDGE:?VM_BRIDGE is required}"
VM_NAME="${VM_NAME:?VM_NAME is required}"
FOREGROUND="${FOREGROUND:-0}"

command -v VBoxManage >/dev/null 2>&1 || { echo "This make task requires virtualbox"; exit 1; }

for i in 0 1 2 3; do
  if [ ! -f "disk${i}.img" ]; then
    truncate -s "${VM_DISK_SIZE}" "disk${i}.img"
    echo "Created sparse disk${i}.img (${VM_DISK_SIZE})"
  fi
done

VBoxManage unregistervm "${VM_NAME}" --delete 2>/dev/null || true
VBoxManage createvm --name "${VM_NAME}" --ostype Linux_64 --register
VBoxManage modifyvm "${VM_NAME}" --memory 4096 --cpus 2 --firmware efi \
  --nic1 bridged --bridgeadapter1 "${VM_BRIDGE}"
VBoxManage storagectl "${VM_NAME}" --name "IDE" --add ide
VBoxManage convertfromraw "${IMAGE}" "${VM_NAME}-boot.vdi" --format VDI 2>/dev/null || true
VBoxManage storageattach "${VM_NAME}" --storagectl "IDE" --port 0 --device 0 \
  --type hdd --medium "${VM_NAME}-boot.vdi"
VBoxManage storagectl "${VM_NAME}" --name "AHCI" --add sata \
  --controller IntelAhci --portcount 4
for i in 0 1 2 3; do
  VBoxManage convertfromraw "disk${i}.img" "${VM_NAME}-disk${i}.vdi" --format VDI 2>/dev/null || true
  VBoxManage storageattach "${VM_NAME}" --storagectl "AHCI" --port "${i}" --device 0 \
    --type hdd --medium "${VM_NAME}-disk${i}.vdi"
done

if [ "${FOREGROUND}" = "1" ]; then
  VBoxManage startvm "${VM_NAME}"
else
  VBoxManage startvm "${VM_NAME}" --type headless
  echo "VirtualBox VM '${VM_NAME}' running in background (headless)"

  echo "Waiting for VM network (up to 120s)..."
  TIMEOUT=120
  ELAPSED=0
  IP=""
  while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    IP=$(VBoxManage guestproperty get "${VM_NAME}" "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>/dev/null \
      | awk '/Value:/ { print $2 }') || true
    if [ -n "${IP}" ]; then
      echo "VirtualBox (${VM_NAME}): ${IP}"
      exit 0
    fi
  done
  echo "Timed out waiting for VM network after ${TIMEOUT}s"
  echo "Use 'make vm-ip' to check later"
fi
