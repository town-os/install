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

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 >/etc/locale.conf
echo KEYMAP=us >/etc/vconsole.conf
echo "${IMAGE_HOSTNAME:-town-os}" >/etc/hostname

# Configure mkinitcpio for squashfs boot.
# Remove autodetect — it strips modules to only those found on the build host
# (a loopback in a chroot), so USB/AHCI/SCSI drivers would be missing at boot.
#
# The wishlist below spans x86 and arm hardware. Some drivers don't exist for
# every kernel/arch (e.g. Intel `ice`, Broadcom `bnxt_en` are absent from the
# aarch64 kernel), and mkinitcpio treats a listed-but-missing module as a HARD
# ERROR (non-zero exit), which fails the whole build. So filter the wishlist down
# to modules actually present for the installed kernel before writing MODULES=.
# Note: no zstd module needed — the squashfs root is gzip-compressed (zlib is
# built into the kernel), and zstd squashfs support is absent on aarch64.
WANT_MODULES="loop overlay squashfs nf_tables ahci sd_mod virtio_blk virtio_scsi nvme usb_storage uas e1000 e1000e igb ixgbe i40e ice virtio_net r8169 tg3 bnxt_en mlx4_en mlx5_core cfg80211 mac80211 iwlwifi iwlmvm ath9k ath10k_pci ath11k_pci brcmfmac mt76x2u rtw88_pci rtw89_pci"

# Raspberry Pi (linux-rpi) storage/USB/PCIe/net drivers, so the read-only root and
# the btrfs data disks come up on Pi 4/5 hardware: the SD/eMMC host (sdhci-iproc),
# PCIe root (pcie-brcmstb — gates Pi 4 USB3 and Pi 5 NVMe/RP1), USB host, and the
# onboard Ethernet MACs (bcmgenet on Pi 4, macb on Pi 5). Names not present for
# the installed kernel are filtered out below, so this is a no-op on the
# linux-aarch64 (qemu) and x86_64 builds; many of these are built-in (=y) in the
# rpi kernel, in which case mkinitcpio simply skips them. Exact Pi 5 RP1/Ethernet
# module names may need verification on real hardware.
WANT_MODULES="$WANT_MODULES sdhci_iproc sdhci_pltfm mmc_block bcm2835 pcie_brcmstb xhci_pci xhci_hcd dwc2 dwc3 phy_broadcom bcmgenet macb mdio_bcm_unimac broadcom lan78xx vc4"

# Allwinner H700 (Anbernic RG35XX) storage/USB, and USB Ethernet everywhere.
# sunxi_mmc drives the boot SD slot; the EHCI/OHCI platform controllers plus
# phy_sun4i_usb and musb are the board's USB host and OTG ports. Most of these
# are built in (=y) on the ALARM kernel and get filtered out below — listing them
# costs nothing and documents what the board needs.
#
# The USB Ethernet drivers matter far more than usual on that box: it has no
# Ethernet port, and its only onboard NIC is SDIO WiFi (rtw88_8821cs, already in
# the list above) whose firmware load can fail on a fresh card — a USB-C Ethernet
# adapter is the dependable way to get the installer online. They are equally
# useful as a fallback NIC on the PC and Pi images.
WANT_MODULES="$WANT_MODULES sunxi_mmc ehci_platform ohci_platform ehci_hcd ohci_hcd phy_sun4i_usb musb_hdrc sunxi usbnet cdc_ether cdc_ncm cdc_subset rndis_host asix ax88179_178a r8152 smsc95xx"

# WiFi on the Anbernic RG35XX: a Realtek RTL8821CS on SDIO (mmc1), which is the
# board's ONLY onboard NIC — it has no Ethernet — so ttyforce cannot get the box
# online in the initrd without this. rtw88_8821cs is the bus glue, rtw88_sdio the
# SDIO transport (rtw88_core/rtw88_8821c come along as dependencies), and rfkill
# is what ttyforce's `rfkill unblock` talks to. The SDIO host controller
# (sunxi_mmc), the mmc-pwrseq-simple that powers the chip up, and the AXP717
# regulators feeding it are all built into this kernel, so they need no entry
# here. Firmware (rtw88/rtw8821c_fw.bin) is pulled into the initrd by mkinitcpio
# automatically — it reads each module's MODULE_FIRMWARE — and the verification
# step after mkinitcpio below fails the build if it did not make it.
WANT_MODULES="$WANT_MODULES rtw88_8821cs rtw88_sdio rfkill"

