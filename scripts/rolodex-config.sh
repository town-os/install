#!/bin/sh
# Generate rolodex's runtime config, choosing DNS forwarders from DHCP.
#
# rolodex is the system resolver: systemd-resolved is pointed at 127.0.0.2
# first, so rolodex always answers first and only *forwards* names it isn't
# authoritative for. This script picks what it forwards TO:
#
#   - DHCP-provided DNS servers when the lease offers any. That honors the
#     local network's resolver (LAN/split-horizon names, captive portals) and,
#     on the QEMU dev VM, the libvirt NAT resolver at 192.168.122.1 — which
#     forwards through the host and so keeps working on networks that drop raw
#     outbound UDP/53 (e.g. guest WiFi).
#   - Cloudflare/Google ONLY when the lease offers no DNS.
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
# (forwarding to 127.0.0.x would loop back into rolodex itself).
dhcp_dns="$(
  awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null \
    | tr ' ' '\n' \
    | grep -vE '^(127\.|::1$)' \
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
