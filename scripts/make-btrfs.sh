#!/bin/bash

set -euo pipefail

LABEL="${LABEL:-town-os}"
DEBUG="${DEBUG:-}"

. $(dirname $0)/btrfs-debug.sh
. $(dirname $0)/detect-disks.sh

town_config() {
  grep "^${1}:" /usr/lib/town-os/town-os.yaml | awk '{ print $2 }' | tr -d '"' | tr -d "'"
}

RAID_MODE=$(town_config btrfs_raid_mode)
RAID_MODE="${RAID_MODE:-native}"

MOUNT_POINT="/town-os"

# Check if the btrfs filesystem already exists; if so, mount and skip creation.
if blkid -L "$LABEL" >/dev/null 2>&1
then
  debug "btrfs filesystem labeled '$LABEL' already exists, mounting"
  mkdir -p "$MOUNT_POINT"
  if ! mountpoint -q "$MOUNT_POINT"
  then
    mount -L "$LABEL" "$MOUNT_POINT"
  fi
else
  if [ "$RAID_MODE" = "mdadm" ]
  then
    # mdadm mode: create an md array, then format it
    debug "Creating mdadm array from ${disk_count} disk(s): ${disk_list[*]}"
    mdadm --create /dev/md0 --level=1 --raid-devices=${disk_count} ${disk_list[@]} --run
    mkfs_btrfs -f -L "$LABEL" /dev/md0
    mkdir -p "$MOUNT_POINT"
    mount /dev/md0 "$MOUNT_POINT"
  else
    # native btrfs raid mode
    if [ "$disk_count" -eq 1 ]
    then
      mkfs_btrfs -f -L "$LABEL" ${disk_list[0]}
    elif [ "$disk_count" -eq 2 ]
    then
      mkfs_btrfs -f -L "$LABEL" -d raid1 -m raid1 ${disk_list[@]}
    else
      mkfs_btrfs -f -L "$LABEL" -d raid5 -m raid1 ${disk_list[@]}
    fi

    mkdir -p "$MOUNT_POINT"
    mount -L "$LABEL" "$MOUNT_POINT"
  fi

  # Create subvolumes
  btrfs subvolume create "$MOUNT_POINT/@var"
  btrfs subvolume create "$MOUNT_POINT/@etc"
fi

# Ensure containers directory exists for podman storage
mkdir -p "$MOUNT_POINT/containers"

# Mount subvolumes for overlays
for sub in var etc
do
  mkdir -p /overlays/$sub
  if ! mountpoint -q /overlays/$sub
  then
    mount -o subvol=@$sub -L "$LABEL" /overlays/$sub
  fi
done

systemctl daemon-reload
mount -a

if [ "x$DEBUG" = "x" ]
then
  for sub in var etc
  do
    mkdir -p /overlays/$sub/work
    mkdir -p /overlays/$sub/root
    mkdir -p /overlays/$sub/merged
  done

  perl -i -pe 's!^# premount (\w+)\n.*$!# premount $1\noverlay /$1 overlay rw,upperdir=/overlays/$1/root,lowerdir=/usb/$1,workdir=/overlays/$1/work 0 0!mg' /etc/fstab
  mount -a
fi
