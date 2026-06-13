#!/usr/bin/env bash
set -euo pipefail

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    sudo pacman -S --needed base-devel arch-install-scripts parted e2fsprogs \
      dosfstools rsync psmisc lsof squashfs-tools libvirt dnsmasq qemu-full \
      socat lbzip2 pv podman dbus avahi
    ;;
  ubuntu|debian|pop|linuxmint)
    sudo apt-get update
    sudo apt-get install -y \
      build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
      qemu-system-x86 qemu-utils socat lbzip2 pv podman \
      dbus util-linux avahi-daemon avahi-utils
    ;;
  fedora*|rhel|centos|rocky|almalinux)
    # Image building still requires Arch-specific tools (pacstrap, mkinitcpio,
    # arch-chroot) — build in an Arch container. These host deps cover VM
    # launching. qemu-system-x86 provides the x86_64 emulator the VM scripts
    # use (needed when the host is aarch64, e.g. Fedora Asahi Remix).
    sudo dnf install -y \
      gcc make parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt libvirt-client dnsmasq \
      qemu-system-x86 qemu-img socat lbzip2 pv podman util-linux \
      avahi avahi-tools
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
# This replaces avahi-daemon — systemd-resolved handles mDNS natively.
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

# Hosts running firewalld (Fedora & friends — Arch/Debian don't enable it by
# default): the 'libvirt' zone holding the bridge allows dhcp/dns/ssh/tftp but
# NOT mdns, and ends in a catch-all reject — guest mDNS (UDP 5353) never
# reaches resolved. Allow it permanently.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --zone=libvirt --add-service=mdns >/dev/null 2>&1 || true
  sudo firewall-cmd --reload >/dev/null 2>&1 || true
  # firewall-cmd --reload flushes netavark's NAT/DNS rules, silently breaking
  # networking for running podman containers — restore them.
  sudo podman network reload --all >/dev/null 2>&1 || true
fi

# avahi publishes the LAN-side mDNS alias for `make lan-proxy`. It MUST be
# scoped OFF the VM bridge: the guest owns its name on the bridge, and a host
# responder probing the same name there would trigger mDNS conflict resolution
# and force the guest to rename itself (town-os -> town-os-2). resolved keeps
# handling mDNS on the bridge; avahi handles the LAN side.
if [ -f /etc/avahi/avahi-daemon.conf ]; then
  if grep -q '^[#[:space:]]*deny-interfaces=' /etc/avahi/avahi-daemon.conf; then
    sudo sed -i "s/^[#[:space:]]*deny-interfaces=.*/deny-interfaces=${VM_BRIDGE}/" /etc/avahi/avahi-daemon.conf
  else
    sudo sed -i "/^\[server\]/a deny-interfaces=${VM_BRIDGE}" /etc/avahi/avahi-daemon.conf
  fi
fi
sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "avahi-daemon.service" false false
sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager RestartUnit "ss" "avahi-daemon.service" "replace"

sudo systemctl reload systemd-resolved 2>/dev/null || true
