#!/bin/sh
# Refresh rolodex's DNS forwarders from the CURRENT DHCP lease and restart
# rolodex only if they actually changed.
#
# rolodex reads its forwarders once, at startup (--config /data/rolodex.yml),
# and rolodex-config.sh runs as its ExecStartPre — so the forwarders are a
# snapshot of the lease at the moment rolodex first started. This script keeps
# that snapshot current: town-os-rolodex-config.path triggers it on every
# networkd lease transition (DHCP acquire/renew/expire), so a new LAN resolver
# (or WiFi provisioned after boot) is picked up without a manual restart.
set -eu

CONF=/town-os/rolodex/rolodex.yml

old=""
[ -f "$CONF" ] && old="$(cat "$CONF")"

/bin/sh /usr/lib/town-os/scripts/rolodex-config.sh

new="$(cat "$CONF")"

# Same forwarders (e.g. a renewal that re-offered the same DNS): leave the
# running rolodex alone so resolution doesn't blip.
[ "$old" = "$new" ] && exit 0

# Forwarders changed: restart rolodex so it re-reads the config. Use
# TryRestartUnit (only restarts if already running) so a lease transition
# during early boot doesn't start rolodex ahead of its own ordering — its
# ExecStartPre will pick up the current lease when it starts normally.
# systemd operations go through D-Bus, never the systemctl CLI (see CLAUDE.md).
busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager TryRestartUnit ss \
  "town-os-system--rolodex.service" "replace"
