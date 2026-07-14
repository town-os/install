#!/usr/bin/env bash
set -euo pipefail

# Expose the NAT'd QEMU guest to the LAN so other devices on the wireless network
# — a phone running the Town OS client — can reach it. On by default; set
# VM_LAN=0 to turn it off.
#
# The guest lives behind libvirt's NAT (virbr0): LAN devices can neither route to
# 192.168.122.x nor resolve its mDNS name. A passthrough bridge is impossible on
# a WiFi-only host (802.11 won't carry a second MAC behind the station), so the
# host has to stand in for the guest. Two mechanisms, each where it belongs:
#
#   TCP (the control API on 5309 — what the Android client enrolls against — plus
#   the UI on 80/443 and ssh on 2222 so it doesn't shadow the host's own sshd):
#   socat. The connection TERMINATES on the host and a fresh one is opened
#   host->guest over the bridge, which is always permitted, so this needs no
#   forwarding rules at all — only the host's own INPUT opened.
#
#   UDP (WireGuard): a single nft DNAT rule for the WHOLE port range. There is one
#   UDP port per custom network, derived from the network's name
#   (51820 + sha256("port|"+name) % 4096 — town-os/src/wireguard/ipam.go), so the
#   port isn't known until a network exists, and we can't enumerate them (GET
#   /networks needs a bearer token). socat cannot help here: it is one process per
#   port and the space is 4096 wide. One range DNAT covers every network that will
#   ever exist, with no names and no discovery.
#
# DNAT alone is NOT enough on a firewalld host. Its forward chain reads
#
#   iifname "<lan>" oifname "virbr0" jump filter_FWD_<zone>
#   iifname "<lan>" oifname "virbr0" reject with icmpx admin-prohibited
#
# so unless something upstream of that reject accepts, the DNAT'd packet dies
# before reaching the guest -- silently, and WireGuard being UDP, the phone just
# never handshakes while cheerfully reporting "connected".
#
# The accept MUST live inside firewalld's own `inet firewalld` table. Two ways
# that look like they work and do NOT:
#
#   - `firewall-cmd --direct` rules land in the legacy `ip filter` table
#     (iptables-nft). nftables evaluates every base chain at a hook
#     INDEPENDENTLY, so an accept there cannot stop firewalld's reject in a
#     different table from dropping the packet.
#   - `nft insert` straight into firewalld's chain is refused: firewalld owns its
#     table (`flags owner`), so the kernel returns EPERM.
#
# The only mechanism that expresses "from the LAN zone into the libvirt zone,
# accept" is a firewalld POLICY, and creating one needs --permanent + --reload.
# A reload flushes libvirt's and netavark's runtime rules, so it also has to be
# followed by `podman network reload --all` (libvirt reinstalls its own). We
# therefore create the policy ONCE and leave it: it is inert with no VM running,
# since nothing answers on the guest address.
#
# The DNAT itself stays a runtime-only --direct rule, torn down on exit.
#
# NOTE ON CONNTRACK: NAT rules are evaluated only on a flow's FIRST packet. A
# phone that was already retrying handshakes against a broken relay has a
# conntrack entry that bypasses a newly-added DNAT, so it keeps failing until its
# source port changes (toggle the tunnel) or the entry times out.
#
# The peer's Endpoint needs no manual override: the box derives it from the
# address the enrolling client DIALED — the Host header of its /networks/peers/add
# request (peerEndpointHost, town-os/src/svc/systemcontroller). A phone enrolling
# through this relay reaches the API at ${HOST_IP}:5309, so ${HOST_IP} is the
# endpoint it is handed, and the DNAT below forwards the WireGuard range on that
# same address. (It used to derive Endpoint from the box's own view — its public
# IP, falling back to 192.168.122.50 inside QEMU — and neither is reachable from
# the phone, so every handshake vanished and the tunnel looked simply dead.)
#
# All state is runtime-only — socat processes, firewall openings and DNAT rules —
# and is torn down on exit.

