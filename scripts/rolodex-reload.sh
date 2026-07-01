#!/bin/sh
# Keep DNS current across DHCP transitions. town-os-rolodex-config.path triggers
# this on every networkd lease change (acquire/renew/expire). Two things depend
# on the lease:
#
#   1. The BOOTSTRAP resolver — resolved's fallback DHCP/gateway server, used
#      before rolodex is up (see scripts/bootstrap-dns.sh). If the offered DNS or
#      the gateway changes (renewal, WiFi provisioned after boot), refresh it.
#   2. rolodex's BIND list — it binds the host's global addresses, which change
#      if the DHCP address changes. rolodex reads its config once at startup, so
#      restart it (only if the generated config actually changed) to rebind.
#
# rolodex does NOT forward, so nothing here touches upstreams — it recurses from
# the roots regardless of the lease.
set -eu

# 1. Refresh the bootstrap resolver from the current lease/gateway.
/bin/sh /usr/lib/town-os/scripts/bootstrap-dns.sh || true

# 2. Regenerate rolodex.yml; restart rolodex only if its bind list changed.
CONF=/town-os/rolodex/rolodex.yml

old=""
[ -f "$CONF" ] && old="$(cat "$CONF")"

/bin/sh /usr/lib/town-os/scripts/rolodex-config.sh

new="$(cat "$CONF")"

# Unchanged (e.g. a renewal keeping the same address): leave rolodex alone so
# resolution doesn't blip.
[ "$old" = "$new" ] && exit 0

# Changed: restart rolodex so it re-reads the config. Use TryRestartUnit (only
# restarts if already running) so a lease transition during early boot doesn't
# start rolodex ahead of its own ordering — its ExecStartPre picks up the current
# state when it starts normally. D-Bus, never the systemctl CLI (see CLAUDE.md).
busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager TryRestartUnit ss \
  "town-os-system--rolodex.service" "replace"
