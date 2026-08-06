#!/usr/bin/env bash

set -xeou pipefail

export DEBUG=${DEBUG:-}
export KEEP_MOUNT=${KEEP_MOUNT:-}
# When non-empty, GRUB defaults to the serial-console boot entry so the machine
# comes up headless on the serial port (115200) with no keyboard/monitor required.
# The serial device is arch-specific (ttyS0 on x86_64, ttyAMA0 on aarch64); see
# SERIAL_TTY below.
export SERIAL_CONSOLE=${SERIAL_CONSOLE:-}

town_config() {
  grep "^${1}:" ./town-os.yaml | awk '{ print $2 }' | tr -d '"' | tr -d "'"
}

STORAGE_BACKEND=$(town_config storage_backend)
STORAGE_BACKEND="${STORAGE_BACKEND:-btrfs}"
BTRFS_RAID_MODE=$(town_config btrfs_raid_mode)
BTRFS_RAID_MODE="${BTRFS_RAID_MODE:-native}"

chroot_cmd() {
  env -i HOME=/root arch-chroot $MOUNT_POINT sh -lc "$*"
}

eject_loopback() {
  losetup -j $IMAGE | awk -F: '{ print $1 }' | xargs -I{} losetup -d {}
}

cleanup_build_container() {
  podman stop town-build 2>/dev/null || true
  podman rm town-build 2>/dev/null || true
}

cleanup_mount() {
  print_info "Ejecting loopback and unmounting partitions..."
  cleanup_build_container

  if [ -d "$MOUNT_POINT" ]; then
    # Only kill processes on the mount if something is actually mounted there;
    # otherwise fuser -c targets the parent filesystem (root!) and kills the desktop
    if mountpoint -q "$MOUNT_POINT"; then
      fuser -mk "$MOUNT_POINT" 2>/dev/null || :
    fi
    umount -Rf "$MOUNT_POINT" 2>/dev/null || umount -Rl "$MOUNT_POINT" 2>/dev/null || :
    rm -rf "$MOUNT_POINT"
  fi
}

IMAGE_SIZE=${1:-12G}
IMAGE=${2:-image.raw}

# RPI builds a Raspberry Pi image (Pi 4/400/CM4/Pi 5/CM5) that boots NATIVELY via
# the Pi GPU bootloader + config.txt — NO UEFI, NO GRUB. It only makes sense on
# aarch64 (builds are always native), and it swaps the kernel, bootloader, and the
# whole boot-staging path below. Empty = the normal UEFI/GRUB image (x86_64 +
# qemu 'virt' aarch64).
RPI="${RPI:-}"

# RG35XX builds an SD-card image for the Anbernic RG35XX Pro (and the rest of the
# Allwinner H700 handheld family) that boots the way every Allwinner box does: the
# SoC's BootROM reads U-Boot out of RAW SECTORS at the front of the card, U-Boot
# then reads /extlinux/extlinux.conf off the FAT partition and loads the kernel.
# NO UEFI, NO GRUB, and — unlike every other target — a bootloader that has to be
# BUILT, because no distro packages U-Boot for this board. aarch64-only, btrfs-only.
RG35XX="${RG35XX:-}"
# Device tree handed to the kernel. Defaults to the Pro board file this repo
# carries (dts/), which the patched-kernel build compiles into the tree; mainline
# has no rg35xx-pro DT at all. Any of the staged H700 DTBs works here, as does an
# absolute path to a .dtb from elsewhere.
RG35XX_DTB="${RG35XX_DTB:-sun50i-h700-anbernic-rg35xx-pro.dtb}"
# DRAM type of the target unit: H700 handhelds shipped with BOTH lpddr4 and
# lpddr3, and the SPL's compiled-in timings must match or the board never brings
# memory up (dead at power-on, no output at all). Both bootloaders are built and
# staged on the boot partition; this selects which one is written to the raw
# sectors. If a unit shows no sign of life, re-write the other variant.
RG35XX_DRAM="${RG35XX_DRAM:-lpddr4}"
# Skip the in-chroot U-Boot build and use this prebuilt u-boot-sunxi-with-spl.bin
# instead (path on the build host, relative to the repo or absolute).
UBOOT_BIN="${UBOOT_BIN:-}"
# Where built kernels are cached between image builds (repo-relative). A patched
# kernel build is the single most expensive step in this target — hours under
# emulation — and its inputs are fully pinned, so it is built once per pin set
# and reused. Delete the directory to force a rebuild.
KERNEL_CACHE_DIR="${KERNEL_CACHE_DIR:-.kernel-cache}"

# Builds are always NATIVE: the image architecture equals the build host (or the
# same-arch builder container) architecture. We never cross-build or emulate, so
# `uname -m` is authoritative for which kernel package and GRUB target to use.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    KERNEL_PKG="linux618"
    KERNEL_ZFS_PKG="linux618-zfs"
    GRUB_EFI_TARGET="x86_64-efi"
    SERIAL_TTY="ttyS0"         # PC 16550 UART
    ;;
  aarch64)
    KERNEL_PKG="linux-aarch64"
    KERNEL_ZFS_PKG=""          # no prebuilt zfs kernel module package on aarch64
    GRUB_EFI_TARGET="arm64-efi"
    SERIAL_TTY="ttyAMA0"       # ARM PL011 UART (e.g. qemu 'virt'); there is no ttyS0
    ;;
  *)
    echo "Unsupported build architecture: $ARCH (expected x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

# Raspberry Pi overrides. The Pi's GPU bootloader reads only a FAT partition and
# loads kernel/DTB/initramfs directly, so we use the Raspberry Pi Foundation
# kernel (ALARM `linux-rpi`: 4 KB pages, ships /boot/kernel8.img + flat *.dtb +
# overlays/, boots BOTH Pi 4 and Pi 5) plus `raspberrypi-bootloader` (the GPU
# firmware: start4.elf/fixup4.dat used by Pi 4, ignored by the EEPROM-resident
# Pi 5 firmware). GRUB is not installed at all on this path.
RPI_FIRMWARE_PKG=""
if [ -n "$RPI" ]; then
  if [ "$ARCH" != "aarch64" ]; then
    echo "RPI builds are aarch64-only (got $ARCH). Build on an aarch64 host." >&2
    exit 1
  fi
  if [ "$STORAGE_BACKEND" = "zfs" ]; then
    echo "RPI builds do not support the zfs storage backend." >&2
    exit 1
  fi
  KERNEL_PKG="linux-rpi"     # RPi Foundation kernel: kernel8.img, Pi 4 + Pi 5
  KERNEL_ZFS_PKG=""
  RPI_FIRMWARE_PKG="raspberrypi-bootloader"
  # Serial console name is per-board on the Pi and the firmware rewrites the
  # `serial0` alias in cmdline.txt to the real device (ttyS0 on Pi 4, ttyAMA10 on
  # Pi 5), so there is no single build-time SERIAL_TTY. See the cmdline.txt and
  # serial-getty handling below, which cover all three candidates.
  SERIAL_TTY="serial0"
fi

