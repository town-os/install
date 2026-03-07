#!/usr/bin/env bash
set -euo pipefail

VM_NAME="${VM_NAME:-town-os}"
IMAGE="${IMAGE:-image.raw}"

found=0

if sudo virsh list --name 2>/dev/null | grep -q .; then
  for vm in $(sudo virsh list --name 2>/dev/null); do
    ip=$(sudo virsh domifaddr "${vm}" 2>/dev/null \
      | awk '/ipv4/ { split($4,a,"/"); print a[1] }')
    if [ -n "${ip}" ]; then
      echo "QEMU (${vm}): ${ip}"
      found=1
    fi
  done
fi

if pgrep -f "qemu-system.*${IMAGE}" >/dev/null 2>&1 && [ "${found}" -eq 0 ]; then
  ip=$(sudo virsh net-dhcp-leases default 2>/dev/null \
    | awk 'NR>2 && $6 != "" { split($5,a,"/"); print a[1] }' | head -1)
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
