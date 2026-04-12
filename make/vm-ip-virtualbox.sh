#!/usr/bin/env bash
set -euo pipefail
# Print IPs of running VirtualBox-backed Town OS VMs. Silent if none found.

VM_NAME="${VM_NAME:-town-os}"

if command -v VBoxManage >/dev/null 2>&1; then
  ip=$(VBoxManage guestproperty get "${VM_NAME}" "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>/dev/null \
    | awk '/Value:/ { print $2 }')
  if [ -n "${ip}" ]; then
    echo "VirtualBox (${VM_NAME}): ${ip}"
  fi
fi