# Anbernic RG35XX (Allwinner H700) overrides. linux-aarch64 is still pacstrapped
# (for the mkinitcpio presets, firmware and hooks) and already carries ARCH_SUNXI,
# the H616/H700 clocks, MMC_SUNXI, the AXP717 PMIC and the RTL8821CS SDIO WiFi
# driver — but it is then REPLACED by a kernel built from source with the H700
# display patches, because mainline drives no display on this SoC family and the
# panel IS this image's only console. The boot path differs too: U-Boot in raw sectors
# + extlinux instead of UEFI/GRUB.
if [ -n "$RG35XX" ]; then
  if [ -n "$RPI" ]; then
    echo "RPI and RG35XX are different boards — set only one." >&2
    exit 1
  fi
  if [ "$ARCH" != "aarch64" ]; then
    echo "RG35XX builds are aarch64-only (got $ARCH). Use 'make image TARGET=rg35xxpro'." >&2
    exit 1
  fi
  if [ "$STORAGE_BACKEND" = "zfs" ]; then
    echo "RG35XX builds do not support the zfs storage backend." >&2
    exit 1
  fi
  case "$RG35XX_DRAM" in
    lpddr3|lpddr4) ;;
    *) echo "RG35XX_DRAM must be 'lpddr3' or 'lpddr4' (got '$RG35XX_DRAM')" >&2; exit 1 ;;
  esac
  # This target configures NO serial console: the handheld's own panel is the
  # console (console=tty0, see the cmdline below) and its buttons are the
  # keyboard, so the machine is set up with nothing plugged in. SERIAL_TTY is
  # still set to the board's real UART (H700 UART0 is a DesignWare 8250 — ttyS0,
  # not the PL011 ttyAMA0 of qemu 'virt') only because the shared serial-getty
  # unit's ConditionKernelCommandLine is rewritten from it below; that getty is
  # deliberately never enabled here.
  SERIAL_TTY="ttyS0"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]
then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# NOTHING HERE REMOVES OR RENAMES THE IMAGE FILE. The build needs a blank slate
# (a plain `truncate -s $IMAGE_SIZE` over an existing image merely EXTENDS it,
# leaving the old partition table and filesystem signatures underneath, which
# would have mkfs prompting "Proceed anyway?" on stdin nothing is reading), so it
# empties the file IN PLACE: truncate to 0 frees every block, and the re-extend
# below hands back a sparse file of zeros -- byte-for-byte what a fresh file
# would be. Same inode, same path, never unlinked, never moved.
if [ -f "$IMAGE" ]
then
  eject_loopback
  truncate -s 0 "$IMAGE"
fi

MOUNT_POINT=$(mktemp -d)

trap 'cleanup_mount; eject_loopback' EXIT

truncate -s "$IMAGE_SIZE" "$IMAGE"

losetup -f --partscan "$IMAGE"
DEVICE=$(losetup -j "$IMAGE" | awk -F: '{ print $1 }' | head -1)

print_info "Creating GPT partition table..."
parted -s "$DEVICE" mklabel gpt

# Raw space reserved AHEAD of the first partition. Normally 1 MiB (the standard
# alignment gap; on x86_64 GRUB's BIOS core image lives in part1 itself).
#
# The RG35XX needs more: the Allwinner BootROM loads U-Boot from raw sectors of
# the boot card, before any partition exists. Its first candidate is sector 16
# (8 KiB) — which sits INSIDE the GPT partition-entry array (LBA 2..33) and would
# destroy the partition table — but every ARM64 Allwinner SoC also checks sector
# 256 (128 KiB) when it finds no image at 8 KiB, and 128 KiB is past the whole
# GPT. So we write U-Boot at 128 KiB and keep GPT (and therefore the identical
# 3-partition layout and shrink machinery) instead of dropping to MBR the way
# most sunxi distro images do. u-boot-sunxi-with-spl.bin for the H700 (SPL +
# TF-A BL31 + U-Boot proper) runs near 1 MiB, so push part1 out to 4 MiB and
# leave the ~3.9 MiB between 128 KiB and it for the bootloader.
if [ -n "$RG35XX" ]; then PART1_START_MIB=4; else PART1_START_MIB=1; fi
PART1_END_MIB=$((PART1_START_MIB + 1))

# Part1: BIOS boot partition (raw, for GRUB core image embed only — no filesystem).
# The partition is created on every arch to keep partition numbering identical
# (PART1/PART2/PART3), but the bios_grub flag and BIOS GRUB only apply to x86_64
# — aarch64 is UEFI-only and never uses this partition.
print_info "Creating BIOS boot partition..."
parted -s "$DEVICE" mkpart grub "${PART1_START_MIB}MiB" "${PART1_END_MIB}MiB"
if [ "$ARCH" = "x86_64" ]; then
  parted -s "$DEVICE" set 1 bios_grub on
fi

# Part2: EFI System Partition (UEFI/GRUB builds) OR the boot partition of the
# native-boot targets (RPI, RG35XX). 64 MiB is plenty for a GRUB stub, but a
# native boot partition must hold the kernel, initramfs and DTBs itself (plus the
# overlays/ tree and GPU firmware on the Pi), so those builds grow it to 512 MiB.
# It stays a FAT32 partition flagged ESP either way — recent Pi 4/5 EEPROMs find
# the first bootable FAT partition on a 512-byte GPT disk (the unformatted part1
# is skipped), and U-Boot scans every partition for extlinux.conf.
print_info "Creating EFI System Partition..."
if [ -n "$RPI" ] || [ -n "$RG35XX" ]; then
  ESP_END_MIB=$((PART1_END_MIB + 512))
else
  ESP_END_MIB=$((PART1_END_MIB + 64))
fi
parted -s "$DEVICE" mkpart ESP fat32 "${PART1_END_MIB}MiB" "${ESP_END_MIB}MiB"
parted -s "$DEVICE" set 2 esp on

# Part3: Data partition (holds /boot + root.sfs, >= 10GB)
print_info "Creating data partition (>= 10GB)..."
parted -s "$DEVICE" mkpart primary ext4 "${ESP_END_MIB}MiB" 100%

# Wait for kernel to update partition table
partprobe "$DEVICE"
for i in $(seq 1 20); do
  [ -b "${DEVICE}p3" ] && break
  sleep 0.2
done

PART1="${DEVICE}p1"
PART2="${DEVICE}p2"
PART3="${DEVICE}p3"

# Part1 is raw (bios_grub) — no formatting

print_info "Formatting EFI partition as FAT32..."
mkfs.fat -F32 -n TOWN_EFI "$PART2"

print_info "Formatting data partition as ext4..."
mkfs.ext4 -L TOWN_DATA "$PART3"

print_info "Mounting partitions..."
mkdir -p "$MOUNT_POINT"
mount "$PART3" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot/efi"
mount "$PART2" "$MOUNT_POINT/boot/efi"

# Base package set lives in make/base-packages.txt (single source of truth shared
# with make/Containerfile.build, which pre-fetches them into the builder image
# cache so pacstrap doesn't re-download them every build). Strip comments/blanks.
BASE_PACKAGES="$(grep -vE '^[[:space:]]*(#|$)' ./make/base-packages.txt | tr '\n' ' ')"
PACKAGES="$BASE_PACKAGES $KERNEL_PKG"

