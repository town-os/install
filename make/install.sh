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

if [ -f "$IMAGE" ]
then
  eject_loopback
  rm -f "$IMAGE"
fi

MOUNT_POINT=$(mktemp -d)

trap 'cleanup_mount; eject_loopback' EXIT

truncate -s "$IMAGE_SIZE" "$IMAGE"

losetup -f --partscan "$IMAGE"
DEVICE=$(losetup -j "$IMAGE" | awk -F: '{ print $1 }' | head -1)

print_info "Creating GPT partition table..."
parted -s "$DEVICE" mklabel gpt

# Part1: BIOS boot partition (raw, for GRUB core image embed only — no filesystem).
# The partition is created on every arch to keep partition numbering identical
# (PART1/PART2/PART3), but the bios_grub flag and BIOS GRUB only apply to x86_64
# — aarch64 is UEFI-only and never uses this partition.
print_info "Creating BIOS boot partition..."
parted -s "$DEVICE" mkpart grub 1MiB 2MiB
if [ "$ARCH" = "x86_64" ]; then
  parted -s "$DEVICE" set 1 bios_grub on
fi

# Part2: EFI System Partition (UEFI/GRUB builds) OR the Pi boot partition (RPI).
# 64 MiB is plenty for a GRUB stub, but a native Pi boot partition must hold the
# kernel, initramfs, all board DTBs, the overlays/ tree, and the GPU firmware, so
# the Pi build grows it to 512 MiB. It stays a FAT32 partition flagged ESP either
# way — recent Pi 4/5 EEPROMs find the first bootable FAT partition on a 512-byte
# GPT disk (the unformatted 1 MiB part1 is skipped).
print_info "Creating EFI System Partition..."
if [ -n "$RPI" ]; then ESP_END_MIB=514; else ESP_END_MIB=66; fi
parted -s "$DEVICE" mkpart ESP fat32 2MiB "${ESP_END_MIB}MiB"
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
env -i HOME=/root PACKAGE_DNS="$PACKAGE_DNS" IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-town-os}" TTYFORCE_DEV="${TTYFORCE_DEV:-}" TTYFORCE_LATEST="${TTYFORCE_LATEST:-}" arch-chroot $MOUNT_POINT sh -lc "bash /usr/lib/town-os/scripts/configure.sh"

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
  cat > "$FAT/config.txt" <<CFG
# Town OS — Raspberry Pi (Pi 4/400/CM4, Pi 5/CM5). Native GPU-bootloader boot.
arm_64bit=1
enable_uart=1
initramfs initramfs-linux.img followkernel
dtparam=pciex1

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

fi  # end UEFI/GRUB vs native-Pi boot

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

print_info "Image built successfully: $IMAGE ($(du -h "$IMAGE" | awk '{print $1}'))"

exit 0
