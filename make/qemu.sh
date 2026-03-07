#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: qemu.sh IMAGE}"
VM_DISK_SIZE="${VM_DISK_SIZE:?VM_DISK_SIZE is required}"
VM_MEMORY="${VM_MEMORY:?VM_MEMORY is required}"
VM_BRIDGE="${VM_BRIDGE:?VM_BRIDGE is required}"
FOREGROUND="${FOREGROUND:-0}"

sudo ip link set "${VM_BRIDGE}" allmulticast on 2>/dev/null || true

for i in 0 1 2 3; do
  if [ ! -f "disk${i}.img" ]; then
    truncate -s "${VM_DISK_SIZE}" "disk${i}.img"
    echo "Created sparse disk${i}.img (${VM_DISK_SIZE})"
  fi
done

DAEMON_ARGS=()
SERIAL_ARGS=()
if [ "${FOREGROUND}" != "1" ]; then
  DAEMON_ARGS=(-daemonize -pidfile qemu.pid)
  SERIAL_ARGS=(-serial "unix:/tmp/town-os-serial.sock,server=on,wait=off")
else
  SERIAL_ARGS=(-serial mon:stdio)
fi

# Generate a stable random MAC in the QEMU OUI range (52:54:00:xx:xx:xx)
# seeded from the VM name so the same VM always gets the same MAC/IP
MAC=$(echo "${VM_NAME:-town-os}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')

sudo -E qemu-system-x86_64 \
  -enable-kvm \
  -m "${VM_MEMORY}" \
  -netdev bridge,id=net0,br="${VM_BRIDGE}" \
  -device virtio-net-pci,netdev=net0,mac="${MAC}" \
  -device qemu-xhci \
  -drive if=none,id=usbdisk,file="${IMAGE}",format=raw \
  -device usb-storage,drive=usbdisk,bootindex=0 \
  -device ahci,id=ahci0 \
  -drive file=disk0.img,if=none,id=d0,format=raw \
  -device ide-hd,drive=d0,bus=ahci0.0 \
  -drive file=disk1.img,if=none,id=d1,format=raw \
  -device ide-hd,drive=d1,bus=ahci0.1 \
  -drive file=disk2.img,if=none,id=d2,format=raw \
  -device ide-hd,drive=d2,bus=ahci0.2 \
  -drive file=disk3.img,if=none,id=d3,format=raw \
  -device ide-hd,drive=d3,bus=ahci0.3 \
  "${SERIAL_ARGS[@]}" \
  "${DAEMON_ARGS[@]}"

if [ "${FOREGROUND}" != "1" ]; then
  PID=$(sudo cat qemu.pid)
  echo "QEMU running in background (PID ${PID})"
  echo "Serial console: socat - UNIX-CONNECT:/tmp/town-os-serial.sock"

  echo "Waiting for VM network (up to 120s)..."
  TIMEOUT=120
  ELAPSED=0
  IP=""
  while [ "${ELAPSED}" -lt "${TIMEOUT}" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    IP=$(VM_NAME="${VM_NAME:-town-os}" IMAGE="${IMAGE}" "$(dirname "$0")/vm-ip.sh" 2>/dev/null) || true
    if [ -n "${IP}" ]; then
      echo "${IP}"
      exit 0
    fi
  done
  echo "Timed out waiting for VM network after ${TIMEOUT}s"
  echo "Use 'make vm-ip' to check later"
fi
