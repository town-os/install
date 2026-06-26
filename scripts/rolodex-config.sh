#!/bin/sh
# Generate rolodex's runtime config, choosing DNS forwarders from DHCP.
#
# rolodex is the system resolver: systemd-resolved is pointed at 127.0.0.2
# first, so rolodex always answers first and only *forwards* names it isn't
# authoritative for. This script picks what it forwards TO:
#
#   - DHCP-provided DNS servers when the lease offers any (honors the local
#     network's resolver: LAN/split-horizon names, captive portals).
#   - then the default gateway, which in NAT/home-router setups runs a DNS
#     forwarder — and on networks that filter outbound DNS to public resolvers
#     is often the ONLY resolver that works.
#   - then Cloudflare/Google as an always-on safety net.
#
# QEMU dev special-case: the libvirt default NAT hands the guest its own dnsmasq
# (192.168.122.1) as the DHCP DNS. We drop the 192.168.122.0/24 entry from the
# DHCP list (a lease pointing at the guest's own subnet), but it comes back via
# the gateway path — and that is SAFE because qemu.sh pins that dnsmasq's
# forwarders to the host's real upstream, so forwarding rolodex to 192.168.122.1
# reaches the upstream directly and does NOT loop back through host resolved (the
# loop the drop originally guarded against). On a DNS-filtering network this
# gateway path is the only thing that makes guest DNS work, since the public
# servers are blocked. In a real deployment Town OS is not behind libvirt's NAT,
# so the gateway is just the LAN router there.
#
# This keeps "rolodex first, then DHCP DNS" without letting DHCP DNS outrank
# rolodex: ttyforce sets `UseDNS=no` on its networkd units precisely so the
# DHCP servers never get installed as higher-priority per-link resolvers (which
# would bypass rolodex). networkd still records them in the lease file
# regardless of UseDNS, so that file — not resolved — is our source.
set -eu

CONF_DIR=/town-os/rolodex
CONF="$CONF_DIR/rolodex.yml"
mkdir -p "$CONF_DIR"

# DHCP-offered DNS from every networkd lease, in order, deduped. Drop loopback
# (forwarding to 127.0.0.x would loop back into rolodex itself) and the libvirt
# default NAT subnet (192.168.122.0/24 — the QEMU dev special-case above).
dhcp_dns="$(
  awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null \
    | tr ' ' '\n' \
    | grep -vE '^(127\.|::1$|192\.168\.122\.)' \
    | awk 'NF && !seen[$0]++'
)"

forwarder_line() {
  # IPv6 literals contain ':' and must be bracketed before the :53 port.
  case "$1" in
    *:*) printf '  - "[%s]:53"\n' "$1" ;;
    *)   printf '  - "%s:53"\n' "$1" ;;
  esac
}

# Default gateway — a DNS forwarder in NAT/home setups (libvirt's dnsmasq on the
# dev VM; see header). Read from the routing table; empty if there's no route.
gw="$(ip -4 route show default 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')"

# Forwarder priority: DHCP-offered DNS, then the gateway, then the public
# servers as a safety net. Deduped, first occurrence wins; loopback dropped
# (forwarding to 127.0.0.x / ::1 would loop back into rolodex itself).
forwarder_ips="$(
  {
    printf '%s\n' "$dhcp_dns"
    if [ -n "$gw" ]; then printf '%s\n' "$gw"; fi
    printf '1.1.1.1\n8.8.8.8\n'
  } | grep -vE '^(127\.|::1$)' | awk 'NF && !seen[$0]++'
)"
forwarders="$(printf '%s\n' "$forwarder_ips" | while IFS= read -r ip; do forwarder_line "$ip"; done)"

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
forwarders:
$forwarders
rbl:
  enabled: true
  providers: []
EOF
