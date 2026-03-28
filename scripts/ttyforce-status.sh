#!/bin/bash
exec /usr/bin/ttyforce getty --shell --sledgehammer-grub-entry "Sledgehammer - Erase Permanent Storage And Reboot" --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
