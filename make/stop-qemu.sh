#!/usr/bin/env bash
set -euo pipefail

# Reap the LAN relay (make/vm-relay.sh) that a `VM_LAN=1` launch detached to
# outlive qemu.sh. Its own EXIT trap removes the socats and firewall openings.
if [ -f vm-relay.pid ]; then
  RELAY_PID=$(cat vm-relay.pid)
  if kill "${RELAY_PID}" 2>/dev/null; then
    echo "Stopped LAN relay (PID ${RELAY_PID})"
  fi
  rm -f vm-relay.pid
fi

# Reap the host-DNS waiter (make/host-dns.sh set) a background launch detached
# for the same reason. Killed BEFORE the unset below: if the guest never came up
# it is still in its probe loop, and letting it win that race would re-point the
# host at a VM we are in the middle of stopping.
if [ -f vm-dns.pid ]; then
  DNS_PID=$(cat vm-dns.pid)
  if kill "${DNS_PID}" 2>/dev/null; then
    echo "Stopped host-DNS waiter (PID ${DNS_PID})"
  fi
  rm -f vm-dns.pid
fi

if [ -f qemu.pid ]; then
  PID=$(sudo cat qemu.pid)
  if sudo kill "${PID}" 2>/dev/null; then
    echo "Stopped QEMU (PID ${PID})"
  else
    echo "QEMU process ${PID} not running"
  fi
  sudo rm -f qemu.pid
else
  echo "No qemu.pid file found"
fi

# Give the host back its own resolver. Unconditional and idempotent: it exits
# silently when nothing was switched, and running it even on the "no qemu.pid"
# path is what recovers a host left pointed at a VM that died without its trap
# firing (a kill -9, a host crash, a background launch never stopped).
"$(dirname "$0")/host-dns.sh" unset || true