GUEST_IP="${GUEST_IP:-}"
VM_BRIDGE="${VM_BRIDGE:-virbr0}"
VM_RELAY_TCP="${VM_RELAY_TCP:-5309 80 443 2222:22}"
# The WireGuard listen-port space (ListenPortForName: 51820 + hash % 4096).
WG_PORT_LO="${WG_PORT_LO:-51820}"
WG_PORT_HI="${WG_PORT_HI:-55915}"

if [ -z "${GUEST_IP}" ]; then
  echo "vm-relay: GUEST_IP not set" >&2
  exit 1
fi
if ! command -v socat >/dev/null 2>&1; then
  echo "vm-relay: socat not found -- re-run 'make deps'" >&2
  exit 1
fi

# Host LAN address and the interface it lives on: what the phone talks to, and
# what the DNAT rule matches inbound traffic on. iproute2 only, so this is
# network-manager-agnostic.
read -r LAN_IF HOST_IP <<<"$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "src") s = $(i + 1) } }
          END { print d, s }')"
if [ -z "${HOST_IP}" ] || [ -z "${LAN_IF}" ]; then
  echo "vm-relay: could not determine the host's LAN interface/IP (no default route?)" >&2
  exit 1
fi

RELAY_PIDS=()
FW_PORTS=()

# The firewalld policy that permits LAN->guest forwarding, and the zone the LAN
# interface is in (its ingress zone).
FW_POLICY="townos-vm"
LAN_ZONE=""

FIREWALLD=0
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  FIREWALLD=1
  LAN_ZONE=$(sudo firewall-cmd --get-zone-of-interface="${LAN_IF}" 2>/dev/null || true)
  if [ -z "${LAN_ZONE}" ]; then
    LAN_ZONE=$(sudo firewall-cmd --get-default-zone 2>/dev/null || true)
  fi
fi

# Remove any DNAT/forward state we (or a previous, crashed run) may have left
# behind, so setup always starts from a known-empty slate and never stacks
# duplicate rules. Safe to call when nothing is installed.
#
# The removals are enumerated explicitly rather than looped: firewall-cmd
# --remove-rule exits 0 even when the rule does not exist, so a
# `while remove; do :; done` loop would spin forever.
teardown_forwarding() {
  for _ in 1 2 3; do  # a bounded sweep clears duplicates from earlier runs
    sudo firewall-cmd --direct --remove-rule ipv4 nat PREROUTING 0 \
      -i "${LAN_IF}" -p udp --dport "${WG_PORT_LO}:${WG_PORT_HI}" \
      -j DNAT --to-destination "${GUEST_IP}" >/dev/null 2>&1 || true
    # The old, ineffective forward accept: it landed in the legacy ip filter
    # table where it could never override firewalld's reject. Remove it if an
    # older build of this script left one behind.
    sudo firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 \
      -i "${LAN_IF}" -o "${VM_BRIDGE}" -d "${GUEST_IP}" -p udp -j ACCEPT >/dev/null 2>&1 || true
  done
  sudo nft delete table ip townos-vm >/dev/null 2>&1 || true

  # Drop every accept we added to libvirt's guest_input chain. Matched by handle,
  # since the rule text as listed differs from the text we wrote.
  while :; do
    local handle
    handle=$(sudo nft -a list chain ip libvirt_network guest_input 2>/dev/null \
      | awk -v ip="${GUEST_IP}" '$0 ~ ip && /udp dport/ { for (i = 1; i <= NF; i++) if ($i == "handle") print $(i + 1) }' \
      | head -1)
    [ -n "${handle}" ] || break
    sudo nft delete rule ip libvirt_network guest_input handle "${handle}" >/dev/null 2>&1 || break
  done
}

