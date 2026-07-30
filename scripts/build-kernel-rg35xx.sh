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
# THE JOYPAD DRIVER, AND WHAT IT DRAGS IN
# ---------------------------------------
# Patch 0140 replaces the device tree's mainline `gpio-keys` gamepad with a
# `rocknix-singleadc-joypad` node bound to ROCKNIX's out-of-tree driver, which
# lives in its own repo (github.com/ROCKNIX/rocknix-joypad, pinned by commit).
# We build that driver here, so 0140 is applied — the alternative is the mainline
# gpio-keys path, which cannot read the analog sticks at all: they hang off the
# SoC GPADC behind a GPIO-selected analog mux, and this driver is what walks that
# mux and reports ABS_X/Y/RX/RY. It also presents the whole pad as ONE input
# device (buttons and both sticks together), which is what gilrs — and therefore
# ttyforce's installer — wants to see.
#
# Four things travel with that decision, and none of them is optional:
#
#   1. 0144, which is nothing but `&joypad { amux-count = <4>; }` on the rg35xx-h
#      board. `joypad` is a label only 0140 creates, so skipping 0140 while
#      keeping 0144 does not fail to apply — it fails later at DTC ("Label or
#      path joypad not found") and takes every Allwinner DTB with it. Skipping
#      either one demands checking the other; these patches are a sequence.
#   2. Three kernel patches from OTHER directories of the same ROCKNIX tree
#      (EXTRA_PATCHES below, each commented there): the input-polldev API the
#      driver registers with, the gpiolib-of revert it reads GPIO flags through,
#      and the adc-keys patch that defines the one symbol it declares extern.
#      Without the first two it does not compile; without the third it compiles
#      and then will not load.
#   3. CONFIG_INPUT_POLLDEV, CONFIG_INPUT_FF_MEMLESS (the module references
#      input_ff_create_memless even on a board with no rumble motor, so the
#      symbol has to exist or it will not load), CONFIG_KEYBOARD_ADC (where that
#      extern symbol lives) and CONFIG_IIO/CONFIG_SUN20I_GPADC — the ADC the
#      sticks are read through. All are built in, matching ROCKNIX's own config.
#   4. CONFIG_WERROR off, because this patch stack emits warnings that upstream
#      never promised not to (see the config section).
#
# RG35XX_KERNEL_PATCH_SKIP is still there to drop a patch, but it now defaults to
# empty: the full set is applied.
#
# Output: /boot/Image, /boot/dtbs/allwinner/*.dtb, /usr/lib/modules/<kver>/
# (including extra/rocknix-singleadc-joypad.ko)

set -euo pipefail

# --- Pinned inputs -----------------------------------------------------------
# The kernel version MUST be the one ROCKNIX builds the H700 against at
# ROCKNIX_COMMIT: the patch set is version-sensitive (it touches
# drivers/gpu/drm/sun4i and the allwinner DTs), so a mismatched pair means
# patches that do not apply — which fails the build loudly, hours in.
#
# WHERE TO READ THE RIGHT VERSION WHEN RE-PINNING — there are two package.mk
# files for the kernel and only one of them applies here:
#
#   projects/ROCKNIX/packages/linux/package.mk   <-- THIS one; `case ${DEVICE} in H700)`
#   packages/linux/package.mk                    <-- decoy: LibreELEC's, overridden
#
# The project-level file shadows the root one for every ROCKNIX build, so the
# root file's versions (keyed on ${LINUX}, e.g. the amlogic 6.16-rc3 commit)
# are never what an H700 image is built from. Reading the wrong one is exactly
# how these pins drifted apart before.
KERNEL_VERSION="${KERNEL_VERSION:-7.0.11}"
KERNEL_SHA256="${KERNEL_SHA256:-e56c8356dda01136a6041c6ef832bd0ec99bd2d35dff97832aa5ec10ed014304}"
ROCKNIX_COMMIT="${ROCKNIX_COMMIT:-441a1830f87c05f4fa43e38210829e9f05c2e4b4}"
# github.com/ROCKNIX/rocknix-joypad — the out-of-tree driver 0140's device tree
# binds to, built as an external module against the kernel below. Pinned the way
# ROCKNIX pins it (by commit; they carry no checksum for it either).
JOYPAD_COMMIT="${JOYPAD_COMMIT:-7647fdb0fc89cd69b284903bf7707e861df5dc7e}"
RG35XX_KERNEL_PATCH_SKIP="${RG35XX_KERNEL_PATCH_SKIP:-}"

