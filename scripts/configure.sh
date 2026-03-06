#!/bin/sh

set -euo pipefail

town_config() {
  grep "^${1}:" /usr/lib/town-os/town-os.yaml | awk '{ print $2 }' | tr -d '"' | tr -d "'"
}

BACKEND=$(town_config storage_backend)
BACKEND="${BACKEND:-btrfs}"

chown root:root /usr/lib/town-os/scripts/*.sh
chmod +x /usr/lib/town-os/scripts/*.sh

echo 'root:enjoytownos' | chpasswd
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen
echo LANG=en_US.UTF-8 >/etc/locale.conf
echo KEYMAP=us >/etc/vconsole.conf
echo town-os >/etc/hostname
mkinitcpio -P

curl -sSL sh.rustup.rs >boot-rustup && chmod +x boot-rustup && ./boot-rustup -y && rm boot-rustup
source $HOME/.cargo/env && cargo install --git https://gitea.com/town-os/control-plane charon && mv /root/.cargo/bin/charon /usr/bin && rm -rf $HOME/.cargo/registry

systemctl enable make-storage.service systemcontroller.service avahi-daemon.service systemd-networkd systemd-resolved
systemctl disable avahi-daemon.socket

if [ "$BACKEND" = "zfs" ]
then
  systemctl enable zfs-mount.service
  echo DO_OVERLAY_MOUNTS=yes >> /etc/default/zfs
  echo ZPOOL_IMPORT_ALL_VISIBLE=yes >> /etc/default/zfs
fi

cat >/etc/systemd/network/10-ethernet.network <<EOF
[Match]
Name=en*

[Network]
DHCP=yes
[Link]
RequiredForOnline=routable
EOF

echo Welcome to Town OS >> /etc/issue
echo GRUB_CMDLINE_LINUX_DEFAULT= >> /etc/default/grub
echo "GRUB_DISTRIBUTOR=\"Town OS\"" >> /etc/default/grub
echo GRUB_TERMINAL_OUTPUT=console >> /etc/default/grub
