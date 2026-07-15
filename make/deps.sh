#!/usr/bin/env bash
set -euo pipefail

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    sudo pacman -S --needed base-devel arch-install-scripts parted e2fsprogs \
      dosfstools rsync psmisc lsof squashfs-tools libvirt dnsmasq qemu-full \
      socat lbzip2 pv podman dbus
    ;;
  ubuntu|debian|pop|linuxmint)
    sudo apt-get update
    sudo apt-get install -y \
      build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
      qemu-system-x86 qemu-utils socat lbzip2 pv podman \
      dbus util-linux
    ;;
  fedora*|rhel|centos|rocky|almalinux)
    # Image building still requires Arch-specific tools (pacstrap, mkinitcpio,
    # arch-chroot) — build in an Arch container. These host deps cover VM
    # launching. qemu-system-x86 provides the x86_64 emulator the VM scripts
    # use (needed when the host is aarch64, e.g. Fedora Asahi Remix).
    sudo dnf install -y \
      gcc make parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt libvirt-client dnsmasq \
      qemu-system-x86 qemu-img socat lbzip2 pv podman util-linux
    ;;
  *)
    echo "Unsupported distro: ${ID:-unknown}" >&2
    echo "Install dependencies manually — see CLAUDE.md for package lists" >&2
    exit 1
    ;;
esac

# Ensure the host loop module exposes partition nodes for the image build.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/deps-loop.sh"
ensure_loop_partitions

sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "libvirtd.service" false false
sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager StartUnit "ss" "libvirtd.service" "replace"
sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

# Enable mDNS in systemd-resolved for .local resolution across the VM bridge.
# systemd-resolved handles mDNS natively — no avahi-daemon needed.
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nMulticastDNS=yes\n' | sudo tee /etc/systemd/resolved.conf.d/mdns.conf >/dev/null

# Ensure nsswitch.conf uses systemd-resolved (resolve) for .local — remove
# avahi's mdns_minimal if present from a previous install.
if grep -q 'mdns_minimal' /etc/nsswitch.conf; then
  sudo sed -i 's/ mdns_minimal \[NOTFOUND=return\]//' /etc/nsswitch.conf
fi
if ! grep -q 'resolve' /etc/nsswitch.conf; then
  sudo sed -i 's/^hosts:.*/hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf
fi

# Enable mDNS on the VM bridge so the host can resolve guest .local names
VM_BRIDGE="${VM_BRIDGE:-virbr0}"
sudo resolvectl mdns "${VM_BRIDGE}" yes 2>/dev/null || true

# qemu-bridge-helper (setuid, used by `make qemu`/`qemu-fg` to attach the guest
# to the NAT bridge) refuses any bridge not listed in /etc/qemu/bridge.conf,
# failing with "access denied by acl file" — so the VM gets no network, or won't
# launch at all. The file frequently doesn't exist on a fresh install. Ensure it
# allows the VM bridge; idempotent (only appends the rule when absent).
sudo mkdir -p /etc/qemu
if ! sudo grep -qxF "allow ${VM_BRIDGE}" /etc/qemu/bridge.conf 2>/dev/null; then
  echo "allow ${VM_BRIDGE}" | sudo tee -a /etc/qemu/bridge.conf >/dev/null
fi

# Hosts running firewalld (Fedora & friends — Arch/Debian don't enable it by
# default): the 'libvirt' zone holding the bridge allows dhcp/dns/ssh/tftp but
# NOT mdns, and ends in a catch-all reject — guest mDNS (UDP 5353) never
# reaches resolved. Allow it permanently.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --zone=libvirt --add-service=mdns >/dev/null 2>&1 || true

  # The policy that lets LAN->guest WireGuard forwarding past firewalld's reject,
  # so a phone on the wireless network can reach the VM's WireGuard (make/vm-relay.sh
  # DNATs the port range; without this the DNAT'd packet is rejected on the way in
  # and the tunnel silently never handshakes).
  #
  # It has to be a POLICY: --direct rules land in the legacy ip filter table, and
  # nftables evaluates each table's chains independently, so an accept there
  # cannot override firewalld's reject in `inet firewalld`; and nft cannot write
  # into firewalld's table directly (it is owner-flagged, EPERM). Set up here, at
  # deps time, because creating it costs a --reload -- doing it during a VM launch
  # would flush libvirt/netavark rules underneath a running VM.
  #
  # Delete-then-create so a half-configured policy from an earlier run cannot
  # linger. Inert with no VM running: nothing answers on the guest address.
  LAN_IF=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  LAN_ZONE=$(sudo firewall-cmd --get-zone-of-interface="${LAN_IF}" 2>/dev/null \
    || sudo firewall-cmd --get-default-zone 2>/dev/null)
  if [ -n "${LAN_ZONE}" ]; then
    sudo firewall-cmd --permanent --delete-policy=townos-vm >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --new-policy=townos-vm >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --policy=townos-vm --add-ingress-zone="${LAN_ZONE}" >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --policy=townos-vm --add-egress-zone=libvirt >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --policy=townos-vm --set-target=CONTINUE >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --policy=townos-vm \
      --add-rich-rule='rule family="ipv4" destination address="192.168.122.0/24" port port="51820-55915" protocol="udp" accept' \
      >/dev/null 2>&1 || true
  fi

  sudo firewall-cmd --reload >/dev/null 2>&1 || true
  # firewall-cmd --reload flushes netavark's NAT/DNS rules, silently breaking
  # networking for running podman containers — restore them.
  sudo podman network reload --all >/dev/null 2>&1 || true
fi

sudo systemctl reload systemd-resolved 2>/dev/null || true
