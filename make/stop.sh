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

# Kill a detached host-DNS waiter first. stop-qemu.sh above reaps it too, but
# only runs when there is a qemu.pid — and a waiter still spinning on a guest
# that never answered is precisely what outlives a VM that died untracked. If it
# were left alive it could re-point the host after the unset below.
if [ -f vm-dns.pid ]; then
  DNS_PID=$(cat vm-dns.pid)
  kill "${DNS_PID}" 2>/dev/null || true
  rm -f vm-dns.pid
fi

# Always give the host back its own resolver, even when no VM was tracked — that
# is exactly the case where a stale switch (VM killed without its trap firing)
# needs recovering. Idempotent and silent when nothing was set.
"${PWD}/make/host-dns.sh" unset || true
