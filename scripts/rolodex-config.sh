#!/bin/sh
# Generate rolodex's runtime config, choosing DNS forwarders from DHCP.
#
# rolodex is the system resolver: systemd-resolved is pointed at 127.0.0.2
# first, so rolodex always answers first and only *forwards* names it isn't
# authoritative for. This script picks what it forwards TO:
#
#   - DHCP-provided DNS servers when the lease offers any. That honors the
#     local network's resolver (LAN/split-horizon names, captive portals).
#   - Cloudflare/Google ONLY when the lease offers no DNS.
#
# QEMU dev special-case: the libvirt default NAT hands the guest its own dnsmasq
# (192.168.122.0/24, the .1 gateway) as the DHCP DNS. Forwarding rolodex there
# routes guest DNS back through the HOST's resolver, which loops if the host in
# turn points at this guest (the "use Town OS as my resolver" dev setup). We
# therefore DROP any 192.168.122.0/24 forwarder below; on the dev VM that empties
# the DHCP list, so the public fallback applies and rolodex forwards straight to
# 1.1.1.1/8.8.8.8. Town OS never sits behind libvirt's NAT in a real deployment
# (it bridges onto the real LAN), so this only ever fires under the QEMU dev VM.
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

if [ -n "$dhcp_dns" ]; then
  forwarders="$(echo "$dhcp_dns" | while IFS= read -r ip; do forwarder_line "$ip"; done)"
else
  forwarders='  - "1.1.1.1:53"
  - "8.8.8.8:53"'
fi

cat > "$CONF" <<EOF
database_path: /data/rolodex.db
dns:
  bind:
    - udp: "primary:53"
    - udp: "127.0.0.2:53"
    - tcp: "primary:53"
    - tcp: "127.0.0.2:53"
grpc:
  tcp_bind: ""
  unix_socket: /data/rolodex.sock
  shared_secret: ""
forwarders:
$forwarders
rbl:
  enabled: true
  providers: []
EOF
