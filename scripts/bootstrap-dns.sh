#!/bin/sh
# Point systemd-resolved at exactly ONE resolver — whichever is actually working
# right now — so it never wastes a query on a dead server or leaks a split-horizon
# name to a resolver that doesn't host the local zones.
#
#   rolodex UP   -> DNS=127.0.0.2 ::1     (rolodex is primary and SOLE)
#   rolodex DOWN -> DNS=<DHCP/gateway>    (bootstrap resolver only; NO loopback)
#
# Why a hard toggle rather than a preference list:
#   * systemd-resolved treats DNS= as a SET, picks one "current" server and
#     sticks to it, rotating only on failure. Listing rolodex AND the DHCP
#     resolver together lets resolved latch onto the DHCP resolver (e.g. after a
#     rolodex cold-query blip) and then route EVERYTHING there — including
#     split-horizon .home names it can't answer (NXDOMAIN). So the DHCP resolver
#     must never be a peer of rolodex.
#   * When rolodex is down, listing 127.0.0.2/::1 (dead) just buys a per-query
#     timeout before resolved falls to the DHCP resolver — so drop the loopback
#     entirely while rolodex is down.
#
# The DHCP/gateway resolver is what the box boots with (rolodex is a container
# pulled from quay.io with --pull=always; resolving quay.io needs a working DNS
# before rolodex exists) and what it falls back to any time rolodex is down. It is
# NOT a rolodex forwarder — rolodex recurses from the roots itself.
#
# This script is the single source of truth for resolved's DNS= list. It is run:
#   * at boot before rolodex (town-os-bootstrap-dns.service)   -> down state
#   * right after rolodex is listening (rolodex ExecStartPost)  -> up state
#   * right after rolodex stops (rolodex ExecStopPost)          -> down state
#   * on every DHCP lease change (town-os-rolodex-config.path)  -> refresh either
# It probes rolodex liveness itself, so every caller converges on the right list.
set -eu

DROPIN_DIR=/run/systemd/resolved.conf.d
# 'zz-' sorts after the baked /etc/…/townos.conf so this list is applied last.
DROPIN="$DROPIN_DIR/zz-townos-bootstrap.conf"

# rolodex — and only rolodex — binds 127.0.0.2:53 (it runs --net host). If that
# socket is listening, rolodex is up and must be resolved's sole resolver.
if ss -H -t -u -l -n 2>/dev/null | grep -q '127\.0\.0\.2:53'; then
  desired="127.0.0.2 ::1"
else
  # rolodex is down: use the DHCP-offered DNS from every networkd lease (in
  # order, deduped) then the default gateway (a DNS forwarder in NAT/home-router
  # setups — on the QEMU dev VM this is libvirt's dnsmasq at 192.168.122.1, which
  # forwards through the host and so works even where raw outbound public DNS is
  # filtered). Loopback is dropped: 127.0.0.x here is dead rolodex / resolved's
  # own stub, and forwarding to it would loop or stall.
  dhcp_dns="$(
    awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null \
      | tr ' ' '\n'
  )"
  gw="$(ip -4 route show default 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
  desired="$(
    { printf '%s\n' "$dhcp_dns"; [ -n "$gw" ] && printf '%s\n' "$gw"; } \
      | grep -vE '^(127\.|::1$)' \
      | awk 'NF && !seen[$0]++' \
      | tr '\n' ' ' \
      | sed 's/ *$//'
  )"
fi

# A leading empty `DNS=` RESETS the list systemd-resolved accumulated from the
# baked townos.conf (which lists 127.0.0.2 ::1), so this drop-in fully owns it —
# without the reset, resolved MERGES the lists and 127.0.0.2 would survive even
# in the down state.
new_content="$(cat <<EOF
# Written at runtime by scripts/bootstrap-dns.sh — do not edit.
[Resolve]
DNS=
DNS=$desired
EOF
)"

# Idempotent: only rewrite + reload resolved when the list actually changes, so a
# lease renewal (or a redundant start/stop hook firing) doesn't blip resolution.
old_content=""
[ -f "$DROPIN" ] && old_content="$(cat "$DROPIN")"
[ "$old_content" = "$new_content" ] && exit 0

mkdir -p "$DROPIN_DIR"
printf '%s\n' "$new_content" > "$DROPIN"

# Reload resolved so it picks up the new global DNS list. D-Bus, not the
# systemctl CLI (see CLAUDE.md).
busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager ReloadUnit ss \
  "systemd-resolved.service" "replace" || true