# Raspberry Pi GPU firmware (start*.elf/fixup*.dat/*.bin) staged onto the FAT boot
# partition below so the GPU bootloader can bring up the SoC and load the kernel.
if [ -n "$RPI_FIRMWARE_PKG" ]; then
  PACKAGES="$PACKAGES $RPI_FIRMWARE_PKG"
fi

if [ "$STORAGE_BACKEND" = "zfs" ]
then
  if [ -z "$KERNEL_ZFS_PKG" ]; then
    echo "zfs storage backend is not supported on $ARCH (no $KERNEL_PKG zfs package)" >&2
    exit 1
  fi
  PACKAGES="$PACKAGES $KERNEL_ZFS_PKG"
else
  PACKAGES="$PACKAGES btrfs-progs"
  if [ "$BTRFS_RAID_MODE" = "mdadm" ]
  then
    PACKAGES="$PACKAGES mdadm"
  fi
fi

# Refresh the package databases so pacstrap installs current versions even when
# the (cached) builder image — and the package cache stamped into it — is old.
# The stamped cache still serves unchanged packages; only updated ones download.
pacman -Sy --noconfirm

# The Arch Linux ARM signing key, which nothing else pulls in on aarch64.
# `base` depends on `archlinux-keyring` — Arch's x86 keyring — and that is the
# ONLY keyring the chroot gets, while every aarch64 package in the image was
# signed by the single Arch Linux ARM Build System key. It is absent because
# ALARM ships archlinuxarm-keyring in its base ROOTFS rather than as a
# dependency of anything, so a pacstrapped chroot never sees it.
#
# Two consequences, both real: the in-chroot `pacman -S` that the RG35XX
# kernel/U-Boot builds run stops to import that key and then blocks fetching it
# from a keyserver, and the SHIPPED IMAGE cannot verify an ALARM package either
# — `pacman -S` on the running device hits the same wall.
#
# Guarded on the package actually existing so a non-ALARM aarch64 repo (a
# BASE_IMAGE override) doesn't fail the build over a package it doesn't carry.
if [ "$ARCH" = "aarch64" ] && pacman -Si archlinuxarm-keyring >/dev/null 2>&1; then
  PACKAGES="$PACKAGES archlinuxarm-keyring"
fi


pacstrap -Kc $MOUNT_POINT $PACKAGES

print_info "System setup..."

genfstab -U $MOUNT_POINT >> $MOUNT_POINT/etc/fstab

# Remove the root (/) entry from fstab — root is mounted by the initramfs
# squashfs hook as an overlay, and systemd-remount-fs would fail trying to
# remount the overlay as ext4
sed -i '\|[[:space:]]/[[:space:]]|d' $MOUNT_POINT/etc/fstab

# Fix the /boot/efi entry. In the container build, genfstab -U can't resolve the
# vfat partition's UUID (no udev/blkid cache) and falls back to the build-time
# loopback path (e.g. /dev/loop10p2). That device never exists at runtime, so the
# mount times out and boot drops to emergency mode. Replace it with the EFI
# partition's real UUID (blkid direct-probe works, as it does for DATA_UUID), and
# mark it nofail with a short device timeout so a missing/changed ESP can never
# block boot.
EFI_UUID=$(blkid -s UUID -o value "$PART2")
sed -i '\|[[:space:]]/boot/efi[[:space:]]|d' $MOUNT_POINT/etc/fstab
printf 'UUID=%s\t/boot/efi\tvfat\trw,relatime,nofail,x-systemd.device-timeout=5s\t0 2\n' \
  "$EFI_UUID" >> $MOUNT_POINT/etc/fstab

# Install initcpio hooks into the chroot
cp ./initcpio/install/town-squashfs $MOUNT_POINT/usr/lib/initcpio/install/town-squashfs
cp ./initcpio/hooks/town-squashfs $MOUNT_POINT/usr/lib/initcpio/hooks/town-squashfs
cp ./initcpio/install/town-installer $MOUNT_POINT/usr/lib/initcpio/install/town-installer
cp ./initcpio/hooks/town-installer $MOUNT_POINT/usr/lib/initcpio/hooks/town-installer

# Tags are arch-suffixed (rc.latest-x86_64 / rc.latest-aarch64) — per-arch
# tags, not multi-arch manifests. The Makefile normally supplies these; the
# defaults cover a direct install.sh invocation. Rolodex follows the
# controller's tag.
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-quay.io/town/town:rc.latest-${ARCH}}"
ROLODEX_IMAGE="${ROLODEX_IMAGE:-quay.io/town/rolodex:${CONTROLLER_IMAGE##*:}}"

# Resolve LOCAL_DNS into a concrete package DNS name
PACKAGE_DNS=""
if [ -n "${LOCAL_DNS:-}" ]; then
  if [ "$LOCAL_DNS" = "1" ]; then
    PACKAGE_DNS="$(hostname)"
  else
    PACKAGE_DNS="$LOCAL_DNS"
  fi
fi
export PACKAGE_DNS

rsync -a ./systemd/ $MOUNT_POINT/etc/systemd/system/
sed -i "s|quay.io/town/town:rc.latest|${CONTROLLER_IMAGE}|g" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
sed -i "s|quay.io/town/rolodex:rc.latest|${ROLODEX_IMAGE}|g" $MOUNT_POINT/etc/systemd/system/town-os-system--rolodex.service
# Pass the controller's image tag into the container as TOWN_OS_TAG so the
# systemcontroller derives every sibling image (UI, rolodex, networkcontroller,
# ingress) at the SAME tag it was installed with. With no override this is
# rc.latest-${ARCH}, so a system update always pulls the newest images; a
# specific CONTROLLER_TAG/CONTROLLER_IMAGE pins the whole fleet to that tag.
CONTROLLER_TAG_ONLY="${CONTROLLER_IMAGE##*:}"
sed -i "s|@TOWN_OS_TAG@|${CONTROLLER_TAG_ONLY}|g" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
if [ -n "$PACKAGE_DNS" ]; then
  sed -i "s|@PACKAGE_DNS@|-package-dns ${PACKAGE_DNS}|g" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
else
  sed -i "/@PACKAGE_DNS@/d" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
fi
# Keep the serial-getty's console gate IN TANDEM with the kernel `console=`
# parameter. On UEFI/GRUB builds both derive from $SERIAL_TTY (ttyS0 on x86_64,
# ttyAMA0 on aarch64 'virt'), so the getty only starts on the exact serial device
# the kernel was told to use. On the Pi the real serial device is per-board
# (ttyS0 on Pi 4, ttyAMA10 on Pi 5 — the firmware rewrites cmdline.txt's `serial0`
# alias to it), so we gate on the PER-INSTANCE console with the %I specifier and
# enable all three candidate instances below; only the one matching the live
# `console=` runs.
if [ -n "$RPI" ]; then
  SERIAL_GETTY_GATE='console=%I,115200'
else
  SERIAL_GETTY_GATE="console=${SERIAL_TTY},115200"
fi
sed -i "s|^ConditionKernelCommandLine=console=.*|ConditionKernelCommandLine=${SERIAL_GETTY_GATE}|" \
  $MOUNT_POINT/etc/systemd/system/town-os-serial-getty@.service

