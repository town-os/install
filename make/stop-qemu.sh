#!/usr/bin/env bash
set -euo pipefail

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
