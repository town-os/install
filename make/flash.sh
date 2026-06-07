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

# --- Expand the data partition to fill the device ---
# The image is shrunk to ~minimum at build time, so after flashing, most of the
# target device is unused. Grow partition 3 (the ext4 data partition that holds
# root.sfs + /boot) and its filesystem to the full device size. Set FLASH_EXPAND=0
# to keep the minimal layout (e.g. to re-image the stick later).
if [ "${FLASH_EXPAND:-1}" != "0" ]; then
  echo "Expanding partition 3 to fill $USB_DEV ..." >&2
  sudo partprobe "$USB_DEV" 2>/dev/null || true
  # The flashed image's backup GPT header sits at the end of the (small) image,
  # not the device, so the trailing free space isn't addressable yet. parted
  # prompts "Fix" to relocate the backup GPT to the device's true end and update
  # the primary header's last-usable-LBA; feed the answer non-interactively.
  # (sgdisk -e would do the same but is not a host dependency.)
  printf 'Fix\nFix\n' | sudo parted ---pretend-input-tty "$USB_DEV" print >/dev/null 2>&1 || true
  # Grow partition 3 to the end of the device, then resize the ext4 to match.
  sudo parted -s "$USB_DEV" resizepart 3 100%
  sudo partprobe "$USB_DEV" 2>/dev/null || true
  sudo udevadm settle 2>/dev/null || true
  PART3="${USB_DEV}3"
  # e2fsck returns 1 when it fixes minor issues; that is not a failure here.
  sudo e2fsck -fy "$PART3" || [ $? -le 1 ]
  sudo resize2fs "$PART3"
  sudo sync
  echo "Expanded $PART3:" >&2
  lsblk -o NAME,SIZE,FSTYPE "$USB_DEV"
fi

echo "Done. You can safely remove the USB drive."
