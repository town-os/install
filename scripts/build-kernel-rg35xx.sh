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
# needs is asserted by the fragment below and re-checked after olddefconfig.
#
# EVERY config decision lives in kernel/rg35xxpro.config, in git — both the
# additions and (most of the wall-clock) the subtractions. arm64 defconfig is
# the MULTIPLATFORM config, so out of the box this build spent hours compiling
# MediaTek clocks, Tegra audio and UBIFS for a handheld that has none of them;
# the fragment prunes the tree to this board. Read that file for the reasoning
# per symbol. Override with RG35XX_KERNEL_CONFIG=<path> to test a variant
# without editing the tracked one.
make ARCH=arm64 defconfig

KCONFIG_FRAGMENT="${RG35XX_KERNEL_CONFIG:-/usr/lib/town-os/kernel/rg35xxpro.config}"
if [ ! -f "$KCONFIG_FRAGMENT" ]; then
  echo "kernel config fragment not found: $KCONFIG_FRAGMENT" >&2
  echo "(install.sh stages kernel/ into the chroot at /usr/lib/town-os/kernel/)" >&2
  exit 1
fi
# merge_config.sh -m merges without running a config pass, so olddefconfig below
# is the single point where the kernel resolves dependencies. It prints
# "Value of CONFIG_x is redefined by fragment" for every symbol we override —
# that is the fragment doing its job, not a warning to chase.
./scripts/kconfig/merge_config.sh -m -O . .config "$KCONFIG_FRAGMENT"

make ARCH=arm64 olddefconfig

# --- Verify the config actually says what we just asked for ------------------
# A fragment line for a symbol whose dependencies are unmet is a silent no-op —
# merge_config.sh writes it, olddefconfig drops it, nothing complains. Everything
# below is load-bearing for either booting or the point of this build, so check
# the RESULT rather than trusting the request. This runs BEFORE the (very long)
# compile, so a config mistake costs minutes, not hours.
MUST_HAVE="SQUASHFS SQUASHFS_ZLIB OVERLAY_FS BTRFS_FS EXT4_FS VFAT_FS
           BLK_DEV_LOOP NAMESPACES USER_NS CGROUPS SECCOMP BRIDGE VETH TUN
           WIREGUARD NF_TABLES NF_NAT MMC_SUNXI MMC_BLOCK KEYBOARD_GPIO
           INPUT_EVDEV USB_STORAGE SERIAL_8250_DW DRM_SUN4I DRM_PANEL_MIPI
           PWM_SUN20I BACKLIGHT_PWM FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION SPI_GPIO
           RTW88_8821CS CFG80211 MAC80211 REGULATOR_AXP20X SUN50I_H616_CCU
           VT_CONSOLE INPUT_KEYBOARD DRM_VIRTIO_GPU VIRTIO_INPUT
           INPUT_POLLDEV INPUT_FF_MEMLESS IIO SUN20I_GPADC KEYBOARD_ADC
           ARCH_SUNXI BLK_DEV_SD USB_XHCI_HCD PCI_HOST_GENERIC
           USB_RTL8152 USB_NET_AX88179_178A
           SATA_AHCI"
missing=""
for sym in $MUST_HAVE; do
  grep -qE "^CONFIG_${sym}=(y|m)$" .config || missing="$missing $sym"
done
if [ -n "$missing" ]; then
  echo "kernel config verification FAILED — not enabled after olddefconfig:$missing" >&2
  echo "(a symbol whose dependencies are unmet is silently dropped; check the" >&2
  echo " patch set applied, that the symbol still exists in this kernel, and" >&2
  echo " that kernel/rg35xxpro.config did not prune something it depends on)" >&2
  exit 1
fi

# The other direction: confirm the pruning in kernel/rg35xxpro.config actually
# took. These are the blocks that account for most of the build time, and a
# rename upstream would silently put them back — turning a 40-minute emulated
# build into the multi-hour one this fragment exists to end, with nothing in the
# log to say why. Checking is free; noticing six hours in is not.
#
# Safe in the other direction too: a symbol that no longer exists reads as "not
# enabled" and passes, so this can never fail the build over a rename alone.
MUST_NOT_HAVE="ARCH_MEDIATEK ARCH_TEGRA ARCH_QCOM ARCH_ROCKCHIP ARCH_MESON
               ARCH_EXYNOS ARCH_RENESAS ARCH_MXC ARCH_HISI
               SND SOUND BT NFC MEDIA_SUPPORT INFINIBAND STAGING MTD
               ETHERNET WLAN_VENDOR_ATH WLAN_VENDOR_MEDIATEK WLAN_VENDOR_INTEL
               DRM_LIMA DRM_PANFROST VIRTUALIZATION COMPAT
               NFS_FS CIFS XFS_FS UBIFS_FS SCSI_LOWLEVEL"
unpruned=""
for sym in $MUST_NOT_HAVE; do
  ! grep -qE "^CONFIG_${sym}=(y|m)$" .config || unpruned="$unpruned $sym"
done
if [ -n "$unpruned" ]; then
  echo "kernel config verification FAILED — should have been pruned but is enabled:$unpruned" >&2
  echo "(something in kernel/rg35xxpro.config stopped taking effect — most likely" >&2
  echo " a symbol renamed upstream, or a new defconfig entry selecting it. Left" >&2
  echo " alone this silently restores the multi-hour multiplatform build.)" >&2
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