# Architecture selection is handled entirely by the arch-suffixed image tags
# (rc.latest-${ARCH}, set above): each tag is a single-arch image, and podman
# pulls for the host's own architecture by default. No --platform flag is used
# — that is only for pulling a foreign architecture from a multi-arch manifest,
# which this build never does (it is always native, host arch == image arch).

chroot_cmd mkdir -p /usr/lib/town-os
cp ./town-os.yaml $MOUNT_POINT/usr/lib/town-os/town-os.yaml
rsync -a ./scripts/ $MOUNT_POINT/usr/lib/town-os/scripts/
if [ -d ./dts ]; then
  mkdir -p "$MOUNT_POINT/usr/lib/town-os/dts"
  rsync -a ./dts/ "$MOUNT_POINT/usr/lib/town-os/dts/"
fi
# Kernel config fragments (kernel/rg35xxpro.config) — build-kernel-rg35xx.sh
# merges one onto arm64 defconfig. Staged like dts/ because the kernel build
# runs inside the chroot and cannot reach the repo.
if [ -d ./kernel ]; then
  mkdir -p "$MOUNT_POINT/usr/lib/town-os/kernel"
  rsync -a ./kernel/ "$MOUNT_POINT/usr/lib/town-os/kernel/"
fi

# --- Make the chroot's pacman keyring usable before anything installs into it ---
# The RG35XX build is the ONLY path in this repo that runs `pacman -S` inside the
# image chroot: scripts/build-{kernel,uboot}-rg35xx.sh install their own build
# deps there (bc, dtc, swig, python, ...). Every other target only pacstraps.
#
# That chroot keyring is NOT ready for it, for two independent reasons:
#
#   1. `pacstrap -K` runs `pacman-key --init` and NOTHING else (see
#      /usr/bin/pacstrap) — the keyring it creates is EMPTY. Distro keys arrive
#      only via a keyring package's own install scriptlet, and
#      archlinuxarm-keyring's is conditional on /usr/bin/pacman-key already
#      existing when it runs. (pacstrap's own package verification doesn't
#      notice: it runs the host's pacman with the host's absolute GPGDir, so it
#      verifies against the BUILD ENV's keyring, not this one.)
#   2. archlinuxarm-keyring wasn't even installed here until the package list
#      above added it — `base` pulls Arch's x86 archlinux-keyring and nothing
#      pulls ALARM's, because ALARM ships it in its base rootfs instead.
#
# Together those left the chroot with Arch's x86 master keys fully trusted and
# the one Arch Linux ARM key absent, so `pacman -S bc dtc` printed
#   :: Import PGP key 77193F152BDBE6A6, "Arch Linux ARM Build System"? [Y/n] y
# auto-answered yes (--noconfirm), went to a KEYSERVER for it, and blocked there.
# Nothing prompting, nothing failing — the build just stopped.
#
# scripts/pacman-keyring.sh closes it offline, populating from the keyring
# package now on disk. Naming `archlinuxarm` as REQUIRED is what makes this
# airtight: it asserts the keyring is installed at all, so the check cannot pass
# vacuously on Arch's keys the way "is anything trusted" did.
if [ -n "$RG35XX" ]; then
  print_info "Ensuring the chroot's pacman keyring trusts the distro signing keys"
  chroot_cmd "sh /usr/lib/town-os/scripts/pacman-keyring.sh ensure archlinuxarm" || {
    echo "The chroot's pacman keyring is unusable; the in-chroot kernel/U-Boot" >&2
    echo "builds would stall fetching signing keys from a keyserver." >&2
    exit 1
  }
fi

