#!/bin/bash
log_flag=""
if grep -q 'town\.sledgehammer' /proc/cmdline; then
  log_flag="--log"
fi

# Sledgehammer wipe-boot trigger differs by platform. UEFI/GRUB images use a
# one-shot GRUB entry (grub-reboot). The Raspberry Pi has no GRUB, so it uses the
# firmware `tryboot` one-shot instead (config.txt's [tryboot] -> cmdline_sledge.txt
# adds town.sledgehammer). Detect the Pi by its device-tree model.
#
# The Anbernic RG35XX (U-Boot/extlinux, also no GRUB) deliberately takes the
# grub-reboot branch: that image ships a grub-reboot SHIM at /usr/bin/grub-reboot
# which flips extlinux.conf's DEFAULT to the matching label, so the entry TITLE
# below is the interface on that target too and must keep matching the LABEL's
# MENU LABEL in make/install.sh.
if grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
  sledge=(--sledgehammer-tryboot)
else
  sledge=(--sledgehammer-grub-entry "Sledgehammer - Erase Permanent Storage And Reboot")
fi

exec /usr/bin/ttyforce getty $log_flag "${sledge[@]}" --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
