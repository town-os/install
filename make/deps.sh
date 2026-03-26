#!/usr/bin/env bash
set -euo pipefail

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    sudo -E pacman -S --needed base-devel arch-install-scripts parted e2fsprogs \
      dosfstools rsync psmisc lsof squashfs-tools libvirt dnsmasq qemu-full \
      socat lbzip2 pv podman dbus
    ;;
  ubuntu|debian|pop|linuxmint)
    sudo -E apt-get update
    sudo -E apt-get install -y \
      build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
      qemu-system-x86 qemu-utils socat lbzip2 pv podman \
      dbus util-linux
    ;;
  *)
    echo "Unsupported distro: ${ID:-unknown}" >&2
    echo "Install dependencies manually — see CLAUDE.md for package lists" >&2
    exit 1
    ;;
esac

sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "libvirtd.service" false false
sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager StartUnit "ss" "libvirtd.service" "replace"
sudo -E virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
sudo -E virsh net-start default 2>/dev/null || true
sudo -E virsh net-autostart default

# Enable mDNS in systemd-resolved for .local resolution across the VM bridge.
# This replaces avahi-daemon — systemd-resolved handles mDNS natively.
sudo -E mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nMulticastDNS=yes\n' | sudo -E tee /etc/systemd/resolved.conf.d/mdns.conf >/dev/null

# Ensure nsswitch.conf uses systemd-resolved (resolve) for .local — remove
# avahi's mdns_minimal if present from a previous install.
if grep -q 'mdns_minimal' /etc/nsswitch.conf; then
  sudo -E sed -i 's/ mdns_minimal \[NOTFOUND=return\]//' /etc/nsswitch.conf
fi
if ! grep -q 'resolve' /etc/nsswitch.conf; then
  sudo -E sed -i 's/^hosts:.*/hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf
fi

# Enable mDNS on the VM bridge so the host can resolve guest .local names
VM_BRIDGE="${VM_BRIDGE:-virbr0}"
sudo -E resolvectl mdns "${VM_BRIDGE}" yes 2>/dev/null || true

sudo -E systemctl reload systemd-resolved 2>/dev/null || true