# --- Patched kernel for the Allwinner H700 (RG35XX) ---
# The reason this exists at all is the LCD: mainline drives everything else on
# this board but has no display support for the H616/H700 SoC family, so the
# stock kernel can only ever talk over the UART. scripts/build-kernel-rg35xx.sh
# applies the (GPL, pinned) H700 patch set that ROCKNIX maintains and builds the
# result here, replacing the pacstrapped ALARM kernel. It also builds ROCKNIX's
# out-of-tree joypad driver, which that patch set's device tree binds to and
# which is the board's only input device (analog sticks included).
#
# It must run BEFORE configure.sh, which generates the initramfs — an initrd
# built against the old kernel's modules would not match the kernel it boots.
#
# CACHED, because this is by far the most expensive step in the whole build
# (hours under emulation) and its inputs are fully pinned: the cache key is the
# hash of the build script itself, the kernel config fragment, our device tree,
# and any pin overrides, so any change to those misses the cache and rebuilds,
# while a repeat build of the same pins extracts in seconds. The cache lives in
# the repo (bind-mounted/9p-shared into the builder), which is the only writable
# place that outlives the chroot.
#
# kernel/*.config MUST stay in this hash: it is now where every config decision
# lives, so leaving it out would let an edited config silently reuse a kernel
# built from the previous one — the worst kind of stale, since the .config that
# produced the cached modules is not the one in the tree.
if [ -n "$RG35XX" ]; then
  KCACHE_KEY=$(cat ./scripts/build-kernel-rg35xx.sh ./kernel/*.config ./dts/*.dts 2>/dev/null | sha256sum | cut -c1-16)
  KCACHE_KEY="${KCACHE_KEY}-${KERNEL_VERSION:-pin}-${ROCKNIX_COMMIT:-pin}-${JOYPAD_COMMIT:-pin}-${RG35XX_KERNEL_PATCH_SKIP:-default}"
  # RG35XX_KERNEL_CONFIG names a path INSIDE the chroot, so the normal way to use
  # it is to drop a variant into kernel/ (everything there is staged to
  # /usr/lib/town-os/kernel/) and point at that — in which case ./kernel/*.config
  # above already hashed it and the cache key is correct with no extra work.
  # Fold in the path itself so two variants staged side by side can't collide on
  # one cache entry, and hash the content as well on the off chance the override
  # resolves to a real file on the host too.
  if [ -n "${RG35XX_KERNEL_CONFIG:-}" ]; then
    KCACHE_KEY="${KCACHE_KEY}-${RG35XX_KERNEL_CONFIG}"
    [ -f "${RG35XX_KERNEL_CONFIG}" ] &&
      KCACHE_KEY="${KCACHE_KEY}-$(sha256sum "${RG35XX_KERNEL_CONFIG}" | cut -c1-16)"
  fi
  KCACHE_KEY=$(printf '%s' "$KCACHE_KEY" | sha256sum | cut -c1-24)
  KCACHE_FILE="${KERNEL_CACHE_DIR}/rg35xx-kernel-${KCACHE_KEY}.tar.zst"
  if [ -f "$KCACHE_FILE" ]; then
    print_info "Reusing cached patched kernel: $KCACHE_FILE"
    rm -rf "$MOUNT_POINT"/usr/lib/modules/*
    rm -f "$MOUNT_POINT/boot/Image.gz"
    tar --zstd -xf "$KCACHE_FILE" -C "$MOUNT_POINT"
  else
    print_info "Building patched kernel for the H700 (long; cached afterwards)..."
    # No terminal is passed in the environment: this script installs build deps
    # inside the chroot (pacman -S), and anything there that wants a terminal
    # gets one by inheriting the controlling terminal, which survives `env -i`
    # because it is a property of the process rather than of its environment.
    env -i HOME=/root \
      KERNEL_VERSION="${KERNEL_VERSION:-}" KERNEL_SHA256="${KERNEL_SHA256:-}" \
      ROCKNIX_COMMIT="${ROCKNIX_COMMIT:-}" JOYPAD_COMMIT="${JOYPAD_COMMIT:-}" \
      RG35XX_KERNEL_PATCH_SKIP="${RG35XX_KERNEL_PATCH_SKIP:-}" \
      RG35XX_KERNEL_CONFIG="${RG35XX_KERNEL_CONFIG:-}" \
      arch-chroot $MOUNT_POINT sh -lc "bash /usr/lib/town-os/scripts/build-kernel-rg35xx.sh"
    mkdir -p "$KERNEL_CACHE_DIR"
    print_info "Caching the built kernel as $KCACHE_FILE"
    tar --zstd -cf "$KCACHE_FILE" -C "$MOUNT_POINT" \
      boot/Image boot/dtbs usr/lib/modules
    # The cache is written by root (this script runs as root); hand it to the
    # invoking user so a later non-root `rm -rf .kernel-cache` works.
    [ -n "${SUDO_UID:-}" ] && chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$KERNEL_CACHE_DIR" || true
  fi
  [ -f "$MOUNT_POINT/boot/Image" ] || { echo "patched kernel build left no /boot/Image" >&2; exit 1; }
fi

# --- U-Boot for the Allwinner H700 (RG35XX) ---
# No distro packages a bootloader for this board, so we build mainline U-Boot
# (anbernic_rg35xx_h700_defconfig) plus the TF-A BL31 secure monitor it
# chainloads. It runs INSIDE the chroot, right here: the chroot is aarch64 and
# still has base-devel at this point — configure.sh (next line) is what strips
# the toolchain back out, so a build placed after it would have no compiler.
if [ -n "$RG35XX" ]; then
  if [ -n "$UBOOT_BIN" ]; then
    print_info "Using prebuilt U-Boot: $UBOOT_BIN"
    [ -f "$UBOOT_BIN" ] || { echo "UBOOT_BIN=$UBOOT_BIN does not exist" >&2; exit 1; }
    cp "$UBOOT_BIN" "$MOUNT_POINT/boot/u-boot-sunxi-with-spl.bin"
  else
    print_info "Building U-Boot + TF-A for the Allwinner H700..."
    env -i HOME=/root \
      UBOOT_VERSION="${UBOOT_VERSION:-}" ATF_VERSION="${ATF_VERSION:-}" \
      arch-chroot $MOUNT_POINT sh -lc "bash /usr/lib/town-os/scripts/build-uboot-rg35xx.sh"
  fi
  # A prebuilt UBOOT_BIN is used for both DRAM variants (the caller supplied a
  # blob for their own unit); a built one produces a binary per variant.
  if [ -n "$UBOOT_BIN" ]; then
    cp "$MOUNT_POINT/boot/u-boot-sunxi-with-spl.bin" "$MOUNT_POINT/boot/u-boot-sunxi-with-spl-${RG35XX_DRAM}.bin"
  fi
  [ -f "$MOUNT_POINT/boot/u-boot-sunxi-with-spl-${RG35XX_DRAM}.bin" ] || {
    echo "U-Boot build produced no u-boot-sunxi-with-spl-${RG35XX_DRAM}.bin" >&2; exit 1; }
fi

# RG35XX is passed through so configure.sh can VERIFY the generated initrd
# actually carries that board's WiFi (its only NIC), its gpio-keys controls (its
# only input) and their firmware — there is no second console to recover with if
# it doesn't.
env -i HOME=/root PACKAGE_DNS="$PACKAGE_DNS" IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-town-os}" TTYFORCE_DEV="${TTYFORCE_DEV:-}" TTYFORCE_LATEST="${TTYFORCE_LATEST:-}" RG35XX="$RG35XX" arch-chroot $MOUNT_POINT sh -lc "bash /usr/lib/town-os/scripts/configure.sh"

# --- D-Bus systemd configuration via Podman container ---
print_info "Configuring systemd units via D-Bus in Podman container..."

podman run -d --systemd=true --name town-build --replace \
  --network=none \
  --rootfs "$MOUNT_POINT" \
  /sbin/init --unit=basic.target

# Wait for systemd to be ready (up to 30s)
for i in $(seq 1 60); do
  if podman exec town-build busctl get-property org.freedesktop.systemd1 \
    /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager SystemState \
    2>/dev/null | grep -q running; then
    break
  fi
  sleep 0.5
done

podman exec town-build busctl call \
  org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager SetDefaultTarget "sb" \
  "multi-user.target" false

# Serial-getty instances to enable + mask. UEFI/GRUB builds have exactly one
# serial device ($SERIAL_TTY). On the Pi the live serial device is per-board
# (Pi 4 -> ttyS0, Pi 5 -> ttyAMA10, ttyAMA0 covering other cases) and the firmware
# rewrites cmdline.txt's `serial0` to it, so we enable all three candidates; the
# per-instance %I console gate set above means only the one matching the live
# `console=` actually starts. Build the busctl argument arrays so the "asbb" count
# stays correct as the serial instance list grows.
if [ -n "$RPI" ]; then
  SERIAL_TTYS="ttyS0 ttyAMA0 ttyAMA10"
elif [ -n "$RG35XX" ]; then
  # No serial console exists on this image at all — the panel is the console — so
  # no serial getty is enabled. town-os-getty@tty1 (enabled below) is the one
  # that matters here, and it runs on the screen.
  SERIAL_TTYS=""
else
  SERIAL_TTYS="$SERIAL_TTY"
fi
ENABLE_UNITS=(
  "town-os-overlays.service"
  "town-os-bootstrap-dns.service"
  "town-os-system--rolodex.service"
  "town-os-rolodex-config.path"
  "town-os-podman-api.service"
  "town-os-systemcontroller.service"
  "town-os-sledgehammer.service"
  "town-os-network-diag.service"
  "systemd-networkd.service"
  "systemd-networkd-wait-online.service"
  "systemd-resolved.service"
  "sshd.service"
  "town-os-getty@tty1.service"
)
MASK_UNITS=( "getty@tty1.service" )
for _t in $SERIAL_TTYS; do
  ENABLE_UNITS+=( "town-os-serial-getty@${_t}.service" )
  MASK_UNITS+=( "serial-getty@${_t}.service" )
done

podman exec town-build busctl call \
  org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" "${#ENABLE_UNITS[@]}" \
  "${ENABLE_UNITS[@]}" \
  false false

# Mask default getty units so they don't conflict with ttyforce getty
podman exec town-build busctl call \
  org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager MaskUnitFiles "asbb" "${#MASK_UNITS[@]}" \
  "${MASK_UNITS[@]}" \
  false false

if [ "$STORAGE_BACKEND" = "zfs" ]; then
  podman exec town-build busctl call \
    org.freedesktop.systemd1 /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 1 \
    "zfs-mount.service" false false
fi

cleanup_build_container
print_info "systemd D-Bus configuration complete."

# Point resolv.conf at systemd-resolved stub — must be done outside chroot
# because arch-chroot bind-mounts /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf "$MOUNT_POINT/etc/resolv.conf"

DATA_UUID=$(blkid -s UUID -o value "$PART3")

if [ -n "$RPI" ]; then
  # ---- Native Raspberry Pi boot (no UEFI, no GRUB) ----
  # The Pi GPU bootloader reads ONLY this FAT partition (mounted at /boot/efi for
  # the build). It chains: GPU firmware (start4.elf on Pi 4; EEPROM-resident on
  # Pi 5) -> config.txt -> auto-selects the matching board DTB -> loads kernel8.img
  # + the initramfs. linux-rpi + raspberrypi-bootloader already put kernel8.img,
  # the flat *.dtb files, overlays/, and the firmware blobs into /boot, so we copy
  # those onto the FAT partition and add config.txt/cmdline.txt ourselves.
  print_info "Staging native Raspberry Pi boot files onto the FAT partition (no GRUB)..."
  FAT="$MOUNT_POINT/boot/efi"
  SRC="$MOUNT_POINT/boot"

  # linux-rpi ships the kernel as kernel8.img (4 KB pages; boots Pi 4 AND Pi 5).
  if [ ! -f "$SRC/kernel8.img" ]; then
    echo "expected $SRC/kernel8.img from linux-rpi but it is missing" >&2
    exit 1
  fi
  cp "$SRC/kernel8.img" "$FAT/kernel8.img"

  # The town initramfs (mkinitcpio); reference it as initramfs-linux.img in
  # config.txt regardless of the package preset's filename.
  INITRD_SRC=$(ls "$SRC"/initramfs-*.img | grep -v fallback | head -1)
  cp "$INITRD_SRC" "$FAT/initramfs-linux.img"

  # All board DTBs (flat in /boot on ALARM) + the overlays tree. The firmware
  # selects the correct DTB by detecting the board, so we ship them all.
  cp "$SRC"/*.dtb "$FAT"/ 2>/dev/null || true
  [ -d "$SRC/overlays" ] && cp -a "$SRC/overlays" "$FAT/overlays"
  # GPU firmware from raspberrypi-bootloader (start*.elf/fixup*.dat/*.bin). Pi 5
  # ignores these; Pi 4 requires start4.elf + fixup4.dat.
  for f in "$SRC"/*.elf "$SRC"/*.dat "$SRC"/*.bin; do
    [ -e "$f" ] && cp "$f" "$FAT"/
  done

  # config.txt — minimal and board-agnostic. arm_64bit + enable_uart are safe on
  # all boards; dtparam=pciex1 enables the PCIe link so an NVMe root works on Pi 5
  # (no-op on Pi 4). The [tryboot] section drives the Sledgehammer one-shot below.
  #
  # USB power: both boards current-limit the USB ports unless told otherwise, which
  # browns out bus-powered peripherals (USB SSD/NVMe adapters, hubs, hungry sticks)
  # — exactly the devices a from-USB install image boots off. The knob is
  # board-specific and each is ignored by the other's firmware, so we set both under
  # the matching [pi*] filter:
  #   Pi 5   -> usb_max_current_enable=1 : lift the 600 mA total cap to the full
  #             1.6 A even when the PSU doesn't advertise 5 A (5 A PSUs enable it
  #             automatically; this forces it for third-party supplies).
  #   Pi 4   -> max_usb_current=1        : raise the 600 mA total cap to 1.2 A.
  cat > "$FAT/config.txt" <<CFG
# Town OS — Raspberry Pi (Pi 4/400/CM4, Pi 5/CM5). Native GPU-bootloader boot.
arm_64bit=1
enable_uart=1
initramfs initramfs-linux.img followkernel
dtparam=pciex1

[pi5]
usb_max_current_enable=1

[pi4]
max_usb_current=1

[all]

[tryboot]
cmdline=cmdline_sledge.txt
CFG

  # cmdline.txt — one line. console=serial0 is rewritten by the firmware to the
  # board's real UART (ttyS0 on Pi 4, ttyAMA10 on Pi 5); tty1 is the HDMI console.
  # root=UUID=<data> is exactly what the town-squashfs initrd hook expects.
  CMDLINE="console=serial0,115200 console=tty1 root=UUID=$DATA_UUID rootfstype=ext4 rootwait rw"
  printf '%s\n' "$CMDLINE" > "$FAT/cmdline.txt"
  # Sledgehammer cmdline: identical plus the trigger param. Selected only by a
  # one-shot `reboot "0 tryboot"`, which the firmware auto-reverts next boot — so
  # town.sledgehammer reaches /proc/cmdline exactly as the GRUB entry did, and the
  # sledgehammer.service / getty consumers are unchanged.
  printf '%s town.sledgehammer\n' "$CMDLINE" > "$FAT/cmdline_sledge.txt"

  # autoboot.txt: boot from partition 2 (our FAT ESP) explicitly, so the firmware
  # never lingers on the unformatted 1 MiB part1.
  cat > "$FAT/autoboot.txt" <<AUTOBOOT
[all]
boot_partition=2
AUTOBOOT

  print_info "Raspberry Pi boot files staged on partition 2 (FAT)."
elif [ -n "$RG35XX" ]; then
  # ---- Native Anbernic RG35XX boot: U-Boot + extlinux (no UEFI, no GRUB) ----
  # Chain: H700 BootROM -> u-boot-sunxi-with-spl.bin from raw sector 256 (written
  # at the very end of this script, after the partition table is final) -> U-Boot
  # scans the partitions for /extlinux/extlinux.conf -> loads Image + initramfs +
  # DTB off this FAT partition. From the kernel onward everything is identical to
  # the other targets: root=UUID=<data> is what the town-squashfs hook expects.
  print_info "Staging RG35XX boot files onto the FAT partition (U-Boot/extlinux, no GRUB)..."
  FAT="$MOUNT_POINT/boot/efi"
  SRC="$MOUNT_POINT/boot"

  # ALARM's linux-aarch64 installs the raw ARM64 kernel as /boot/Image and the
  # device trees under /boot/dtbs/<vendor>/.
  [ -f "$SRC/Image" ] || { echo "expected $SRC/Image from $KERNEL_PKG but it is missing" >&2; exit 1; }
  cp "$SRC/Image" "$FAT/Image"
  INITRD_SRC=$(ls "$SRC"/initramfs-*.img | grep -v fallback | head -1)
  cp "$INITRD_SRC" "$FAT/initramfs-linux.img"

  # Ship every H700 board DTB, not just the selected one, so the board can be
  # changed by editing extlinux.conf on the card with no rebuild.
  cp "$SRC"/dtbs/allwinner/sun50i-h700-anbernic-*.dtb "$FAT"/ 2>/dev/null || true
  # An absolute path in RG35XX_DTB is a caller-supplied .dtb (e.g. a Pro DT from
  # KNULLI/ROCKNIX): copy it in and reference it by basename.
  case "$RG35XX_DTB" in
    /*) cp "$RG35XX_DTB" "$FAT"/ ; RG35XX_DTB="$(basename "$RG35XX_DTB")" ;;
  esac
  [ -f "$FAT/$RG35XX_DTB" ] || {
    echo "device tree $RG35XX_DTB not found; staged DTBs: $(cd "$FAT" && echo *.dtb)" >&2
    exit 1; }

  # Stage BOTH DRAM variants of the bootloader on the boot partition. They are
  # not read from there (the BootROM only looks at raw sectors) — they are there
  # so a unit whose RAM type was guessed wrong can be rescued by re-writing
  # 128 KiB of the card instead of rebuilding the image:
  #   dd if=u-boot-sunxi-with-spl-lpddr3.bin of=/dev/sdX bs=1k seek=128 conv=notrunc
  cp "$SRC"/u-boot-sunxi-with-spl-*.bin "$FAT"/
  # Stash the SELECTED variant outside the image: it is written into the raw
  # sectors at the very end of the build, long after $MOUNT_POINT is unmounted.
  cp "$SRC/u-boot-sunxi-with-spl-${RG35XX_DRAM}.bin" /tmp/town-uboot.bin

  # Kernel command line. THE SCREEN IS THE CONSOLE: console=tty0 and nothing
  # else. Everything the box needs — kernel messages, the ttyforce installer, the
  # login getty — lands on the handheld's own panel, driven by its own buttons
  # (our device tree maps them to keyboard codes; see dts/). No serial console is
  # configured anywhere in this image, so nothing has to be soldered to or
  # plugged in to set the machine up.
  #
  # The town-installer hook points ttyforce at the LAST console=, so with tty0
  # the sole entry the installer runs on the panel. That makes the display a HARD
  # dependency of provisioning, which is exactly why the patched kernel is the
  # default and why the build verifies the panel node survives into the DTB.
  CMDLINE="console=tty0 root=UUID=$DATA_UUID rootfstype=ext4 rootwait rw"

  # extlinux.conf — U-Boot's bootstd/syslinux bootmeth finds this by scanning
  # partitions; no boot.scr and no mkimage needed. The second LABEL is the
  # Sledgehammer entry: with no GRUB there is no grub-reboot/grubenv one-shot, so
  # the trigger flips DEFAULT here instead (see the grub-reboot shim below), and
  # scripts/sledgehammer.sh flips it back before it reboots.
  mkdir -p "$FAT/extlinux"
  cat > "$FAT/extlinux/extlinux.conf" <<EXTLINUX
# Town OS — Anbernic RG35XX (Allwinner H700). Booted by U-Boot from this
# partition; the bootloader itself lives in raw sectors at 128 KiB.
DEFAULT townos
PROMPT 0
TIMEOUT 20

LABEL townos
    MENU LABEL Town OS
    LINUX /Image
    INITRD /initramfs-linux.img
    FDT /$RG35XX_DTB
    APPEND $CMDLINE

LABEL sledgehammer
    MENU LABEL Sledgehammer - Erase Permanent Storage And Reboot
    LINUX /Image
    INITRD /initramfs-linux.img
    FDT /$RG35XX_DTB
    APPEND $CMDLINE town.sledgehammer
EXTLINUX

  # grub-reboot shim. ttyforce triggers a sledgehammer wipe by running
  # `grub-reboot "<menu title>"` and rebooting; that interface is baked into the
  # ttyforce getty invocation (scripts/ttyforce-getty.sh), and the real
  # grub-reboot from the `grub` package is inert here — this image has no
  # grub.cfg and no grubenv. Replace it with a shim that performs the equivalent
  # one-shot in extlinux terms. It deliberately overwrites /usr/bin/grub-reboot
  # rather than shadowing it from /usr/local/bin, so it wins no matter how
  # ttyforce resolves the command.
  cat > "$MOUNT_POINT/usr/bin/grub-reboot" <<'GRUBSHIM'
#!/bin/sh
# Town OS (Anbernic RG35XX / U-Boot) — grub-reboot shim, installed by
# make/install.sh. There is no GRUB on this image: boot entries live in
# extlinux.conf on the FAT boot partition. Select the next boot by pointing
# DEFAULT at the matching label. scripts/sledgehammer.sh resets it to `townos`
# on the way through, which is what makes this a ONE-SHOT like grub-reboot.
set -e
conf=/boot/efi/extlinux/extlinux.conf
[ -f "$conf" ] || { echo "grub-reboot: $conf not found" >&2; exit 1; }
case "${1:-}" in
  *[Ss]ledgehammer*) label=sledgehammer ;;
  *)                 label=townos ;;
esac
sed -i "s/^DEFAULT .*/DEFAULT $label/" "$conf"
sync
GRUBSHIM
  chmod 755 "$MOUNT_POINT/usr/bin/grub-reboot"

  print_info "RG35XX boot files staged on partition 2 (FAT); DTB: $RG35XX_DTB"
else

print_info "Installing GRUB bootloader..."

mkdir -p "$MOUNT_POINT/boot/grub"

# Detect kernel and initramfs filenames. The kernel image name is arch-specific:
# x86_64 installs /boot/vmlinuz-<pkg>; Arch Linux ARM's linux-aarch64 installs the
# raw ARM64 kernel as /boot/Image. GRUB's arm64-efi `linux` command boots Image.
case "$ARCH" in
  x86_64)  KERNEL=$(basename $(ls "$MOUNT_POINT"/boot/vmlinuz-* | head -1)) ;;
  aarch64) KERNEL=$(basename $(ls "$MOUNT_POINT"/boot/Image | head -1)) ;;