PATCH_DIR_IN_REPO="projects/ROCKNIX/devices/H700/patches/linux"
# Kernel patches from outside the H700 device directory that the joypad driver
# needs to compile at all, applied in this order BEFORE the device patches (the
# order ROCKNIX applies them in). They are in the same tarball at the same pin:
#   input-polldev  the polled-input API the driver is written against
#                  (input_register_polled_device); mainline deleted it, and the
#                  patch restores it behind CONFIG_INPUT_POLLDEV.
#   adc-keys       defines and EXPORT_SYMBOLs `joypad_input_g`, the one symbol
#                  the driver declares extern and never defines. Without this
#                  patch the module builds and then refuses to LOAD on an
#                  unresolved symbol — on a board where that module is the only
#                  input device. It is also why CONFIG_KEYBOARD_ADC has to be
#                  built below: no adc-keys, no exported symbol.
#   gpiolib-of     restores of_get_named_gpio_flags()/enum of_gpio_flags, which
#                  the driver uses to read each button's active level, plus the
#                  <linux/of_gpio_legacy.h> header it includes on >= 6.3.
EXTRA_PATCHES="
projects/ROCKNIX/packages/linux/patches/mainline/0002-input-add-input-polldev-driver.patch
projects/ROCKNIX/packages/linux/patches/mainline/0004-input-adc-keys-redirect-keycode-316-to-rocknix-joypa.patch
projects/ROCKNIX/packages/linux/patches/rocknix-joypad/0001-gpiolib-of-revert-api-changes-needed-for-joypad-driv.patch
"
# Our own board file for the Pro. Mainline has no rg35xx-pro DT; ours matches
# ROCKNIX's (-plus base + amux-count = 4) with three button codes changed for
# ttyforce. Staged into the tree by install.sh.
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

echo "Fetching kernel ${KERNEL_VERSION}, the ROCKNIX H700 patch set and the joypad driver..."
curl -fsSL -o "$WORK/linux.tar.xz" \
  "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-${KERNEL_VERSION}.tar.xz"
echo "${KERNEL_SHA256}  $WORK/linux.tar.xz" | sha256sum -c -
curl -fsSL -o "$WORK/rocknix.tar.gz" \
  "https://github.com/ROCKNIX/distribution/archive/${ROCKNIX_COMMIT}.tar.gz"
curl -fsSL -o "$WORK/joypad.tar.gz" \
  "https://github.com/ROCKNIX/rocknix-joypad/archive/${JOYPAD_COMMIT}.tar.gz"

tar -xJf "$WORK/linux.tar.xz" -C "$WORK"
ROCKNIX_DIR="distribution-${ROCKNIX_COMMIT}"
tar -xzf "$WORK/rocknix.tar.gz" -C "$WORK" \
  "${ROCKNIX_DIR}/${PATCH_DIR_IN_REPO}" \
  $(for e in $EXTRA_PATCHES; do echo "${ROCKNIX_DIR}/${e}"; done)
tar -xzf "$WORK/joypad.tar.gz" -C "$WORK"
SRC="$WORK/linux-${KERNEL_VERSION}"
PATCHES="$WORK/${ROCKNIX_DIR}/${PATCH_DIR_IN_REPO}"
JOYPAD_SRC="$WORK/rocknix-joypad-${JOYPAD_COMMIT}"
cd "$SRC"

# --- Apply the patch set -----------------------------------------------------
# The two EXTRA_PATCHES first (the joypad driver's kernel-side APIs), then the
# H700 device directory in filename order: it is a sequence, not a menu — later
# patches (e.g. the one selecting the panel-mipi-dpi-spi driver) edit device tree
# nodes that earlier ones create. `.disabled` files are ROCKNIX's own opt-outs.
# A patch that does not apply stops the build naming itself, rather than quietly
# producing a kernel with half a display stack or a driver that cannot build.
#
# ROCKNIX has two further patch dirs for this device (packages/linux/patches/
# {mainline,7.0}) that we do not replicate: what is left in them after the
# polldev patch above is their adc-keys/joypad keycode redirect (which needs the
# rest of their userspace), a pwm_set_period helper nothing here calls, and
# Qualcomm/Rust/Bluetooth work this board never builds.
apply_patch() {
  local p="$1" name
  name=$(basename "$p")
  case " $RG35XX_KERNEL_PATCH_SKIP " in
    *" $name "*) echo "kernel: skipping $name (RG35XX_KERNEL_PATCH_SKIP)"; return 1 ;;
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
    echo "Re-pin KERNEL_VERSION/KERNEL_SHA256 to the version ROCKNIX builds the" >&2
    echo "H700 against at ROCKNIX_COMMIT — projects/ROCKNIX/packages/linux/" >&2
    echo "package.mk, 'case \${DEVICE} in H700)', NOT the root packages/linux one —" >&2
    echo "or skip the patch via RG35XX_KERNEL_PATCH_SKIP if it is not needed for" >&2
    echo "display/input/USB." >&2
    exit 1
  fi
  return 0
}

# apply_patch returns non-zero only for a skip (a failure exits), so `if` here is
# a counter, not error handling.
applied=0
for e in $EXTRA_PATCHES; do
  if apply_patch "$WORK/${ROCKNIX_DIR}/${e}"; then applied=$((applied + 1)); fi
