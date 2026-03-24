#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:-town-os}"
IMAGE="${IMAGE:-image.raw}"

found=0

if sudo -E virsh list --name 2>/dev/null | grep -q .; then
  for vm in $(sudo -E virsh list --name 2>/dev/null); do
    ip=$(sudo -E virsh domifaddr "${vm}" 2>/dev/null \
      | awk '/ipv4/ { split($4,a,"/"); print a[1] }')
    if [ -n "${ip}" ]; then
      echo "QEMU (${vm}): ${ip}"
      found=1
    fi
  done
fi

if pgrep -f "qemu-system.*${IMAGE}" >/dev/null 2>&1 && [ "${found}" -eq 0 ]; then
  # Derive the same stable MAC that qemu.sh generates from VM_NAME
  MAC=$(echo "${VM_NAME}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')
  ip=$(sudo -E virsh net-dhcp-leases default 2>/dev/null \
    | awk -v mac="${MAC}" '$3 == mac { split($5,a,"/"); print a[1] }' | tail -1)
  if [ -n "${ip}" ]; then
    echo "QEMU: ${ip}"
    found=1
  fi
fi

if command -v VBoxManage >/dev/null 2>&1; then
  ip=$(VBoxManage guestproperty get "${VM_NAME}" "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>/dev/null \
    | awk '/Value:/ { print $2 }')
  if [ -n "${ip}" ]; then
    echo "VirtualBox (${VM_NAME}): ${ip}"
    found=1
  fi
fi

if [ "${found}" -eq 0 ]; then
  echo "No running VMs found"
fi
