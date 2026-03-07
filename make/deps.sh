#!/usr/bin/env bash
set -euo pipefail

sudo -E pacman -S --needed base-devel arch-install-scripts parted e2fsprogs \
  dosfstools rsync psmisc lsof squashfs-tools libvirt dnsmasq avahi

sudo systemctl enable --now libvirtd
sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

sudo sed -i 's/^#*enable-reflector=.*/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
sudo systemctl enable --now avahi-daemon
sudo systemctl restart avahi-daemon