esac
INITRD=$(basename $(ls "$MOUNT_POINT"/boot/initramfs-*.img | grep -v fallback | head -1))

# Default boot entry. The menu order below is: 0 = "Town OS" (console=tty0,
# needs a keyboard/monitor), 1 = "Town OS (Serial Console)" (console=$SERIAL_TTY,
# which is ttyS0 on x86_64 and ttyAMA0 on aarch64). When SERIAL_CONSOLE is set we
# default to the serial entry so the machine boots headless on the serial port
# with no keyboard required.
if [ -n "$SERIAL_CONSOLE" ]; then
  GRUB_DEFAULT_ENTRY=1
  print_info "Serial console requested: defaulting GRUB to the serial entry (${SERIAL_TTY},115200)."
else
  GRUB_DEFAULT_ENTRY=0
fi

# Write grub.cfg directly — grub-mkconfig can't resolve UUIDs correctly
# inside a loopback chroot, so we generate a known-correct config
cat > "$MOUNT_POINT/boot/grub/grub.cfg" <<EOF
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

set timeout=5

insmod part_gpt
insmod ext2
insmod search_fs_uuid
insmod loadenv

search --no-floppy --fs-uuid --set=root $DATA_UUID

# Honor one-shot boots set by \`grub-reboot\` (writes next_entry to grubenv).
# Without this, ttyforce's sledgehammer trigger silently no-ops.
load_env
if [ "\${next_entry}" ] ; then
    set default="\${next_entry}"
    set next_entry=
    save_env next_entry
