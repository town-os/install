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
# DNAT alone is not enough on a firewalld host: the forward chain ends in
#   iifname "<lan>" oifname "virbr0" reject with icmpx admin-prohibited
# so a DNAT'd packet is dropped before it reaches the guest. We add a matching
# forward ACCEPT. On firewalld we use --direct rules, which are RUNTIME-ONLY and
# apply immediately: a firewalld policy would need `--reload`, and a reload
# flushes libvirt's and netavark's runtime rules, breaking the VM's and podman's
# networking. Never reload firewalld here.
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
DNAT_ADDED=0
NFT_TABLE=0

FIREWALLD=0
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  FIREWALLD=1
fi

cleanup() {
  trap - EXIT INT TERM
  for pid in ${RELAY_PIDS[@]+"${RELAY_PIDS[@]}"}; do
    sudo kill "${pid}" 2>/dev/null || true
  done
  for port in ${FW_PORTS[@]+"${FW_PORTS[@]}"}; do
    sudo firewall-cmd --remove-port="${port}" >/dev/null 2>&1 || true
  done
  if [ "${DNAT_ADDED}" -eq 1 ]; then
    # --direct rules are runtime-only; removing them needs no reload either.
    sudo firewall-cmd --direct --remove-rule ipv4 nat PREROUTING 0 \
      -i "${LAN_IF}" -p udp --dport "${WG_PORT_LO}:${WG_PORT_HI}" \
      -j DNAT --to-destination "${GUEST_IP}" >/dev/null 2>&1 || true
    sudo firewall-cmd --direct --remove-rule ipv4 filter FORWARD 0 \
      -i "${LAN_IF}" -o "${VM_BRIDGE}" -d "${GUEST_IP}" -p udp -j ACCEPT >/dev/null 2>&1 || true
  fi
  if [ "${NFT_TABLE}" -eq 1 ]; then
    sudo nft delete table ip townos-vm >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

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
WG_OK=0
if [ "${FIREWALLD}" -eq 1 ]; then
  if sudo firewall-cmd --direct --add-rule ipv4 nat PREROUTING 0 \
       -i "${LAN_IF}" -p udp --dport "${WG_PORT_LO}:${WG_PORT_HI}" \
       -j DNAT --to-destination "${GUEST_IP}" >/dev/null 2>&1 \
     && sudo firewall-cmd --direct --add-rule ipv4 filter FORWARD 0 \
       -i "${LAN_IF}" -o "${VM_BRIDGE}" -d "${GUEST_IP}" -p udp -j ACCEPT >/dev/null 2>&1; then
    DNAT_ADDED=1
    WG_OK=1
  fi
elif command -v nft >/dev/null 2>&1; then
  if sudo nft add table ip townos-vm >/dev/null 2>&1 \
     && sudo nft add chain ip townos-vm prerouting \
          '{ type nat hook prerouting priority dstnat; policy accept; }' >/dev/null 2>&1 \
     && sudo nft add rule ip townos-vm prerouting iifname "${LAN_IF}" \
          udp dport "${WG_PORT_LO}-${WG_PORT_HI}" dnat to "${GUEST_IP}" >/dev/null 2>&1 \
     && sudo nft add chain ip townos-vm forward \
          '{ type filter hook forward priority -5; policy accept; }' >/dev/null 2>&1 \
     && sudo nft add rule ip townos-vm forward ip daddr "${GUEST_IP}" \
          udp dport "${WG_PORT_LO}-${WG_PORT_HI}" accept >/dev/null 2>&1; then
    NFT_TABLE=1
    WG_OK=1
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
