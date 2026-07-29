#!/bin/bash
#
# build-kernel-rg35xx.sh — build a PATCHED kernel for the Anbernic RG35XX Pro
# (Allwinner H700), so the device's own LCD works as a console. Runs INSIDE the
# image chroot, from make/install.sh, before scripts/configure.sh (which runs
# mkinitcpio and then strips the toolchain).
#
# WHY A PATCHED KERNEL IS UNAVOIDABLE HERE
# ----------------------------------------
# Mainline drives almost all of this board — SoC, MMC, USB, AXP717 PMIC, the
# RTL8821CS SDIO WiFi — but NOT the display. As of the pinned kernel, mainline
# has the DE33 mixer (sun8i_mixer.c knows "allwinner,sun50i-h616-de33-mixer-0")
# and nothing else in the chain: no display-engine compatible for H616 in
# sun4i_drv.c, no LCD timing controller, and sun50i-h616.dtsi has no display,
# mixer or TCON nodes at all. The work exists — it was posted upstream in July
# 2025 as "arm64: dts: allwinner: h616: add LCD timing controller and display
# engine support" (v2, 12 patches) — but it has not landed. So the stock ALARM
# linux-aarch64 kernel can never light this panel, no matter what device tree it
# is given, and the LCD stays dark.
#
# WHERE THE PATCHES COME FROM
# ---------------------------
# ROCKNIX (the handheld distro that actually ships this board) carries that work
# plus the pieces around it — the PWM driver and backlight the panel needs to be
# visible at all, USB OTG host mode, and the generic MIPI-DPI/SPI panel driver
# the RG35XX panel uses. We take their H700 patch directory verbatim at a pinned
# commit rather than re-deriving it: they are GPL patches maintained by the
# people with the hardware, and pinning a commit makes the build reproducible.
# Everything here is pinned by commit and, for the kernel tarball, by sha256.
#
# WHAT IS DELIBERATELY NOT APPLIED
# --------------------------------
# ROCKNIX's joypad patch (0140) swaps the device tree's mainline `gpio-keys`
# controls for their out-of-tree `rocknix-joypad` driver, which lives in a
# different package. Applying it WITHOUT that driver would leave the board with
# no working buttons at all, so it is skipped by default and the mainline
# gpio-keys path — which our initrd already carries a driver for — is kept.
# Override with RG35XX_KERNEL_PATCH_SKIP if you vendor their driver too.
#
# Output: /boot/Image, /boot/dtbs/allwinner/*.dtb, /usr/lib/modules/<kver>/

set -euo pipefail

# --- Pinned inputs -----------------------------------------------------------
# torvalds/linux at 6.16-rc3 — the tree ROCKNIX pins its H700 patches against.
# The patch set is version-sensitive (it touches drivers/gpu/drm/sun4i and the
# allwinner DTs), so moving this without moving ROCKNIX_COMMIT means patches
# that do not apply — which fails the build loudly rather than silently.
KERNEL_COMMIT="${KERNEL_COMMIT:-86731a2a651e58953fc949573895f2fa6d456841}"
KERNEL_SHA256="${KERNEL_SHA256:-008b00968a8bfc0627580b82a2d30c7304336a4f92a58e80cdbc2d4723e01840}"
ROCKNIX_COMMIT="${ROCKNIX_COMMIT:-441a1830f87c05f4fa43e38210829e9f05c2e4b4}"
RG35XX_KERNEL_PATCH_SKIP="${RG35XX_KERNEL_PATCH_SKIP:-0140-rg35xx-2024-use-rocknix-joypad-driver.patch}"

PATCH_DIR_IN_REPO="projects/ROCKNIX/devices/H700/patches/linux"
# Our own board file for the Pro (mainline has no rg35xx-pro DT and ROCKNIX's
# references their joypad driver). Staged into the tree by install.sh.
PRO_DTS="/usr/lib/town-os/dts/sun50i-h700-anbernic-rg35xx-pro.dts"

# --- Build-only dependencies -------------------------------------------------
# On top of base-devel (gcc/make/bison/flex). Remove afterwards exactly what we
# installed, the same accounting scripts/build-uboot-rg35xx.sh does.
DEPS="bc dtc python perl cpio xz kmod tar inetutils"
NEW=""
for p in $DEPS; do
  pacman -Qq "$p" >/dev/null 2>&1 || NEW="$NEW $p"
done
if [ -n "$NEW" ]; then
  pacman -S --needed --noconfirm $NEW
fi