else
    set default=$GRUB_DEFAULT_ENTRY
fi

menuentry "Town OS" {
    linux /boot/$KERNEL root=UUID=$DATA_UUID rootwait rw console=tty0
    initrd /boot/$INITRD
}

menuentry "Town OS (Serial Console)" {
    linux /boot/$KERNEL root=UUID=$DATA_UUID rootwait rw console=${SERIAL_TTY},115200
    initrd /boot/$INITRD
}

menuentry "Sledgehammer - Erase Permanent Storage And Reboot" {
    linux /boot/$KERNEL root=UUID=$DATA_UUID rootwait rw console=tty0 console=${SERIAL_TTY},115200 town.sledgehammer
    initrd /boot/$INITRD
}
EOF

# Initialize grubenv so \`grub-reboot\` / \`load_env\` have a file to read/write
chroot_cmd grub-editenv /boot/grub/grubenv create

# UEFI GRUB (both arches). --removable writes the firmware fallback binary
# (BOOTX64.EFI on x86_64, BOOTAA64.EFI on aarch64) so the image boots without
# an NVRAM entry — required for removable media / fresh VMs.
chroot_cmd grub-install --target="$GRUB_EFI_TARGET" \
    --efi-directory="/boot/efi" \
    --boot-directory="/boot" \
    --removable \
    --recheck $DEVICE

