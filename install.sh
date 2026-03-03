#!/bin/bash

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

IMAGE_SIZE=${1:-10G}
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

print_info "Creating EFI System Partition (ESP)..."
parted -s "$DEVICE" mkpart ESP ext4 1MiB 513MiB
parted -s "$DEVICE" set 1 bios_grub on
parted -s "$DEVICE" mkpart ESP fat32 513MiB 1GiB
parted -s "$DEVICE" set 2 esp on

print_info "Creating data partition..."
parted -s "$DEVICE" mkpart primary ext4 1GiB 100%

# Wait for kernel to update partition table
sleep 2
partprobe "$DEVICE"
sleep 2

PART1="${DEVICE}p1"
PART2="${DEVICE}p2"
PART3="${DEVICE}p3"

print_info "Formatting Boot partition as ext4..."
mkfs.ext4 -L TOWN_BOOT "$PART1"

print_info "Formatting EFI partition as FAT32..."
mkfs.fat -F32 -n TOWN_EFI "$PART2"

print_info "Formatting data partition as ext4..."
mkfs.ext4 -L TOWN_DATA "$PART3"

print_info "Mounting partitions..."
mkdir -p "$MOUNT_POINT"
mount "$PART3" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot"
mount "$PART1" "$MOUNT_POINT/boot"
mkdir -p "$MOUNT_POINT/boot/efi"
mount "$PART2" "$MOUNT_POINT/boot/efi"

PACKAGES="base base-devel avahi clang linux618 podman efibootmgr grub dhcpcd"

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

pacstrap -K $MOUNT_POINT $PACKAGES

print_info "System setup..."

genfstab -U $MOUNT_POINT $MOUNT_POINT/etc/fstab

rsync -a ./systemd/ $MOUNT_POINT/etc/systemd/system/
chroot_cmd mkdir -p /usr/lib/town-os
cp ./town-os.yaml $MOUNT_POINT/usr/lib/town-os/town-os.yaml
rsync -a ./scripts/ $MOUNT_POINT/usr/lib/town-os/scripts/
chroot_cmd bash /usr/lib/town-os/scripts/configure.sh

print_info "Installing GRUB bootloader..."

mkdir -p "$MOUNT_POINT/boot/grub"
chroot_cmd grub-mkconfig -o /boot/grub/grub.cfg

chroot_cmd grub-install --target=x86_64-efi \
    --efi-directory="/boot/efi" \
    --boot-directory="/boot" \
    --removable \
    --recheck $DEVICE

chroot_cmd grub-install --target=i386-pc \
    --boot-directory="/boot" \
    --recheck \
    "$DEVICE"

if [ "x$KEEP_MOUNT" = "x" ]
then
  cleanup_mount
  eject_loopback
  print_info "Image built successfully: $IMAGE"
else
  print_info "Mount preserved at $MOUNT_POINT"
fi

exit 0