WORK=$(mktemp -d)
cleanup() {
  rm -rf "$WORK"
  if [ -n "$NEW" ]; then
    pacman -Rdd --noconfirm $NEW >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Fetching kernel ${KERNEL_COMMIT} and the ROCKNIX H700 patch set..."
curl -fsSL -o "$WORK/linux.tar.gz" \
  "https://github.com/torvalds/linux/archive/${KERNEL_COMMIT}.tar.gz"
echo "${KERNEL_SHA256}  $WORK/linux.tar.gz" | sha256sum -c -
curl -fsSL -o "$WORK/rocknix.tar.gz" \
  "https://github.com/ROCKNIX/distribution/archive/${ROCKNIX_COMMIT}.tar.gz"

tar -xzf "$WORK/linux.tar.gz" -C "$WORK"
tar -xzf "$WORK/rocknix.tar.gz" -C "$WORK" \
  "distribution-${ROCKNIX_COMMIT}/${PATCH_DIR_IN_REPO}"
SRC="$WORK/linux-${KERNEL_COMMIT}"
PATCHES="$WORK/distribution-${ROCKNIX_COMMIT}/${PATCH_DIR_IN_REPO}"
cd "$SRC"

# --- Apply the patch set -----------------------------------------------------
# In filename order: it is a sequence, not a menu — later patches (e.g. the one
# selecting the panel-mipi-dpi-spi driver) edit device tree nodes that earlier
# ones create. `.disabled` files are ROCKNIX's own opt-outs. A patch that does
# not apply stops the build naming itself, rather than quietly producing a
# kernel with half a display stack.
applied=0
for p in "$PATCHES"/*.patch; do
  name=$(basename "$p")
  case " $RG35XX_KERNEL_PATCH_SKIP " in
    *" $name "*) echo "kernel: skipping $name (RG35XX_KERNEL_PATCH_SKIP)"; continue ;;
  esac
  echo "kernel: applying $name"
  # --batch is not optional in an unattended build: without it, a patch whose
  # target file patch cannot locate makes it PROMPT ("File to patch:") and block
  # on stdin — and the >/dev/null below swallows the prompt, so the build simply
  # stops dead with no output and no clue. Worse, anything typed is taken as a
  # filename, so an operator answering "y" just gets re-prompted invisibly.
  # --batch takes the default (skip) instead, which fails the patch, which is
  # caught right here and reported by name.
  if ! patch --batch -p1 -F2 --no-backup-if-mismatch -i "$p" >/dev/null; then
    echo "kernel patch FAILED to apply: $name" >&2
    echo "The pinned kernel and the pinned ROCKNIX patch set have drifted apart." >&2
    echo "Re-pin KERNEL_COMMIT/ROCKNIX_COMMIT together, or skip it via" >&2
    echo "RG35XX_KERNEL_PATCH_SKIP if it is not needed for display/input/USB." >&2
    exit 1
  fi
  applied=$((applied + 1))
done
echo "kernel: applied $applied patches"

# --- Add the RG35XX Pro board file -------------------------------------------
# The Pro is not in any tree: mainline stops at -2024/-plus/-h/-sp. Ours derives
# from -plus (see the DTS for why) and inherits everything the patches above
# added to the shared -2024 base — the display, and the button remap that makes
# the panel drivable without a keyboard.
if [ -f "$PRO_DTS" ]; then
  cp "$PRO_DTS" arch/arm64/boot/dts/allwinner/
  DTB_MAKEFILE=arch/arm64/boot/dts/allwinner/Makefile
  if ! grep -q 'rg35xx-pro' "$DTB_MAKEFILE"; then
    echo 'dtb-$(CONFIG_ARCH_SUNXI) += sun50i-h700-anbernic-rg35xx-pro.dtb' >> "$DTB_MAKEFILE"
  fi
fi

# --- Configure ---------------------------------------------------------------
# Base is the kernel's own arm64 defconfig rather than Arch Linux ARM's config.
# WHY: ALARM's config tracks a much newer kernel than the one this patch set
# applies to, so `olddefconfig` would silently default hundreds of symbols that
# moved or were renamed in between — on a board that cannot be recovered without
# a soldering iron. arm64 defconfig is maintained in-tree for exactly this
# kernel, boots on multiplatform arm64, and everything Town OS additionally
# needs is asserted explicitly below and re-checked after olddefconfig.
make ARCH=arm64 defconfig

enable() { ./scripts/config --file .config --enable "$@"; }
module() { ./scripts/config --file .config --module "$@"; }
disable() { ./scripts/config --file .config --disable "$@"; }

# Root filesystem: read-only squashfs (zlib — see install.sh) + tmpfs overlay,
# btrfs for /town-os, ext4 for the data partition, vfat for the boot partition.
enable SQUASHFS SQUASHFS_ZLIB SQUASHFS_XATTR SQUASHFS_FILE_DIRECT \
       OVERLAY_FS BTRFS_FS BTRFS_FS_POSIX_ACL EXT4_FS EXT4_FS_POSIX_ACL \
       VFAT_FS FAT_DEFAULT_UTF8 NLS_CODEPAGE_437 NLS_ISO8859_1 NLS_UTF8 \
       FUSE_FS BLK_DEV_LOOP AUTOFS_FS
# systemd/podman substrate: namespaces, cgroups, seccomp, devtmpfs, xattrs.
enable NAMESPACES USER_NS PID_NS NET_NS UTS_NS IPC_NS CGROUPS CGROUP_FREEZER \
       CGROUP_PIDS CGROUP_DEVICE MEMCG CPUSETS SECCOMP SECCOMP_FILTER \
       DEVTMPFS DEVTMPFS_MOUNT TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
       FANOTIFY EPOLL SIGNALFD TIMERFD EVENTFD POSIX_MQUEUE
# Networking: the container/WireGuard data path plus nftables.
enable BRIDGE VETH TUN WIREGUARD IPV6 NF_TABLES NF_TABLES_INET NF_NAT \
       NF_CONNTRACK NETFILTER_XTABLES NFT_CT NFT_NAT NFT_MASQ NFT_REDIR \
       NFT_CHAIN_NAT IP_NF_IPTABLES IP_NF_NAT IP_NF_TARGET_MASQUERADE \
       BRIDGE_NETFILTER VLAN_8021Q
# Storage + USB on this board: the SD host, USB host/OTG, and USB mass storage
# (the persistent btrfs lives on USB — mainline enables no second card slot).
enable MMC MMC_BLOCK MMC_SUNXI PWRSEQ_SIMPLE PWRSEQ_EMMC \
       USB USB_EHCI_HCD USB_EHCI_HCD_PLATFORM USB_OHCI_HCD \
       USB_OHCI_HCD_PLATFORM USB_MUSB_HDRC USB_MUSB_SUNXI USB_MUSB_DUAL_ROLE \
       PHY_SUN4I_USB USB_STORAGE USB_UAS
# Input: every control on this handheld is a gpio-keys line. Built IN, not a
# module — it is the board's only input device and must never be missing.
enable KEYBOARD_GPIO INPUT_EVDEV INPUT_JOYDEV HID HID_GENERIC USB_HID \
       INPUT_KEYBOARD INPUT_JOYSTICK
module JOYSTICK_XPAD HID_SONY HID_PLAYSTATION HID_NINTENDO HID_STEAM \
       HID_MICROSOFT HID_LOGITECH HID_LOGITECH_DJ HID_LOGITECH_HIDPP
# THE POINT OF THIS BUILD: the display. DE33 mixer + TCON + the generic
# MIPI-DPI/SPI panel driver (DRM_PANEL_MIPI, added by the patch set), the PWM
# driver and PWM backlight the panel needs to be visible, and the fbdev
# emulation + framebuffer console that turn it into /dev/tty0.
enable DRM DRM_SUN4I DRM_SUN4I_BACKEND DRM_SUN8I_MIXER DRM_SUN8I_TCON_TOP \
       DRM_PANEL DRM_PANEL_MIPI DRM_PANEL_BRIDGE DRM_FBDEV_EMULATION \
       FB FB_CORE FRAMEBUFFER_CONSOLE FRAMEBUFFER_CONSOLE_DETECT_PRIMARY \
       VT VT_CONSOLE PWM PWM_SUN20I BACKLIGHT_CLASS_DEVICE BACKLIGHT_PWM \
       SPI SPI_GPIO SPI_SUN6I REGMAP_SPI
# Board plumbing: PMIC/regulators the panel, WiFi and SD rails hang off, the
# 8250 UART that is the serial console, thermal/watchdog, SRAM controller.
enable MFD_AXP20X MFD_AXP20X_I2C REGULATOR REGULATOR_AXP20X AXP20X_POWER \
       SUNXI_SRAM SUN8I_THERMAL SUNXI_WATCHDOG SERIAL_8250 SERIAL_8250_CONSOLE \
       SERIAL_8250_DW SERIAL_OF_PLATFORM SUN50I_H616_CCU SUN50I_H6_R_CCU \
       SUN8I_DE2_CCU RTC_DRV_SUN6I I2C_MV64XXX NVMEM_SUNXI_SID
# WiFi: the RTL8821CS on SDIO, its firmware loader, and rfkill.
module RTW88 RTW88_CORE RTW88_SDIO RTW88_8821C RTW88_8821CS RFKILL
enable CFG80211 MAC80211 WLAN FW_LOADER CFG80211_CRDA_SUPPORT
# USB Ethernet: the dependable way to get this box online (no Ethernet port).
module USB_NET_DRIVERS USB_USBNET USB_NET_AX8817X USB_NET_AX88179_178A \
       USB_NET_CDCETHER USB_NET_CDC_NCM USB_NET_RNDIS_HOST USB_RTL8152 \
       USB_NET_SMSC95XX
# virtio, purely so `make qemu-usb TARGET=rg35xxpro` can boot this exact kernel
# under QEMU 'virt' and show the installer on an emulated screen — the closest
# thing to a test rig this target has. Costs nothing on real hardware.
enable VIRTIO VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE \
       DRM_VIRTIO_GPU VIRTIO_INPUT SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE
# Modules are zstd-compressed to match Arch's tooling; debug info is dropped
# (CONFIG_DEBUG_INFO_NONE) because it triples build time and image size for a
# kernel nobody will run a debugger against, and BTF additionally needs pahole.
enable MODULES MODULE_UNLOAD MODULE_COMPRESS_ZSTD
disable DEBUG_INFO_BTF DEBUG_INFO_DWARF5
enable DEBUG_INFO_NONE

make ARCH=arm64 olddefconfig

# --- Verify the config actually says what we just asked for ------------------
# `scripts/config --enable` on a symbol whose dependencies are unmet is a silent
# no-op, and olddefconfig can turn a symbol back off. Everything below is
# load-bearing for either booting or the point of this build, so check the
# RESULT rather than trusting the request.
MUST_HAVE="SQUASHFS SQUASHFS_ZLIB OVERLAY_FS BTRFS_FS EXT4_FS VFAT_FS
           BLK_DEV_LOOP NAMESPACES USER_NS CGROUPS SECCOMP BRIDGE VETH TUN
           WIREGUARD NF_TABLES NF_NAT MMC_SUNXI MMC_BLOCK KEYBOARD_GPIO
           INPUT_EVDEV USB_STORAGE SERIAL_8250_DW DRM_SUN4I DRM_PANEL_MIPI
           PWM_SUN20I BACKLIGHT_PWM FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION SPI_GPIO
           RTW88_8821CS CFG80211 MAC80211 REGULATOR_AXP20X SUN50I_H616_CCU
           VT_CONSOLE INPUT_KEYBOARD DRM_VIRTIO_GPU VIRTIO_INPUT"
missing=""
for sym in $MUST_HAVE; do
  grep -qE "^CONFIG_${sym}=(y|m)$" .config || missing="$missing $sym"
done
if [ -n "$missing" ]; then
  echo "kernel config verification FAILED — not enabled after olddefconfig:$missing" >&2
  echo "(a symbol whose dependencies are unmet is silently dropped; check the" >&2
  echo " patch set applied and that the symbol still exists in this kernel)" >&2
  exit 1
fi
echo "kernel config verification passed"

# --- Build -------------------------------------------------------------------
JOBS=$(nproc)
echo "Building kernel with -j${JOBS} (this is the long part)..."
make ARCH=arm64 -j"$JOBS" Image modules dtbs

# --- Install into the image --------------------------------------------------
# Drop the pacstrapped ALARM kernel's modules first: configure.sh resolves the
# kernel version with `ls /usr/lib/modules | head -1`, and mkinitcpio's preset
# reads the version out of /boot/Image — two module trees would make both
# ambiguous and could build an initrd for the wrong kernel.
KVER=$(make -s ARCH=arm64 kernelrelease)
echo "Installing kernel ${KVER}..."
rm -rf /usr/lib/modules/*
make ARCH=arm64 INSTALL_MOD_PATH=/usr INSTALL_MOD_STRIP=1 modules_install
rm -f /usr/lib/modules/"$KVER"/{build,source}

install -Dm644 arch/arm64/boot/Image /boot/Image
rm -f /boot/Image.gz
mkdir -p /boot/dtbs/allwinner
cp arch/arm64/boot/dts/allwinner/*.dtb /boot/dtbs/allwinner/
depmod -a "$KVER"

# --- Verify the artifacts ----------------------------------------------------
# The whole reason for this build is the panel, and a device tree that quietly
# lost it looks exactly like a working build until the screen stays black on
# hardware. The panel's compatible string appears verbatim in the compiled DTB,
# so grep for it there.
PRO_DTB=/boot/dtbs/allwinner/sun50i-h700-anbernic-rg35xx-pro.dtb
if [ -f "$PRO_DTS" ]; then
  if [ ! -f "$PRO_DTB" ]; then
    echo "expected $PRO_DTB but the Pro device tree did not build" >&2
    exit 1
  fi
  if ! grep -qa 'panel-mipi-dpi-spi' "$PRO_DTB"; then
    echo "$PRO_DTB has no panel node — the display patches did not reach this board" >&2
    exit 1
  fi
fi
echo "Kernel built and installed: ${KVER} ($(stat -c %s /boot/Image) bytes)"
