#!/bin/bash
log_flag=""
if grep -q 'town\.sledgehammer' /proc/cmdline; then
  log_flag="--log"
fi
exec /usr/bin/ttyforce getty $log_flag --sledgehammer-grub-entry "Sledgehammer - Erase Permanent Storage And Reboot" --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
