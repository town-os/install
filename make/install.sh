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

# Part2: EFI System Partition
print_info "Creating EFI System Partition..."
parted -s "$DEVICE" mkpart ESP fat32 2MiB 66MiB
parted -s "$DEVICE" set 2 esp on

# Part3: Data partition (holds /boot + root.sfs, >= 10GB)
print_info "Creating data partition (>= 10GB)..."
parted -s "$DEVICE" mkpart primary ext4 66MiB 100%

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

# Install initcpio hooks into the chroot
cp ./initcpio/install/town-squashfs $MOUNT_POINT/usr/lib/initcpio/install/town-squashfs
cp ./initcpio/hooks/town-squashfs $MOUNT_POINT/usr/lib/initcpio/hooks/town-squashfs
cp ./initcpio/install/town-installer $MOUNT_POINT/usr/lib/initcpio/install/town-installer
cp ./initcpio/hooks/town-installer $MOUNT_POINT/usr/lib/initcpio/hooks/town-installer

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-quay.io/town/town:rc.latest}"

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
if [ -n "$PACKAGE_DNS" ]; then
  sed -i "s|@PACKAGE_DNS@|-package-dns ${PACKAGE_DNS}|g" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
else
  sed -i "/@PACKAGE_DNS@/d" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
fi
# Keep the serial-getty's console gate IN TANDEM with the GRUB kernel `console=`
# parameter: both derive from $SERIAL_TTY (ttyS0 on x86_64, ttyAMA0 on aarch64),
# so the getty only starts on the exact serial device the kernel was told to use.
sed -i "s|^ConditionKernelCommandLine=console=.*|ConditionKernelCommandLine=console=${SERIAL_TTY},115200|" \
  $MOUNT_POINT/etc/systemd/system/town-os-serial-getty@.service
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

podman exec town-build busctl call \
  org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager EnableUnitFiles "asbb" 12 \
  "town-os-overlays.service" \
  "town-os-system--rolodex.service" \
  "town-os-podman-api.service" \
  "town-os-systemcontroller.service" \
  "town-os-sledgehammer.service" \
  "town-os-network-diag.timer" \
  "systemd-networkd.service" \
  "systemd-networkd-wait-online.service" \
  "systemd-resolved.service" \
  "sshd.service" \
  "town-os-getty@tty1.service" \
  "town-os-serial-getty@${SERIAL_TTY}.service" \
  false false

# Mask default getty units so they don't conflict with ttyforce getty
podman exec town-build busctl call \
  org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager MaskUnitFiles "asbb" 2 \
  "getty@tty1.service" \
  "serial-getty@${SERIAL_TTY}.service" \
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

print_info "Installing GRUB bootloader..."

mkdir -p "$MOUNT_POINT/boot/grub"
DATA_UUID=$(blkid -s UUID -o value "$PART3")

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

# --- Build squashfs image ---
print_info "Building squashfs root image..."

# Unmount EFI before creating squashfs
umount "$MOUNT_POINT/boot/efi"

# Create squashfs from the rootfs, excluding /boot (it stays on Part3 for GRUB)
mksquashfs "$MOUNT_POINT" /tmp/town-root.sfs -comp zstd -noappend -e boot

# Remove everything from Part3 except /boot
find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 ! -name boot -exec rm -rf {} +

# Place squashfs on the data partition alongside /boot
mv /tmp/town-root.sfs "$MOUNT_POINT/root.sfs"
sync

# --- Resize filesystem and shrink image ---
print_info "Shrinking data partition to fit contents..."

umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT" 2>/dev/null || true

# Check and shrink the ext4 filesystem to minimum size
# e2fsck returns 1 when it corrects errors (e.g. creating lost+found); that's OK
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
