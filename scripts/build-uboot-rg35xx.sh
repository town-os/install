#!/bin/bash
#
# build-uboot-rg35xx.sh — build the bootloader for the Anbernic RG35XX Pro
# (Allwinner H700). Runs INSIDE the image chroot, from make/install.sh, before
# scripts/configure.sh strips the toolchain back out.
#
# WHY BUILD IT AT ALL: every other Town OS target boots through firmware that is
# already on the machine (UEFI on the PC/qemu images, the GPU bootloader on the
# Pi). An Allwinner box has no such firmware — the BootROM loads U-Boot out of
# raw sectors of the boot card, so the image has to CARRY a bootloader, and no
# distro packages one for this board.
#
# WHY TWO BINARIES: the SPL initialises DRAM from compiled-in timings, and H700
# handhelds shipped with BOTH LPDDR3 and LPDDR4 across production runs. The wrong
# timings mean the SPL never brings memory up and the board is simply dead at
# power-on — no console, no output. Mainline U-Boot carries a single
# anbernic_rg35xx_h700_defconfig (LPDDR4 timings), which is why ROCKNIX ships two
# separate U-Boot builds for this SoC. We do the same: build both from ROCKNIX's
# pinned defconfigs, install both, and let install.sh write the selected one into
# the raw sectors while staging the other on the boot partition so a mis-detected
# unit can be recovered by re-writing 128 KiB of the card rather than rebuilding.
#
# Pieces needed:
#   TF-A BL31   the ARM Trusted Firmware secure monitor (PSCI). Every 64-bit
#               Allwinner SoC needs it; U-Boot's SPL chainloads it. The H700 has
#               no TF-A platform of its own — it is an H616 derivative, so
#               PLAT=sun50i_h616 is the correct (and only) choice.
#   U-Boot      built with BL31=, producing u-boot-sunxi-with-spl.bin: SPL +
#               BL31 + U-Boot proper in one blob for the raw sectors.
#
# The build is NATIVE aarch64 (this chroot is aarch64 — the whole repo's rule is
# that image arch == build-host arch), so CROSS_COMPILE is deliberately empty.
#
# Output: /boot/u-boot-sunxi-with-spl-lpddr3.bin, -lpddr4.bin

set -euo pipefail

# U-Boot 2026.01 is what ROCKNIX pins its H700 DRAM patch and defconfigs
# against; moving this without re-checking that patch means it may not apply.
UBOOT_VERSION="${UBOOT_VERSION:-2026.01}"
ATF_VERSION="${ATF_VERSION:-v2.15.0}"
ROCKNIX_COMMIT="${ROCKNIX_COMMIT:-441a1830f87c05f4fa43e38210829e9f05c2e4b4}"
ATF_PLAT=sun50i_h616
RX_H700="projects/ROCKNIX/devices/H700/packages"

# Build-only dependencies on top of base-devel (gcc/make/bison/flex/pkgconf).
# python + swig are not optional: the sunxi image is assembled by binman, which
# needs pylibfdt built from the U-Boot tree. Remove afterwards exactly what we
# installed — packages that were already present stay (configure.sh does the same
# accounting for the Rust toolchain).
DEPS="bc dtc swig python python-setuptools"
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

echo "Fetching U-Boot ${UBOOT_VERSION}, TF-A ${ATF_VERSION}, ROCKNIX H700 DRAM configs..."
curl -fsSL "https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2" \
  | tar -xjf - -C "$WORK"
curl -fsSL "https://github.com/ARM-software/arm-trusted-firmware/archive/refs/tags/${ATF_VERSION}.tar.gz" \
  | tar -xzf - -C "$WORK"
curl -fsSL -o "$WORK/rocknix.tar.gz" \
  "https://github.com/ROCKNIX/distribution/archive/${ROCKNIX_COMMIT}.tar.gz"
tar -xzf "$WORK/rocknix.tar.gz" -C "$WORK" \
  "distribution-${ROCKNIX_COMMIT}/${RX_H700}/u-boot-DDR3" \
  "distribution-${ROCKNIX_COMMIT}/${RX_H700}/u-boot-DDR4"
RX="$WORK/distribution-${ROCKNIX_COMMIT}/${RX_H700}"

UBOOT_SRC="$WORK/u-boot-${UBOOT_VERSION}"
ATF_SRC=$(echo "$WORK"/arm-trusted-firmware-*)

echo "Building TF-A BL31 (PLAT=${ATF_PLAT})..."
make -C "$ATF_SRC" -j"$(nproc)" CROSS_COMPILE= PLAT="$ATF_PLAT" DEBUG=0 bl31
BL31="$ATF_SRC/build/$ATF_PLAT/release/bl31.bin"
[ -f "$BL31" ] || { echo "TF-A produced no $BL31" >&2; exit 1; }

cd "$UBOOT_SRC"
# ROCKNIX's DRAM fix for dram_sun50i_h616.c, shipped identically in both of
# their U-Boot packages — apply once, before either configuration is built.
# --batch so a patch whose target file cannot be located fails loudly (set -e
# catches it) rather than prompting "File to patch:" and blocking forever on a
# console the emulated build VM has no way to answer.
patch --batch -p1 -F2 --no-backup-if-mismatch \
  -i "$RX/u-boot-DDR4/patches/0001-Update-dram_sun50i_h616.c.patch"
cp "$RX/u-boot-DDR3/sources/configs/anbernic_rg35xx_h700_lpddr3_defconfig" configs/
cp "$RX/u-boot-DDR4/sources/configs/anbernic_rg35xx_h700_lpddr4_defconfig" configs/

for variant in lpddr3 lpddr4; do
  echo "Building U-Boot (anbernic_rg35xx_h700_${variant}_defconfig)..."
  make CROSS_COMPILE= mrproper
  make CROSS_COMPILE= "anbernic_rg35xx_h700_${variant}_defconfig"
  # SCP=/dev/null: the optional Crust system-control-processor firmware is not
  # built here. Without it U-Boot only warns; suspend/resume on the SCP is the
  # feature given up, and this is a headless appliance that never suspends.
  make -j"$(nproc)" CROSS_COMPILE= BL31="$BL31" SCP=/dev/null
  [ -f u-boot-sunxi-with-spl.bin ] || {
    echo "U-Boot ${variant} produced no u-boot-sunxi-with-spl.bin" >&2; exit 1; }
  cp u-boot-sunxi-with-spl.bin "/boot/u-boot-sunxi-with-spl-${variant}.bin"
  echo "U-Boot ${variant}: $(stat -c %s "/boot/u-boot-sunxi-with-spl-${variant}.bin") bytes"
done