done
for p in "$PATCHES"/*.patch; do
  if apply_patch "$p"; then applied=$((applied + 1)); fi
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

# One scripts/config call PER SYMBOL: `scripts/config --enable A B` is not a
# thing — the second symbol is parsed as a command, so it prints usage and exits
# 1, which under `set -e` kills the build at the first config line.
enable() { for s in "$@"; do ./scripts/config --file .config --enable "$s"; done; }
module() { for s in "$@"; do ./scripts/config --file .config --module "$s"; done; }
disable() { for s in "$@"; do ./scripts/config --file .config --disable "$s"; done; }

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
# Input. The pad itself is the out-of-tree rocknix-singleadc-joypad module built
# further down; everything it stands on is built IN, because it is the board's
# only input device and the installer needs it in the initrd:
#   INPUT_POLLDEV     the polled-input API it registers with (EXTRA_PATCHES).
#   INPUT_FF_MEMLESS  it references input_ff_create_memless() unconditionally,
#                     so the symbol must exist even though this board has no
#                     rumble motor — otherwise the module fails to load.
#   IIO/SUN20I_GPADC  the ADC the analog sticks are read through, behind the
#                     GPIO-selected mux the driver walks.
#   KEYBOARD_ADC      not for any button on this board: adc-keys is where the
#                     patched kernel DEFINES and exports joypad_input_g, the
#                     symbol the joypad module links against. Built out, the
#                     module cannot load.
#   KEYBOARD_GPIO     still needed: the volume buttons stay a gpio-keys node.
enable KEYBOARD_GPIO INPUT_EVDEV INPUT_JOYDEV HID HID_GENERIC USB_HID \
       INPUT_KEYBOARD INPUT_JOYSTICK INPUT_POLLDEV INPUT_FF_MEMLESS \
       IIO IIO_BUFFER SUN20I_GPADC KEYBOARD_ADC
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
# CONFIG_WERROR is default-y in arm64 defconfig, and it CANNOT stay on with a
# vendored patch stack: -Wmissing-prototypes and -Wunused-result are on by
# default (scripts/Makefile.warn), and ROCKNIX's patches trip both — their
# adc-keys change adds two non-static functions with no prototype, their OTG fix
# calls regulator_enable() without checking it. With -Werror each of those is a
# dead build, hours in, over a warning upstream never promised to avoid in
# out-of-tree code. ROCKNIX's own H700 config has WERROR unset for the same
# reason; this matches it.
disable WERROR

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
           VT_CONSOLE INPUT_KEYBOARD DRM_VIRTIO_GPU VIRTIO_INPUT
           INPUT_POLLDEV INPUT_FF_MEMLESS IIO SUN20I_GPADC KEYBOARD_ADC"
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

# --- The joypad driver, as an external module --------------------------------
# This is the driver 0140's device tree binds to, and on this board it is the
# ONLY thing that produces input: D-pad, face buttons, shoulders, thumb clicks
# and both analog sticks all come from this one device. DEVICE=H700 is read by
# the driver's own Makefile and selects the singleadc variant (the multi-ADC
# rocknix-joypad.o is for Rockchip/Amlogic boards and does not apply here).
# It installs under /usr/lib/modules/$KVER/extra/, which is why depmod below has
# to run after it rather than after modules_install.
echo "Building the rocknix-singleadc-joypad module..."
make ARCH=arm64 -C "$SRC" M="$JOYPAD_SRC" DEVICE=H700 -j"$JOBS" modules
make ARCH=arm64 -C "$SRC" M="$JOYPAD_SRC" DEVICE=H700 \
  INSTALL_MOD_PATH=/usr INSTALL_MOD_STRIP=1 modules_install

install -Dm644 arch/arm64/boot/Image /boot/Image
rm -f /boot/Image.gz
mkdir -p /boot/dtbs/allwinner
cp arch/arm64/boot/dts/allwinner/*.dtb /boot/dtbs/allwinner/
depmod -a "$KVER"

# --- Verify the artifacts ----------------------------------------------------
# The two reasons this build exists are the panel and the pad, and a device tree
# that quietly lost either looks exactly like a working build until the hardware
# shows a black screen or ignores every button. Both bindings appear verbatim as
# compatible strings in the compiled DTB, so grep for them there.
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
  if ! grep -qa 'rocknix-singleadc-joypad' "$PRO_DTB"; then
    echo "$PRO_DTB has no joypad node — patch 0140 did not reach this board, so" >&2
    echo "nothing will bind the module built above and the device has no input" >&2
    exit 1
  fi
fi

# The module is the board's only input driver, and a missing .ko here would only
# surface as an installer nobody can drive.
JOYPAD_KO=$(find /usr/lib/modules/"$KVER" -name 'rocknix-singleadc-joypad.ko*' | head -1)
if [ -z "$JOYPAD_KO" ]; then
  echo "the rocknix-singleadc-joypad module was not installed into" >&2
  echo "/usr/lib/modules/$KVER — the device tree above has a joypad node that" >&2
  echo "nothing would bind, i.e. a handheld with no working buttons" >&2
  exit 1
fi
echo "joypad module installed: $JOYPAD_KO"
echo "Kernel built and installed: ${KVER} ($(stat -c %s /boot/Image) bytes)"
