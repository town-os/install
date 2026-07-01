#!/bin/sh
# Generate rolodex's runtime config.
#
# rolodex is the system resolver: systemd-resolved is pointed at 127.0.0.2
# first, so rolodex always answers first. For names it isn't authoritative for,
# rolodex runs in `auto` mode — a resilient fallback chain:
#
#   1. recurse from the ROOT SERVERS (preferred);
#   2. if that fails (e.g. a network that filters outbound :53), DoH/DoT to
#      public resolvers over :443/:853 (rolodex's built-in defaults —
#      Cloudflare/Google — so this script doesn't set them);
#   3. the LOCAL forwarder — the DHCP-provided resolver / default gateway, which
#      this script computes below and writes to `forwarders`;
#   4. public resolvers over plaintext :53 as a last resort (rolodex default).
#
# rolodex switches tiers only after a grace period of failures and flushes its
# cache on every switch (cross-tier poisoning guard) — all handled in rolodex.
# We only supply the pieces that are host-specific: the `bind` list and the
# local `forwarders`. The DHCP resolver is ALSO used, separately, as the
# systemd-resolved BOOTSTRAP resolver (scripts/bootstrap-dns.sh) so the rolodex
# image can be pulled before rolodex itself is up.
set -eu

CONF_DIR=/town-os/rolodex
CONF="$CONF_DIR/rolodex.yml"
mkdir -p "$CONF_DIR"

# Local forwarder(s) for the auto chain's tier 3: the DHCP-offered DNS from every
# networkd lease, then the default gateway (a DNS forwarder in NAT/home setups;
# on the QEMU dev VM this is libvirt's dnsmasq at 192.168.122.1, which forwards
# through the host and works even where raw outbound :53 is filtered). Loopback
# is dropped (forwarding to 127.0.0.x would loop back into rolodex). Deduped,
# first occurrence wins.
dhcp_dns="$(
  awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null \
    | tr ' ' '\n'
)"
gw="$(ip -4 route show default 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')"
forwarder_ips="$(
  { printf '%s\n' "$dhcp_dns"; [ -n "$gw" ] && printf '%s\n' "$gw"; } \
    | grep -vE '^(127\.|::1$)' \
    | awk 'NF && !seen[$0]++'
)"
forwarders="$(
  printf '%s\n' "$forwarder_ips" | while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    case "$ip" in
      *:*) printf '  - "[%s]:53"\n' "$ip" ;;
      *)   printf '  - "%s:53"\n' "$ip" ;;
    esac
  done
)"
# A bare `forwarders:` is YAML null, not an empty list — emit `[]` when we found
# none (rolodex still resolves via roots + the DoH/public tiers).
if [ -n "$forwarders" ]; then
  forwarders_block="forwarders:
$forwarders"
else
  forwarders_block="forwarders: []"
fi

# Build the DNS bind list. We always bind loopback so systemd-resolved can reach
# rolodex locally over BOTH protocols: 127.0.0.2 (resolved's first DNS= entry)
# and ::1 (its IPv6 counterpart — see scripts/configure.sh). On top of that we
# bind every GLOBAL-scope address on the default-route interface so rolodex is
# reachable EXTERNALLY on the host's routable IPv4 and IPv6 addresses (other LAN
# hosts, upstream clients). We enumerate the addresses here and emit literals
# rather than using rolodex's `primary`/interface tokens because: `primary` is
# IPv4-only (it derives the address from a UDP connect to 8.8.8.8), and an
# interface token would also hand rolodex link-local fe80:: addresses, which
# cannot be bound without a scope id and would log a bind error every start.
# Filtering to `scope global` drops link-local and loopback cleanly.
binds=""
add_bind() {  # $1 = bare IP literal (v4 or v6, unbracketed)
  case "$1" in
    *:*) b="[$1]:53" ;;
    *)   b="$1:53" ;;
  esac
  binds="${binds}    - udp: \"${b}\"
    - tcp: \"${b}\"
"
}
add_bind 127.0.0.2
add_bind ::1
primary_if="$(ip route show default 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
if [ -n "$primary_if" ]; then
  for ip in $(ip -o addr show dev "$primary_if" scope global 2>/dev/null \
    | awk '{ print $4 }' | cut -d/ -f1); do
    add_bind "$ip"
  done
fi

cat > "$CONF" <<EOF
database_path: /data/rolodex.db
dns:
  bind:
${binds}grpc:
  tcp_bind: ""
  unix_socket: /data/rolodex.sock
  shared_secret: ""
${forwarders_block}
resolution:
  mode: auto
rbl:
  enabled: true
  providers: []
EOF
