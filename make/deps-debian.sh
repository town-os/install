#!/usr/bin/env bash
# Install host dependencies on Debian/Ubuntu.
# NOTE: Image building still requires Arch-specific tools (pacstrap, mkinitcpio,
# arch-chroot). This script sets up a podman container with Arch Linux for the
# actual build. Only VM launching (QEMU) runs natively on the Debian host.
set -euo pipefail

sudo apt-get update
sudo apt-get install -y \
  build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
  squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
  qemu-system-x86 qemu-utils socat lbzip2 pv podman \
  dbus util-linux

sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "libvirtd.service" false false
sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager StartUnit "ss" "libvirtd.service" "replace"
sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

# Enable mDNS in systemd-resolved for .local resolution across the VM bridge
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nMulticastDNS=yes\n' | sudo tee /etc/systemd/resolved.conf.d/mdns.conf >/dev/null
sudo resolvectl mdns virbr0 yes 2>/dev/null || true
sudo systemctl reload systemd-resolved 2>/dev/null || true

echo ""
echo "Host dependencies installed."
echo ""
echo "Image building requires Arch Linux tools (pacstrap, mkinitcpio). On this"
echo "non-Arch host 'make image' automatically builds inside a same-architecture"
echo "Arch container ('make image-container' forces it). The image produced is"
echo "this host's architecture (no cross-build, no emulation)."
echo ""
echo "Or run 'make qemu' / 'make qemu-fg' to launch a pre-built image."
