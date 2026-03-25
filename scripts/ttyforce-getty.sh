#!/bin/bash
exec /usr/bin/ttyforce getty --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
