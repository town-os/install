#!/usr/bin/env bash
# Install host dependencies on Debian/Ubuntu.
# NOTE: Image building still requires Arch-specific tools (pacstrap, mkinitcpio,
# arch-chroot). This script sets up a podman container with Arch Linux for the
# actual build. Only VM launching (QEMU) runs natively on the Debian host.
set -euo pipefail

sudo -E apt-get update
sudo -E apt-get install -y \
  build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
  squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
  avahi-daemon qemu-system-x86 qemu-utils socat lbzip2 podman \
  dbus util-linux

sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "libvirtd.service" false false
sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager StartUnit "ss" "libvirtd.service" "replace"
sudo -E virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
sudo -E virsh net-start default 2>/dev/null || true
sudo -E virsh net-autostart default

sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "avahi-daemon.service" false false
sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager RestartUnit "ss" "avahi-daemon.service" "replace"

echo ""
echo "Host dependencies installed."
echo ""
echo "IMPORTANT: Image building requires Arch Linux tools (pacstrap, mkinitcpio)."
echo "Use the Arch container build method:"
echo "  make image-container"
echo ""
echo "Or run 'make qemu' / 'make qemu-fg' to launch a pre-built image."