# libvirt's OWN nft table (ip libvirt_network) rejects every NEW inbound
# connection to the guest -- its guest_input chain accepts only
# established/related and rejects the rest. That reject is what silently ate the
# phone's WireGuard handshakes.
#
# It cannot be overridden from another table: nftables evaluates each table's
# chains independently, so a reject anywhere is final and no accept elsewhere
# rescues the packet. The accept has to go INSIDE libvirt's chain, ahead of its
# reject. libvirt does not owner-flag this table, so we may insert into it.
#
# This is runtime state that libvirt rebuilds whenever the network is (re)started
# (virsh net-destroy/net-start, libvirtd restart, host reboot), so it is
# re-asserted on every launch rather than set up once.
allow_libvirt_input() {
  sudo nft insert rule ip libvirt_network guest_input \
    oif "\"${VM_BRIDGE}\"" ip daddr "${GUEST_IP}" \
    udp dport "${WG_PORT_LO}-${WG_PORT_HI}" counter accept >/dev/null 2>&1
}

# Expire stale UDP conntrack entries. NAT is evaluated only on a flow's FIRST
# packet, so a phone that was already retrying handshakes against a broken relay
# keeps reusing a conntrack entry that predates our DNAT and never gets
# translated -- it stays wedged until its source port changes. Briefly collapsing
# the UDP timeout expires those entries without needing the conntrack tool (which
# is not installed by default).
flush_stale_udp_conntrack() {
  local old
  old=$(sudo sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null) || return 0
  sudo sysctl -w net.netfilter.nf_conntrack_udp_timeout=1 >/dev/null 2>&1 || return 0
  sleep 2
  sudo sysctl -w "net.netfilter.nf_conntrack_udp_timeout=${old}" >/dev/null 2>&1 || true
}

