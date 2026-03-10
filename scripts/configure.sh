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

# Configure mkinitcpio for squashfs boot
# Remove autodetect — it strips modules to only those found on the build host
# (a loopback in a chroot), so USB/AHCI/SCSI drivers would be missing at boot
sed -i 's/^HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap consolefont block filesystems fsck town-squashfs)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(loop overlay squashfs nf_tables)/' /etc/mkinitcpio.conf

mkinitcpio -P

curl -sSL sh.rustup.rs >boot-rustup && chmod +x boot-rustup && ./boot-rustup -y && rm boot-rustup
source $HOME/.cargo/env && cargo install --git https://gitea.com/town-os/control-plane charon && mv /root/.cargo/bin/charon /usr/bin && rm -rf $HOME/.cargo/registry

systemctl enable town-os-make-storage.service town-os-systemcontroller.service town-os-network-diag.timer avahi-daemon.service systemd-networkd systemd-networkd-wait-online systemd-resolved sshd.service

sed -i 's/^#PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
mkdir -p /var/log/journal
# Can't symlink during chroot (bind-mounted), so install.sh handles it after chroot exits

# Bind systemd-resolved stub listener to 127.0.0.53 only — keep 127.0.0.2 free for rolodex
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/townos.conf <<RESOLVED
[Resolve]
DNSStubListener=yes
DNSStubListenerExtra=
RESOLVED

# Prevent systemd-resolved from being stopped or disabled
mkdir -p /etc/systemd/system/systemd-resolved.service.d
cat >/etc/systemd/system/systemd-resolved.service.d/no-disable.conf <<NODISABLE
[Unit]
RefuseManualStop=yes
ConditionPathExists=
NODISABLE

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
IPv6AcceptRA=yes
DNS=127.0.0.2 8.8.8.8

[DHCPv4]
RouteMetric=100

[DHCPv6]
RouteMetric=100
EOF

# Configure podman storage — use native btrfs/zfs driver so we avoid
# overlayfs-on-overlayfs (the root is squashfs+tmpfs overlay)
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<STORAGE
[storage]
driver = "$BACKEND"
graphroot = "/town-os/containers"
STORAGE


cat > /etc/issue <<'ISSUE'
This is Town OS: Go to http://town-os.local to administer the system remotely
SSH: ssh root@\4 (password: enjoytownos)

Welcome to Town OS! \r (\m)

ISSUE
echo 'Welcome to Town OS! Please access http://town-os.local in a browser.' > /etc/motd
echo 'GRUB_CMDLINE_LINUX_DEFAULT="rootwait console=ttyS0,115200 console=tty0"' >> /etc/default/grub
echo "GRUB_DISTRIBUTOR=\"Town OS\"" >> /etc/default/grub
echo GRUB_TERMINAL_OUTPUT=console >> /etc/default/grub