# Game controllers, which on the RG35XX are how the box is INSTALLED: ttyforce
# reads the pad through gilrs/evdev and drives its whole initrd installer from it
# — D-pad navigates, Start raises the on-screen keyboard, the face buttons type
# on it. Every one of those buttons is a gpio-keys line in the device tree, so
# gpio_keys and evdev must exist before ttyforce runs. On the patched H700 kernel
# both are built IN (and the builtin filter below drops them here); on any kernel
# that builds them modular this list is what puts them in the initrd. joydev adds
# the legacy /dev/input/jsN interface; the hid-* and xpad drivers cover USB
# gamepads on every image. (The analog sticks are NOT reachable: they hang off the
# SoC GPADC, and CONFIG_SUN20I_GPADC/CONFIG_JOYSTICK_ADC are unset — no RG35XX
# device tree describes an adc-joystick either. Buttons only, which is all the
# installer uses.)
WANT_MODULES="$WANT_MODULES gpio_keys gpio_keys_polled joydev evdev virtio_input usbhid hid_generic xpad hid_sony hid_playstation hid_nintendo hid_steam hid_microsoft hid_logitech hid_logitech_dj hid_logitech_hidpp"

# Display, for the RG35XX's own LCD to be a console from the initrd onward. On
# the patched H700 kernel (scripts/build-kernel-rg35xx.sh) the whole chain — DE33
# mixer, TCON, the generic MIPI-DPI/SPI panel driver, the PWM backlight — is
# built IN, so the builtin filter below drops every name here and nothing is
# bundled: the console exists before the initrd loads a single module, which is
# what we want on a device whose only other console is an internal UART. They are
# listed anyway so a config that builds them modular still gets a working screen.
WANT_MODULES="$WANT_MODULES sun4i_drm sun8i_mixer sun8i_tcon_top panel_mipi pwm_sun20i pwm_bl"
KVER="$(ls -1 /usr/lib/modules | head -1)"
HAVE_MODULES=""
for m in $WANT_MODULES; do
  # Built into the kernel: it is already "in the initrd" by definition, and there
  # is no .ko to bundle. Listing it in MODULES= at best does nothing and at worst
  # trips mkinitcpio's missing-module error, so drop it here. Module filenames use
  # hyphens where modinfo names use underscores (mmc_block -> mmc_block.ko,
  # sunxi_mmc -> sunxi-mmc.ko), so match either.
  if grep -qE "/$(echo "$m" | tr '_' '.')\.ko" "/usr/lib/modules/$KVER/modules.builtin" 2>/dev/null; then
    echo "mkinitcpio: skipping module built into kernel $KVER: $m"
  elif modinfo -k "$KVER" "$m" >/dev/null 2>&1; then
    HAVE_MODULES="$HAVE_MODULES $m"
  else
    echo "mkinitcpio: skipping module not present for kernel $KVER: $m"
  fi
done
HAVE_MODULES="$(echo $HAVE_MODULES)"  # collapse leading/duplicate whitespace

sed -i \
  -e 's/^HOOKS=.*/HOOKS=(base udev modconf kms keyboard keymap consolefont block filesystems fsck town-installer town-squashfs)/' \
  -e "s/^MODULES=.*/MODULES=($HAVE_MODULES)/" \
  /etc/mkinitcpio.conf

curl -sSL sh.rustup.rs >boot-rustup && chmod +x boot-rustup && ./boot-rustup -y && rm boot-rustup
source $HOME/.cargo/env

# Install ttyforce — interactive installer TUI for network + disk provisioning
if [ -n "${TTYFORCE_DEV:-}" ]; then
  cargo install --git https://github.com/erikh/ttyforce ttyforce
else
  cargo install ttyforce
fi
mv /root/.cargo/bin/ttyforce /usr/bin

