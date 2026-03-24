#!/usr/bin/env bash
set -euo pipefail

if [ -f /etc/os-release ]; then
  . /etc/os-release
fi

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    sudo -E pacman -S --needed base-devel arch-install-scripts parted e2fsprogs \
      dosfstools rsync psmisc lsof squashfs-tools libvirt dnsmasq avahi qemu-full \
      socat lbzip2 podman dbus
    ;;
  ubuntu|debian|pop|linuxmint)
    sudo -E apt-get update
    sudo -E apt-get install -y \
      build-essential parted e2fsprogs dosfstools rsync psmisc lsof \
      squashfs-tools libvirt-daemon-system libvirt-clients dnsmasq-base \
      avahi-daemon qemu-system-x86 qemu-utils socat lbzip2 podman \
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

sudo -E sed -i 's/^#*enable-reflector=.*/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
sudo -E sed -i 's/^#*allow-interfaces=.*/# allow-interfaces=/' /etc/avahi/avahi-daemon.conf
sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 "avahi-daemon.service" false false
sudo -E busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager RestartUnit "ss" "avahi-daemon.service" "replace"
