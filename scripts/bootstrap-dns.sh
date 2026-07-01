#!/bin/sh
# Point systemd-resolved at the DHCP-provided resolver so the system can resolve
# names BEFORE rolodex is running.
#
# The bootstrap deadlock this breaks: rolodex is a container pulled from quay.io
# (--pull=always). Pulling it requires resolving quay.io, which goes through
# resolved. resolved's static config lists rolodex first (127.0.0.2 / ::1) — but
# rolodex is exactly what we're trying to start, so it's down — and NOTHING else,
# because rolodex recurses from the roots rather than forwarding and we don't
# hand public resolvers to resolved. On a network that filters public DNS the
# pull can never resolve quay.io and rolodex never starts.
#
# ttyforce already determined the working resolver at provisioning time: it is
# the DHCP-offered DNS (and, in NAT/home setups, the default gateway, which runs
# a DNS forwarder). We add that resolver to resolved's GLOBAL DNS list, AFTER the
# rolodex loopbacks, via a /run drop-in. resolved tries its global servers in
# order, so once rolodex is up it answers first and this entry is only a fallback
# for when rolodex is down (bootstrap, or a rolodex outage). This is the "you
# only need DHCP DNS until rolodex comes up" path — it is NOT a rolodex forwarder.
set -eu

DROPIN_DIR=/run/systemd/resolved.conf.d
# Must sort AFTER the baked /etc/…/townos.conf so that if resolved treats DNS=
# as override-last-wins (rather than additive) our full list wins. 'zz-' guards
# that regardless of the baked file's name.
DROPIN="$DROPIN_DIR/zz-townos-bootstrap.conf"

# DHCP-offered DNS from every networkd lease, in order, deduped, then the default
# gateway (a DNS forwarder in NAT/home-router setups — on the QEMU dev VM this is
# libvirt's dnsmasq at 192.168.122.1, which forwards through the host and so works
# even where raw outbound DNS to public resolvers is filtered). Loopback is
# dropped (resolved forwarding to 127.0.0.x would loop back into itself / rolodex).
dhcp_dns="$(
  awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null \
    | tr ' ' '\n'
)"
gw="$(ip -4 route show default 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')"

resolvers="$(
  { printf '%s\n' "$dhcp_dns"; [ -n "$gw" ] && printf '%s\n' "$gw"; } \
    | grep -vE '^(127\.|::1$)' \
    | awk 'NF && !seen[$0]++' \
    | tr '\n' ' ' \
    | sed 's/ *$//'
)"

mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
# Written at runtime by scripts/bootstrap-dns.sh — do not edit.
[Resolve]
DNS=127.0.0.2 ::1${resolvers:+ $resolvers}
EOF

# Reload resolved so it picks up the new global DNS list. D-Bus, not the
# systemctl CLI (see CLAUDE.md).
busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager ReloadUnit ss \
  "systemd-resolved.service" "replace" || true
