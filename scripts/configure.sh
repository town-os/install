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
echo '/usr/lib/town-os/scripts/ttyforce-status.sh' >> /etc/shells
useradd -m -s /usr/lib/town-os/scripts/ttyforce-status.sh status
echo 'status:enjoytownos' | chpasswd

# SSH authorized_keys symlinks → persistent btrfs storage
mkdir -p /root/.ssh
ln -sf /town-os/ssh/authorized_keys/root /root/.ssh/authorized_keys
mkdir -p /home/status/.ssh
ln -sf /town-os/ssh/authorized_keys/status /home/status/.ssh/authorized_keys
chown -R status:status /home/status/.ssh

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen
echo LANG=en_US.UTF-8 >/etc/locale.conf
echo KEYMAP=us >/etc/vconsole.conf
echo "${IMAGE_HOSTNAME:-town-os}" >/etc/hostname

# Configure mkinitcpio for squashfs boot
# Remove autodetect — it strips modules to only those found on the build host
# (a loopback in a chroot), so USB/AHCI/SCSI drivers would be missing at boot
sed -i \
  -e 's/^HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap consolefont block filesystems fsck town-installer town-squashfs)/' \
  -e 's/^MODULES=.*/MODULES=(loop overlay squashfs zstd nf_tables ahci sd_mod virtio_blk virtio_scsi nvme usb_storage uas e1000 e1000e igb ixgbe i40e ice virtio_net r8169 tg3 bnxt_en mlx4_en mlx5_core cfg80211 mac80211 iwlwifi iwlmvm ath9k ath10k_pci ath11k_pci brcmfmac mt76x2u rtw88_pci rtw89_pci)/' \
  /etc/mkinitcpio.conf

curl -sSL sh.rustup.rs >boot-rustup && chmod +x boot-rustup && ./boot-rustup -y && rm boot-rustup
source $HOME/.cargo/env && cargo install --git https://gitea.com/town-os/control-plane charon && mv /root/.cargo/bin/charon /usr/bin

# Install ttyforce — interactive installer TUI for network + disk provisioning
if [ -n "${TTYFORCE_DEV:-}" ]; then
  cargo install --git https://github.com/erikh/ttyforce ttyforce
else
  cargo install ttyforce
fi
mv /root/.cargo/bin/ttyforce /usr/bin

rm -rf $HOME/.cargo/registry

mkinitcpio -P

# --- Trim linux-firmware to router essentials ---
# Keep only firmware for drivers in MODULES= plus basic VGA console.
# mkinitcpio already bundled what it needs into the initrd above.
FW=/usr/lib/firmware
mkdir -p /tmp/fw-keep
# WiFi, Ethernet, and GPU framebuffer firmware
for d in ath9k_htc ath10k ath11k brcm mediatek rtw88 rtw89 \
         rtl_nic tigon bnxt intel i40e ice mellanox \
         amdgpu radeon i915 nvidia; do
  [ -d "$FW/$d" ] && mv "$FW/$d" /tmp/fw-keep/
done
mv $FW/iwlwifi-* /tmp/fw-keep/ 2>/dev/null || true
mv $FW/regulatory.* /tmp/fw-keep/ 2>/dev/null || true
# Remove everything else and restore keepers
rm -rf $FW/*
mv /tmp/fw-keep/* $FW/
rmdir /tmp/fw-keep

# --- Remove build-only dependencies ---
# Remove only known build-only packages — do NOT use -s (cascade) on base-devel
# because it can pull out grep, sed, gawk, findutils, etc. that the runtime needs
rustup self uninstall -y
pacman -Rdd --noconfirm gcc binutils autoconf automake bison flex \
  libtool m4 make fakeroot debugedit groff texinfo patch pkgconf clang 2>/dev/null || true
pacman -Scc --noconfirm

# systemd unit enablement is handled via D-Bus in make/install.sh (Podman container phase)

sed -i \
  -e 's/^#PermitRootLogin .*/PermitRootLogin yes/' \
  -e 's/^#PasswordAuthentication .*/PasswordAuthentication yes/' \
  /etc/ssh/sshd_config

# Disable password auth per-user when their authorized_keys exists
cat >>/etc/ssh/sshd_config <<'SSHD'

Match exec "test -s /town-os/ssh/authorized_keys/%u"
    PasswordAuthentication no
SSHD
mkdir -p /var/log/journal
# Can't symlink during chroot (bind-mounted), so make/install.sh handles it after chroot exits

# Configure systemd-resolved: keep 127.0.0.2 free for rolodex, enable mDNS
# for .local hostname advertisement (replaces avahi-daemon)
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/townos.conf <<RESOLVED
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.1.1.1 8.8.8.8
DNSStubListener=yes
DNSStubListenerExtra=
MulticastDNS=yes
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
  # zfs-mount.service enablement is handled via D-Bus in make/install.sh (Podman container phase)
  echo DO_OVERLAY_MOUNTS=yes >> /etc/default/zfs
  echo ZPOOL_IMPORT_ALL_VISIBLE=yes >> /etc/default/zfs
fi

# Network config is written by ttyforce at boot and persisted via btrfs etc overlay.
# No catch-all network config here — only the ttyforce-selected interface should be active.

# Configure podman storage — use native btrfs/zfs driver so we avoid
# overlayfs-on-overlayfs (the root is squashfs+tmpfs overlay)
mkdir -p /etc/containers
cat >/etc/containers/storage.conf <<STORAGE
[storage]
driver = "$BACKEND"
graphroot = "/town-os/containers"
STORAGE


if [ -n "${PACKAGE_DNS:-}" ]; then
  ADMIN_HOST="${PACKAGE_DNS}"
else
  ADMIN_HOST="${IMAGE_HOSTNAME:-town-os}.local"
fi

cat > /etc/issue <<ISSUE
This is Town OS: Go to http://${ADMIN_HOST} to administer the system remotely
SSH: ssh root@\4 (password: enjoytownos)

Welcome to Town OS! \r (\m)

ISSUE
echo "Welcome to Town OS! Please access http://${ADMIN_HOST} in a browser." > /etc/motd
echo 'GRUB_CMDLINE_LINUX_DEFAULT="rootwait console=tty0 console=ttyS0,115200"' >> /etc/default/grub
echo "GRUB_DISTRIBUTOR=\"Town OS\"" >> /etc/default/grub
echo GRUB_TERMINAL_OUTPUT=console >> /etc/default/grub
