#!/usr/bin/env bash

set -xeou pipefail

export DEBUG=${DEBUG:-}
export KEEP_MOUNT=${KEEP_MOUNT:-}

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

cleanup_mount() {
  print_info "Ejecting loopback and unmounting partitions..."

  if [ -d $MOUNT_POINT ] && mountpoint -q $MOUNT_POINT
  then
    while ! umount -Rf $MOUNT_POINT && ! lsof $MOUNT_POINT
    do
      print_warning "Waiting for processes to finish; do not press Ctrl-C until this process completes"

      fuser -cfk $MOUNT_POINT || :
      systemctl daemon-reload
      sleep 30
    done
  fi

  if [ -d $MOUNT_POINT ]
  then
    rm -rf $MOUNT_POINT
  fi
}

IMAGE_SIZE=${1:-12G}
IMAGE=${2:-image.raw}

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
  rm -f $IMAGE
fi

MOUNT_POINT=$(mktemp -d)
truncate -s $IMAGE_SIZE $IMAGE

losetup -f --partscan $IMAGE
DEVICE=$(losetup -j $IMAGE | awk -F: '{ print $1 }' | head -1)

print_info "Creating GPT partition table..."
parted -s "$DEVICE" mklabel gpt

# Part1: BIOS boot partition (raw, for GRUB core image embed only — no filesystem)
print_info "Creating BIOS boot partition..."
parted -s "$DEVICE" mkpart grub 1MiB 2MiB
parted -s "$DEVICE" set 1 bios_grub on

# Part2: EFI System Partition
print_info "Creating EFI System Partition..."
parted -s "$DEVICE" mkpart ESP fat32 2MiB 514MiB
parted -s "$DEVICE" set 2 esp on

# Part3: Data partition (holds /boot + root.sfs, >= 10GB)
print_info "Creating data partition (>= 10GB)..."
parted -s "$DEVICE" mkpart primary ext4 514MiB 100%

# Wait for kernel to update partition table
sleep 2
partprobe "$DEVICE"
sleep 2

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

PACKAGES="base base-devel avahi clang linux618 podman efibootmgr grub openssh"

if [ "$STORAGE_BACKEND" = "zfs" ]
then
  PACKAGES="$PACKAGES linux618-zfs"
else
  PACKAGES="$PACKAGES btrfs-progs"
  if [ "$BTRFS_RAID_MODE" = "mdadm" ]
  then
    PACKAGES="$PACKAGES mdadm"
  fi
fi

pacstrap -Kc $MOUNT_POINT $PACKAGES

print_info "System setup..."

genfstab -U $MOUNT_POINT >> $MOUNT_POINT/etc/fstab

# Remove the root (/) entry from fstab — root is mounted by the initramfs
# squashfs hook as an overlay, and systemd-remount-fs would fail trying to
# remount the overlay as ext4
sed -i '\|[[:space:]]/[[:space:]]|d' $MOUNT_POINT/etc/fstab

# Install squashfs boot hooks into the chroot
cp ./initcpio/install/town-squashfs $MOUNT_POINT/usr/lib/initcpio/install/town-squashfs
cp ./initcpio/hooks/town-squashfs $MOUNT_POINT/usr/lib/initcpio/hooks/town-squashfs

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-quay.io/town/town:rc.latest}"
UI_IMAGE="${UI_IMAGE:-quay.io/town/ui:rc.latest}"

rsync -a ./systemd/ $MOUNT_POINT/etc/systemd/system/
sed -i "s|quay.io/town/town:rc.latest|${CONTROLLER_IMAGE}|g" $MOUNT_POINT/etc/systemd/system/town-os-systemcontroller.service
sed -i "s|quay.io/town/ui:rc.latest|${UI_IMAGE}|g" $MOUNT_POINT/etc/systemd/system/town-os-ui.service
chroot_cmd mkdir -p /usr/lib/town-os
cp ./town-os.yaml $MOUNT_POINT/usr/lib/town-os/town-os.yaml
rsync -a ./scripts/ $MOUNT_POINT/usr/lib/town-os/scripts/
chroot_cmd bash /usr/lib/town-os/scripts/configure.sh

# Point resolv.conf at systemd-resolved stub — must be done outside chroot
# because arch-chroot bind-mounts /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf "$MOUNT_POINT/etc/resolv.conf"

print_info "Installing GRUB bootloader..."

mkdir -p "$MOUNT_POINT/boot/grub"
DATA_UUID=$(blkid -s UUID -o value "$PART3")

# Detect kernel and initramfs filenames
KERNEL=$(basename $(ls "$MOUNT_POINT"/boot/vmlinuz-* | head -1))
INITRD=$(basename $(ls "$MOUNT_POINT"/boot/initramfs-*.img | grep -v fallback | head -1))

# Write grub.cfg directly — grub-mkconfig can't resolve UUIDs correctly
# inside a loopback chroot, so we generate a known-correct config
cat > "$MOUNT_POINT/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

insmod part_gpt
insmod ext2
insmod search_fs_uuid

search --no-floppy --fs-uuid --set=root $DATA_UUID

menuentry "Town OS" {
    linux /boot/$KERNEL root=UUID=$DATA_UUID rootwait rw console=ttyS0,115200 console=tty0
    initrd /boot/$INITRD
}
EOF

chroot_cmd grub-install --target=x86_64-efi \
    --efi-directory="/boot/efi" \
    --boot-directory="/boot" \
    --removable \
    --recheck $DEVICE

chroot_cmd grub-install --target=i386-pc \
    --boot-directory="/boot" \
    --recheck \
    "$DEVICE"

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
BLOCK_COUNT=$(dumpe2fs -h "$PART3" 2>/dev/null | awk '/^Block count:/{print $3}')
BLOCK_SIZE=$(dumpe2fs -h "$PART3" 2>/dev/null | awk '/^Block size:/{print $3}')
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