cleanup() {
  trap - EXIT INT TERM
  for pid in ${RELAY_PIDS[@]+"${RELAY_PIDS[@]}"}; do
    sudo kill "${pid}" 2>/dev/null || true
  done
  for port in ${FW_PORTS[@]+"${FW_PORTS[@]}"}; do
    sudo firewall-cmd --remove-port="${port}" >/dev/null 2>&1 || true
  done
  teardown_forwarding
  # The firewalld policy is deliberately LEFT in place: creating it costs a
  # --reload (which flushes libvirt/netavark rules), and it is inert without a
  # VM answering on the guest address.
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Ensure the firewalld policy that lets LAN->guest forwarding past firewalld's
# reject exists. Created once, permanently; see the header. Idempotent.
ensure_fw_policy() {
  local guest_net="${GUEST_IP%.*}.0/24"
  local rich="rule family=\"ipv4\" destination address=\"${guest_net}\" port port=\"${WG_PORT_LO}-${WG_PORT_HI}\" protocol=\"udp\" accept"

  if sudo firewall-cmd --info-policy="${FW_POLICY}" >/dev/null 2>&1 \
     && sudo firewall-cmd --permanent --policy="${FW_POLICY}" --query-rich-rule="${rich}" >/dev/null 2>&1; then
    return 0  # already correct; do not pay for a reload
  fi

  echo "  setting up the firewalld policy that permits LAN->guest forwarding (one-time)..."
  # Rebuild from scratch so a half-configured policy from an earlier run cannot
  # linger: delete, then recreate.
  sudo firewall-cmd --permanent --delete-policy="${FW_POLICY}" >/dev/null 2>&1 || true
  sudo firewall-cmd --permanent --new-policy="${FW_POLICY}" >/dev/null 2>&1 || return 1
  sudo firewall-cmd --permanent --policy="${FW_POLICY}" --add-ingress-zone="${LAN_ZONE}" >/dev/null 2>&1 || return 1
  sudo firewall-cmd --permanent --policy="${FW_POLICY}" --add-egress-zone=libvirt >/dev/null 2>&1 || return 1
  sudo firewall-cmd --permanent --policy="${FW_POLICY}" --set-target=CONTINUE >/dev/null 2>&1 || return 1
  sudo firewall-cmd --permanent --policy="${FW_POLICY}" --add-rich-rule="${rich}" >/dev/null 2>&1 || return 1
  sudo firewall-cmd --reload >/dev/null 2>&1 || return 1
  # A reload flushes netavark's rules, silently breaking networking for running
  # podman containers; libvirt reinstalls its own on the reload signal.
  sudo podman network reload --all >/dev/null 2>&1 || true
}

# Open the host's INPUT for a socat listen port, runtime-only, and only if it
# wasn't already open (so cleanup never closes a port the user opened themselves).
open_port() {  # $1 = port, $2 = tcp|udp
  if [ "${FIREWALLD}" -eq 1 ]; then
    if ! sudo firewall-cmd --query-port="$1/$2" >/dev/null 2>&1; then
      sudo firewall-cmd --add-port="$1/$2" >/dev/null
      FW_PORTS+=("$1/$2")
    fi
  else
    NOFW_PORTS="${NOFW_PORTS:-} $1/$2"
  fi
}

echo "LAN access: ${HOST_IP} (host, ${LAN_IF}) -> ${GUEST_IP} (guest)"

# KO any socat relays a previous run left behind (killed without its trap
# running): two listeners on one port would otherwise fight over the connection.
sudo pkill -f "socat TCP-LISTEN:.*TCP:${GUEST_IP}:" >/dev/null 2>&1 || true

for entry in ${VM_RELAY_TCP}; do
  lp="${entry%%:*}"
  gp="${entry##*:}"
  sudo socat "TCP-LISTEN:${lp},fork,reuseaddr" "TCP:${GUEST_IP}:${gp}" &
  RELAY_PIDS+=($!)
  open_port "${lp}" tcp
  echo "  tcp  ${HOST_IP}:${lp} -> ${GUEST_IP}:${gp}"
done

# WireGuard: DNAT the whole listen-port range, so every custom network works
# without naming it. Best-effort — a failure here costs WireGuard, not the API.
#
# Tear down first: a previous run that was killed (rather than exiting through
# its trap) leaves its DNAT behind, and re-adding would stack duplicates.
teardown_forwarding

WG_OK=0
if [ "${FIREWALLD}" -eq 1 ]; then
  if ensure_fw_policy \
     && sudo firewall-cmd --direct --add-rule ipv4 nat PREROUTING 0 \
          -i "${LAN_IF}" -p udp --dport "${WG_PORT_LO}:${WG_PORT_HI}" \
          -j DNAT --to-destination "${GUEST_IP}" >/dev/null 2>&1 \
     && allow_libvirt_input; then
    WG_OK=1
    flush_stale_udp_conntrack
  fi
elif command -v nft >/dev/null 2>&1; then
  # No firewalld (Arch/Debian): no reject to get past, so our own table suffices.
  if sudo nft add table ip townos-vm >/dev/null 2>&1 \
     && sudo nft add chain ip townos-vm prerouting \
          '{ type nat hook prerouting priority dstnat; policy accept; }' >/dev/null 2>&1 \
     && sudo nft add rule ip townos-vm prerouting iifname "${LAN_IF}" \
          udp dport "${WG_PORT_LO}-${WG_PORT_HI}" dnat to "${GUEST_IP}" >/dev/null 2>&1 \
     && sudo nft add chain ip townos-vm forward \
          '{ type filter hook forward priority -5; policy accept; }' >/dev/null 2>&1 \
     && sudo nft add rule ip townos-vm forward ip daddr "${GUEST_IP}" \
          udp dport "${WG_PORT_LO}-${WG_PORT_HI}" accept >/dev/null 2>&1 \
     && allow_libvirt_input; then
    WG_OK=1
    flush_stale_udp_conntrack
  else
    sudo nft delete table ip townos-vm >/dev/null 2>&1 || true
  fi
fi

if [ "${WG_OK}" -eq 1 ]; then
  echo "  udp  ${HOST_IP}:${WG_PORT_LO}-${WG_PORT_HI} -> ${GUEST_IP} (WireGuard, all networks)"
else
  echo "  udp  WireGuard forwarding NOT set up (no firewalld/nft) -- tunnels will not connect" >&2
fi

if [ -n "${NOFW_PORTS:-}" ]; then
  echo "  note: no firewalld -- ensure these are open on the host:${NOFW_PORTS}"
fi

echo
echo "  Town OS client: box address  http://${HOST_IP}:5309"
echo "                  (the box hands out ${HOST_IP} as the peer Endpoint — no override needed)"
echo

wait
