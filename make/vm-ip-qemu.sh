#!/usr/bin/env bash
set -euo pipefail
# Print IPs of running QEMU-backed Town OS VMs. Silent if none found.

VM_NAME="${VM_NAME:-town-os}"
IMAGE="${IMAGE:-image.raw}"

found=0

VMS=$(sudo virsh list --name 2>/dev/null || true)
if echo "$VMS" | grep -q .; then
  for vm in $VMS; do
    ip=$(sudo virsh domifaddr "${vm}" 2>/dev/null \
      | awk '/ipv4/ { split($4,a,"/"); print a[1] }')
    if [ -n "${ip}" ]; then
      echo "QEMU (${vm}): ${ip}"
      found=1
    fi
  done
fi

if pgrep -f "qemu-system.*${IMAGE}" >/dev/null 2>&1 && [ "${found}" -eq 0 ]; then
  MAC=$(echo "${VM_NAME}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')
  ip=$(sudo virsh net-dhcp-leases default 2>/dev/null \
    | awk -v mac="${MAC}" '$3 == mac { split($5,a,"/"); print a[1] }' | tail -1)
  if [ -n "${ip}" ]; then
    echo "QEMU: ${ip}"
  fi
fi
