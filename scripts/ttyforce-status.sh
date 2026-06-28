#!/bin/bash
log_flag=""
if grep -q 'town\.sledgehammer' /proc/cmdline; then
  log_flag="--log"
fi

# Sledgehammer wipe-boot trigger differs by platform (see ttyforce-getty.sh):
# GRUB images use grub-reboot, the Raspberry Pi uses the firmware `tryboot`
# one-shot. Detect the Pi by its device-tree model.
if grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
  sledge=(--sledgehammer-tryboot)
else
  sledge=(--sledgehammer-grub-entry "Sledgehammer - Erase Permanent Storage And Reboot")
fi

exec /usr/bin/ttyforce getty --quit $log_flag "${sledge[@]}" --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
