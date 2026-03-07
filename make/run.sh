#!/usr/bin/env bash
set -euo pipefail

if command -v qemu-system-x86_64 &>/dev/null; then
  exec "${PWD}/make/qemu.sh" "$@"
elif command -v VBoxManage &>/dev/null; then
  exec "${PWD}/make/virtualbox.sh" "$@"
else
  echo "Error: no supported hypervisor found." >&2
  echo "Install one of:" >&2
  echo "  pacman -S qemu-full      # recommended" >&2
  echo "  pacman -S virtualbox" >&2
  exit 1
fi
