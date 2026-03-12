#!/bin/bash

# sledgehammer.sh — Erase all permanent storage except the boot USB and reboot.
# Triggered by the "town.sledgehammer" kernel command-line parameter.

set -euo pipefail

# Only run if the kernel was booted with the sledgehammer parameter
if ! grep -q 'town\.sledgehammer' /proc/cmdline; then
  echo "town.sledgehammer not on kernel cmdline, skipping."
  exit 0
fi

echo "*** SLEDGEHAMMER: Erasing all permanent storage ***"

# Determine which device holds the boot filesystem so we don't wipe it
boot_dev=""
for mp in /boot /sysroot /; do
  boot_dev="$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)"
  if [ -n "$boot_dev" ]; then
    break
  fi
done

# Resolve to the whole-disk device (strip partition suffix)
boot_disk=""
if [ -n "$boot_dev" ]; then
  boot_disk="$(lsblk -ndo PKNAME "$boot_dev" 2>/dev/null || true)"
  if [ -n "$boot_disk" ]; then
    boot_disk="/dev/$boot_disk"
  fi
fi

echo "Boot disk: ${boot_disk:-unknown} — will be preserved"

for disk in /sys/block/*; do
  name="$(basename "$disk")"

  # Only consider nvme and sd devices
  if ! echo "$name" | grep -qE '^(nvme|sd)'; then
    continue
  fi

  dev="/dev/$name"

  # Skip the boot disk
  if [ "$dev" = "$boot_disk" ]; then
    echo "Skipping boot disk: $dev"
    continue
  fi

  # Skip removable media (USB sticks show removable=1)
  if [ "$(cat "/sys/block/$name/removable" 2>/dev/null)" = "1" ]; then
    echo "Skipping removable device: $dev"
    continue
  fi

  echo "WIPING: $dev"

  # Stop any md arrays using this disk
  for md in /dev/md*; do
    if [ -b "$md" ] && mdadm --detail "$md" 2>/dev/null | grep -q "$dev"; then
      mdadm --stop "$md" 2>/dev/null || true
    fi
  done

  # Wipe all partition signatures and filesystem metadata
  wipefs -a "$dev" 2>/dev/null || true

  # Zero out the first and last 100MB to destroy partition tables,
  # filesystem superblocks, and RAID metadata
  dd if=/dev/zero of="$dev" bs=1M count=100 conv=notrunc 2>/dev/null || true
  size_bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  if [ "$size_bytes" -gt 104857600 ]; then
    dd if=/dev/zero of="$dev" bs=1M count=100 seek=$(( (size_bytes / 1048576) - 100 )) conv=notrunc 2>/dev/null || true
  fi

  # Also zero each partition individually
  for part in "${dev}"*; do
    if [ -b "$part" ] && [ "$part" != "$dev" ]; then
      wipefs -a "$part" 2>/dev/null || true
      dd if=/dev/zero of="$part" bs=1M count=10 conv=notrunc 2>/dev/null || true
    fi
  done

  echo "WIPED: $dev"
done

echo "*** SLEDGEHAMMER COMPLETE — rebooting ***"
sync
reboot -f