# The RG35XX has no keyboard and no serial console, so the ONLY way to type a
# WiFi password or a GitHub username on it is ttyforce's gamepad-driven
# on-screen keyboard (Start raises it, the face buttons type on it). That landed
# in 0.5.1 — an older ttyforce would leave the box navigable but unable to enter
# text, i.e. unprovisionable, and the failure would only show up in front of a
# user halfway through the installer. Check it here instead.
if [ -n "${RG35XX:-}" ]; then
  TTYFORCE_MIN=0.5.1
  TTYFORCE_HAVE=$(/usr/bin/ttyforce --version 2>/dev/null | awk '{ print $NF }')
  if [ -z "$TTYFORCE_HAVE" ] \
     || [ "$(printf '%s\n%s\n' "$TTYFORCE_MIN" "$TTYFORCE_HAVE" | sort -V | head -1)" != "$TTYFORCE_MIN" ]; then
    echo "ttyforce ${TTYFORCE_HAVE:-unknown} is too old for this board:" >&2
    echo "the on-screen keyboard (>= ${TTYFORCE_MIN}) is the only way to enter text on it." >&2
    exit 1
  fi
  echo "ttyforce ${TTYFORCE_HAVE}: on-screen keyboard available"
fi

rm -rf $HOME/.cargo/registry

mkinitcpio -P

# --- Verify the initrd carries what the hardware needs ---
# mkinitcpio bundles a module's firmware automatically (it reads MODULE_FIRMWARE
# from each module it adds), and it happens to run BEFORE the firmware trim
# below, so the initrd sees the full linux-firmware tree. Both of those are
# implicit behaviours this image depends on, and a silent regression in either
# one produces a board that boots to an installer with no network and no input —
# on hardware that has no other console. So assert it instead of assuming it.
#
# A name that is BUILT IN to the kernel is fine (it can never be in the initrd);
# only a name that is neither built in nor bundled is a failure. Module files use
# hyphens where modinfo names use underscores (sunxi_mmc -> sunxi-mmc.ko), so the
# pattern matches either, and .ko may carry a .zst/.xz suffix.
verify_initrd() {
  local img missing="" m pat f
  img=$(ls /boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -1)
  if [ -z "$img" ]; then
    echo "initrd verification: no /boot/initramfs-*.img was generated" >&2
    return 1
  fi
  local contents
  contents=$(lsinitcpio "$img")
  for m in $VERIFY_MODULES; do
    pat=$(echo "$m" | tr '_' '.')
    if echo "$contents" | grep -qE "/${pat}\.ko"; then
      continue
    fi
    if grep -qE "/${pat}\.ko" "/usr/lib/modules/$KVER/modules.builtin" 2>/dev/null; then
      continue
    fi
    missing="$missing module:$m"
  done
  for f in $VERIFY_FIRMWARE; do
    if ! echo "$contents" | grep -qE "firmware/${f}"; then
      missing="$missing firmware:$f"
    fi
  done
  for f in $VERIFY_FILES; do
    if ! echo "$contents" | grep -qE "$f"; then
      missing="$missing file:$f"
    fi
  done
  if [ -n "$missing" ]; then
    echo "initrd verification FAILED — $img is missing:$missing" >&2
    return 1
  fi
  echo "initrd verification passed: $VERIFY_MODULES $VERIFY_FIRMWARE $VERIFY_FILES"
}

# The RG35XX is the target that cannot be recovered by plugging in a monitor, so
# it is the one that gets checked: SDIO WiFi (its only NIC) with its firmware,
# the gpio-keys controls (its only input), and the regulatory database cfg80211
# needs before it will bring a radio up.
if [ -n "${RG35XX:-}" ]; then
  VERIFY_MODULES="rtw88_8821cs rtw88_sdio gpio_keys sunxi_mmc"
  VERIFY_FIRMWARE="rtw88/rtw8821c_fw.bin regulatory.db"
  # The installer runs IN THE INITRD on this board, on the machine's own screen
  # and buttons, so both have to work there — not just after switch_root:
  #   libudev  gilrs (ttyforce's gamepad stack, and therefore the on-screen
  #            keyboard) enumerates input devices through it. mkinitcpio pulls it
  #            in as a shared-library dependency of the ttyforce binary — an
  #            implicit behaviour worth asserting, since losing it costs all
  #            controller input with no other error.
  #   udev     the runtime hook that populates /dev/input at all.
  # The display half needs nothing in the initrd: the panel, DE33, PWM backlight
  # and framebuffer console are built INTO the patched kernel (verified in
  # scripts/build-kernel-rg35xx.sh), so tty0 exists before any module loads.
  VERIFY_FILES="libudev\.so hooks/udev usr/bin/ttyforce"
  verify_initrd