# BIOS (legacy) GRUB is x86-only; aarch64 has no BIOS firmware.
if [ "$ARCH" = "x86_64" ]; then
  chroot_cmd grub-install --target=i386-pc \
      --boot-directory="/boot" \
      --recheck \
      "$DEVICE"
fi

fi  # end UEFI/GRUB vs native-boot (Pi / RG35XX)

# --- Build squashfs image ---
print_info "Building squashfs root image..."

# Unmount EFI before creating squashfs
umount "$MOUNT_POINT/boot/efi"

# Create squashfs from the rootfs, excluding /boot (it stays on Part3 for GRUB).
# Use gzip (zlib): squashfs zlib decompression is built into the kernel on every
# arch, whereas zstd squashfs support (CONFIG_SQUASHFS_ZSTD / the zstd module) is
# not present in the aarch64 kernel, so a zstd image fails to mount at boot there.
# gzip keeps the compressor consistent across x86_64 and aarch64.
mksquashfs "$MOUNT_POINT" /tmp/town-root.sfs -comp gzip -noappend -e boot

# --- Rebuild the data filesystem cleanly from the final contents ---
print_info "Rebuilding data filesystem from final contents..."

# The data partition was mkfs'd at the full build size and pacstrapped with the
# whole rootfs, so simply deleting the rootfs and running `resize2fs -M` leaves
# ~1.2G of free space that resize2fs cannot reclaim — it is stranded by the
# original 12G metadata/block-group layout. Instead, recreate the filesystem from
# scratch containing ONLY the final content (root.sfs + /boot); a clean fs lays
# the data out contiguously so the later `resize2fs -M` reaches the true minimum.
# Stage /boot (root.sfs is still in /tmp), drop the dead uncompressed-kernel copy,
# then mkfs preserving the label AND UUID so the already-written grub.cfg
# (search --fs-uuid / root=UUID=$DATA_UUID) and the /boot bind-mount still resolve.
rm -f "$MOUNT_POINT/boot/Image.gz"   # GRUB boots /boot/Image; the .gz copy is unused (aarch64)
STAGE=$(mktemp -d)
cp -a "$MOUNT_POINT/boot" "$STAGE/boot"
umount "$MOUNT_POINT"

mkfs.ext4 -F -q -L TOWN_DATA -U "$DATA_UUID" "$PART3"
mount "$PART3" "$MOUNT_POINT"
cp -a "$STAGE/boot" "$MOUNT_POINT/boot"
mv /tmp/town-root.sfs "$MOUNT_POINT/root.sfs"
rm -rf "$STAGE"
sync

# --- Resize filesystem and shrink image ---
print_info "Shrinking data partition to fit contents..."

umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT" 2>/dev/null || true

# Shrink to minimum — now effective because the content sits contiguously in a
# freshly created filesystem. e2fsck returns 1 when it corrects minor issues
# (e.g. creating lost+found); that's OK.
e2fsck -fy "$PART3" || [ $? -le 1 ]
resize2fs -M "$PART3"

# Calculate the new filesystem size in bytes
eval $(dumpe2fs -h "$PART3" 2>/dev/null | awk '/^Block count:/{printf "BLOCK_COUNT=%s ",$3} /^Block size:/{printf "BLOCK_SIZE=%s",$3}')
FS_BYTES=$((BLOCK_COUNT * BLOCK_SIZE))

# Get partition 3 start offset in bytes
PART3_START_BYTES=$(parted -s "$DEVICE" unit B print | awk '/^ 3/{print $2}' | tr -d 'B')
PART3_END_BYTES=$((PART3_START_BYTES + FS_BYTES))

# Resize partition 3 to match the shrunk filesystem
(yes || true) | parted ---pretend-input-tty "$DEVICE" resizepart 3 ${PART3_END_BYTES}B

# Dump the partition table NOW while GPT is still intact on the loopback
# (after truncation the backup GPT header is gone and sfdisk can't read it)
sfdisk -d "$DEVICE" | grep -v '^last-lba:' > /tmp/town-ptable.dump

# Detach loopback
eject_loopback

# Truncate image to end of partition 3 plus 1MB for backup GPT
IMAGE_BYTES=$((PART3_END_BYTES + 1048576))
truncate -s "$IMAGE_BYTES" "$IMAGE"

# Rewrite partition table — sfdisk places the backup GPT at the new disk end
sfdisk --force "$IMAGE" < /tmp/town-ptable.dump
rm -f /tmp/town-ptable.dump

# --- Write U-Boot into the raw boot sectors (RG35XX) ---
# Done LAST, straight into the image file, so nothing that rewrites the partition
# table (parted resizepart, the sfdisk restore above) can land on top of it.
#
# seek=128 (128 KiB, sector 256) rather than the traditional 8 KiB: every ARM64
# Allwinner SoC checks 8 KiB first and then 128 KiB, and only the second location
# clears the GPT partition-entry array. Nothing else may live between 128 KiB and
# part1 at 4 MiB — the size check below enforces that.
if [ -n "$RG35XX" ]; then
  UBOOT_OFFSET_KIB=128
  UBOOT_MAX_BYTES=$(( (PART1_START_MIB * 1024 - UBOOT_OFFSET_KIB) * 1024 ))
  UBOOT_BYTES=$(stat -c %s /tmp/town-uboot.bin)
  if [ "$UBOOT_BYTES" -gt "$UBOOT_MAX_BYTES" ]; then
    echo "u-boot-sunxi-with-spl.bin is ${UBOOT_BYTES}B — it would overrun partition 1" >&2
    echo "(only ${UBOOT_MAX_BYTES}B free between ${UBOOT_OFFSET_KIB}KiB and ${PART1_START_MIB}MiB)" >&2
    exit 1
  fi
  print_info "Writing U-Boot (${RG35XX_DRAM}) to raw sector 256 (${UBOOT_OFFSET_KIB} KiB), ${UBOOT_BYTES} bytes..."
  dd if=/tmp/town-uboot.bin of="$IMAGE" bs=1k seek="$UBOOT_OFFSET_KIB" conv=notrunc status=none
  rm -f /tmp/town-uboot.bin
  sync
fi

print_info "Image built successfully: $IMAGE ($(du -h "$IMAGE" | awk '{print $1}'))"

exit 0
