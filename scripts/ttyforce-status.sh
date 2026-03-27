#!/bin/bash
exec /usr/bin/ttyforce getty --shell --etc-prefix /town-os/etc/overlays/root --tty "$(tty)"
