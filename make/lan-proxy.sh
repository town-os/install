#!/usr/bin/env bash
set -euo pipefail

# Expose the NAT'd QEMU guest to the LAN under its mDNS name.
#
# The guest lives behind libvirt's NAT (virbr0); its mDNS announcements and its
# 192.168.122.x address are invisible/unroutable from the real network. A
# reflector wouldn't help (reflected records would point at the unroutable NAT
# address) and kernel DNAT fights libvirt's own nftables rules. Instead:
#
#   1. Publish "<IMAGE_HOSTNAME>.local" on the LAN via an avahi alias that
#      resolves to the HOST's LAN IP. avahi is scoped off the VM bridge by
#      deps.sh (deny-interfaces) so it never collides with the guest's own
#      announcement on virbr0.
#   2. Relay TCP service ports host->guest with socat. Host->guest traffic over
#      virbr0 is always permitted, so no NAT/forward-chain games.
#
# LAN device -> town-os.local -> host IP -> socat -> guest.
#
# Works under NetworkManager, systemd-networkd, or traditional networking:
# avahi binds interfaces directly, host-IP discovery uses only iproute2, and
# firewalld is optional (when absent, the ports to open are printed instead).
#
# Caveats: TCP only; ssh is mapped to 2222 so the host's own sshd isn't
# shadowed; name->IP plus the relayed ports only (no DNS-SD service browsing).
# All state is runtime-only and removed on exit (Ctrl-C to stop).

VM_NAME="${VM_NAME:-town-os}"
IMAGE="${IMAGE:-image.raw}"
IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-town-os}"
# Space-separated "listen[:guestport]" TCP mappings.
LAN_PROXY_PORTS="${LAN_PROXY_PORTS:-80 443 2222:22}"

if ! command -v avahi-publish >/dev/null 2>&1; then
  echo "error: avahi-publish not found. Install avahi:" >&2
  echo "  Fedora:        sudo dnf install avahi avahi-tools" >&2
  echo "  Arch:          sudo pacman -S avahi" >&2
  echo "  Debian/Ubuntu: sudo apt install avahi-daemon avahi-utils" >&2
  echo "(or re-run 'make deps' / 'make deps-debian')" >&2
  exit 1
fi
if ! avahi-daemon --check 2>/dev/null; then
  echo "error: avahi-daemon is not running — re-run 'make deps' or start it." >&2
  exit 1
fi
if ! command -v socat >/dev/null 2>&1; then
  echo "error: socat not found — re-run 'make deps'." >&2
  exit 1
fi

# Guest IP: same stable-MAC lease lookup as vm-ip-qemu.sh (qemu.sh seeds the
# MAC from VM_NAME, so the lease is keyed to it).
MAC=$(echo "${VM_NAME}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')
echo "Waiting for guest DHCP lease (MAC ${MAC}, up to 120s)..."
DEADLINE=$((SECONDS + 120))
DELAY=1
GUEST_IP=""
while [ "${SECONDS}" -lt "${DEADLINE}" ]; do
  GUEST_IP=$(sudo virsh net-dhcp-leases default 2>/dev/null \
    | awk -v mac="${MAC}" '$3 == mac { split($5,a,"/"); print a[1] }' | tail -1) || true
  [ -n "${GUEST_IP}" ] && break
  sleep "${DELAY}"
  DELAY=$(( DELAY * 2 > 5 ? 5 : DELAY * 2 ))
done
if [ -z "${GUEST_IP}" ]; then
  echo "error: no DHCP lease for ${VM_NAME} — is the VM running? (make qemu-fg)" >&2
  exit 1
fi

# Host LAN IP from the default route — network-manager-agnostic (iproute2 only).
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' | head -1)
if [ -z "${HOST_IP}" ]; then
  echo "error: could not determine the host's LAN IP (no default route?)" >&2
  exit 1
fi

PUBLISH_PID=""
RELAY_PIDS=()
FW_PORTS=()

cleanup() {
  trap - EXIT INT TERM
  echo
  echo "Stopping LAN proxy..."
  [ -n "${PUBLISH_PID}" ] && kill "${PUBLISH_PID}" 2>/dev/null || true
  for pid in "${RELAY_PIDS[@]}"; do
    sudo kill "${pid}" 2>/dev/null || true
  done
  for port in "${FW_PORTS[@]}"; do
    sudo firewall-cmd --remove-port="${port}" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

avahi-publish -a -R "${IMAGE_HOSTNAME}.local" "${HOST_IP}" >/dev/null 2>&1 &
PUBLISH_PID=$!

FIREWALLD=0
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  FIREWALLD=1
fi

echo "Publishing ${IMAGE_HOSTNAME}.local -> ${HOST_IP} (host), relaying to ${GUEST_IP} (guest):"
NOFW_PORTS=""
for entry in ${LAN_PROXY_PORTS}; do
  lp="${entry%%:*}"
  gp="${entry##*:}"
  sudo socat "TCP-LISTEN:${lp},fork,reuseaddr" "TCP:${GUEST_IP}:${gp}" &
  RELAY_PIDS+=($!)
  if [ "${FIREWALLD}" -eq 1 ]; then
    # Only open (and later close) ports that weren't already open.
    if ! sudo firewall-cmd --query-port="${lp}/tcp" >/dev/null 2>&1; then
      sudo firewall-cmd --add-port="${lp}/tcp" >/dev/null
      FW_PORTS+=("${lp}/tcp")
    fi
  else
    NOFW_PORTS="${NOFW_PORTS} ${lp}/tcp"
  fi
  echo "  ${HOST_IP}:${lp} -> ${GUEST_IP}:${gp}"
done
if [ -n "${NOFW_PORTS}" ]; then
  echo "note: firewalld not detected — make sure these ports are open on the host:${NOFW_PORTS}"
fi
echo "Press Ctrl-C to stop (removes the alias, relays, and firewall openings)."
wait
