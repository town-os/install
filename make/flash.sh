#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: flash.sh IMAGE}"

if [ ! -f "$IMAGE" ]; then
  echo "Error: image '$IMAGE' not found" >&2
  exit 1
fi

# Find the first USB mass storage block device
USB_DEV=""
for dev in /sys/block/sd*; do
  [ -e "$dev" ] || continue
  devname="$(basename "$dev")"
  # Walk up to find the usb subsystem
  if readlink -f "$dev/device" | grep -q '/usb[0-9]'; then
    USB_DEV="/dev/$devname"
    break
  fi
done

if [ -z "$USB_DEV" ]; then
  echo "Error: no USB storage device found" >&2
  exit 1
fi

# Safety: show device info and confirm
echo "Found USB device: $USB_DEV"
lsblk -o NAME,SIZE,MODEL,TRAN "$USB_DEV"
echo ""
echo "WARNING: This will erase ALL data on $USB_DEV"
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

sudo true
echo "Writing $IMAGE to $USB_DEV ..." >&2
pv < "$IMAGE" | sudo dd if=/dev/stdin of="$USB_DEV" bs=4M iflag=fullblock oflag=direct
echo "Syncing..." >&2
sudo sync
echo "Done. You can safely remove the USB drive."
