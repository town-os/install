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