fi

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

# Keep the firmware every BUNDLED MODULE actually declares (MODULE_FIRMWARE), on
# top of the curated directories above. The initrd already holds its own copies —
# mkinitcpio bundled them before this trim ran — but a module loaded after
# switch_root reads from the root filesystem, so anything dropped here is gone at
# runtime. Driving this from HAVE_MODULES (the same list that becomes MODULES=)
# means the keep-list can no longer drift out of step with the drivers we ship:
# adding a driver above automatically keeps its firmware. Firmware may be stored
# compressed, while modinfo reports the uncompressed name.
for m in $HAVE_MODULES; do
  for f in $(modinfo -k "$KVER" -F firmware "$m" 2>/dev/null); do
    if [ -e "/tmp/fw-keep/$f" ]; then
      continue   # already preserved as part of a whole directory above
    fi
    for ext in '' .xz .zst; do
      if [ -e "$FW/${f}${ext}" ]; then
        mkdir -p "/tmp/fw-keep/$(dirname "$f")"
        cp -a "$FW/${f}${ext}" "/tmp/fw-keep/${f}${ext}"
      fi
    done
  done
done

# Remove everything else and restore keepers
rm -rf $FW/*
mv /tmp/fw-keep/* $FW/
rmdir /tmp/fw-keep

# --- Strip translation catalogs (only English is used) ---
# glibc's runtime locale data lives in /usr/lib/locale, built by locale-gen above
# and already limited to en_US.UTF-8. /usr/share/locale is separate: it holds every
# package's gettext .mo message catalogs for every language, none of which the
# installer needs. Drop all of it except English (en, en_US, en@…); locale.alias
# and other regular files are left in place (-type d only).
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en*' -exec rm -rf {} +

# --- Strip documentation and man pages ---
# This is a headless appliance driven over the network/serial installer; nobody
# reads man pages or bundled package docs on it. Remove them wholesale (the dirs
# are recreated empty so packages installing into them later don't fail).
rm -rf /usr/share/man/* /usr/share/doc/* /usr/share/info/*

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

mkdir -p /var/log/journal
# Can't symlink during chroot (bind-mounted), so make/install.sh handles it after chroot exits

# Configure systemd-resolved as the DNS broker: it always hits rolodex first
# (127.0.0.2 over IPv4, ::1 over IPv6). rolodex resolves everything else
# RECURSIVELY FROM THE ROOT SERVERS — resolved is NOT given any public upstream,
# because we don't want DNS silently working via Cloudflare/Google when rolodex
# is down or a filtering network blocks them. mDNS is enabled for .local
# hostname advertisement (replaces avahi-daemon).
#
# rolodex binds both loopbacks (127.0.0.2 + [::1]) in scripts/rolodex-config.sh,
# so both entries below reach the same rolodex; the v6 entry gives resolved an
# IPv6 path to it. There is NO public fallback here: the only other server
# resolved ever gets is the DHCP-provided resolver, appended at RUNTIME by
# scripts/bootstrap-dns.sh (a /run drop-in) so the image can resolve quay.io and
# pull rolodex before rolodex itself is up. That runtime entry sorts after the
# rolodex loopbacks, so rolodex still answers first once it is running.
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/townos.conf <<RESOLVED
[Resolve]
DNS=127.0.0.2 ::1
FallbackDNS=
DNSStubListener=yes
DNSStubListenerExtra=
MulticastDNS=yes
RESOLVED

# Speed up boot: only wait for one interface to be online, with a 10s cap.
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat >/etc/systemd/system/systemd-networkd-wait-online.service.d/any.conf <<WAITONLINE
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=10
WAITONLINE

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
# Serial console device is arch-specific (no ttyS0 on aarch64 — it's the PL011
# ttyAMA0). install.sh writes grub.cfg directly so this /etc/default/grub line is
# not used for the shipped config, but keep it correct for any later grub-mkconfig.
case "$(uname -m)" in
  aarch64) SERIAL_TTY=ttyAMA0 ;;
  *)       SERIAL_TTY=ttyS0 ;;
esac
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rootwait console=tty0 console=${SERIAL_TTY},115200\"" >> /etc/default/grub
echo "GRUB_DISTRIBUTOR=\"Town OS\"" >> /etc/default/grub
echo GRUB_TERMINAL_OUTPUT=console >> /etc/default/grub
