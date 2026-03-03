#!/bin/bash

# detect-disks.sh — shared disk detection logic for storage provisioning.
# Sourced by make-zfs.sh and make-btrfs.sh.
#
# Exports:
#   disk_list  — array of /dev paths for usable disks
#   disk_count — number of usable disks

set -euo pipefail

DEBUG="${DEBUG:-}"

debug() {
  if [ "x$DEBUG" != "x" ]
  then
    echo "$*"
  fi
}

# Search mount -l output for the device mounted at a given path prefix.
getmount() {
  echo $(mount -l | grep "on $1 type" | awk '{ print $1 }')
}

# Determine if a block device name is part of the boot/root filesystem.
# Checks /boot first, then /sysroot (atomic installs), then /.
onroot() {
  out="$(getmount /boot)"
  if [ "x$out" = "x" ]
  then
    out="$(getmount /sysroot)"
  fi
  if [ "x$out" = "x" ]
  then
    out="$(getmount /)"
  fi

  echo "$(basename $out)" | grep -qE "^$1"
  return $?
}

# Collect swap devices (they don't appear in mount)
swap="$(for disk in $(swapon | awk '{ print $1 }' | tail -n +2); do basename $disk; done)"

nvme_disks=()
sd_disks=()

# Enumerate known block devices created by the kernel
# FIXME we need to enumerate disks, not block devices; this will break sooner or later
for disk in /sys/block/*
do
  # If this device is swap, skip it
  found=""
  for s in $swap
  do
    if echo $s | grep -q $(basename $disk)
    then
      found=1
    fi
  done

  if [ "x$found" != "x" ] || onroot $(basename $disk)
  then
    continue
  fi

  debug "not on root: $disk"

  # Check that device actually exists (isn't removed)
  if ! cat $disk/events | grep -q media_change
  then
    if echo $(basename $disk) | grep -qE '^nvme'
    then
      nvme_disks=(${nvme_disks[@]} /dev/$(basename $disk))
    elif echo $(basename $disk) | grep -qE '^sd'
    then
      sd_disks=(${sd_disks[@]} /dev/$(basename $disk))
    fi
  fi
done

debug "nvme: count: ${#nvme_disks[@]} - items: ${nvme_disks[@]}"
debug "sd: count: ${#sd_disks[@]} - items: ${sd_disks[@]}"

disk_list=(${nvme_disks[@]})

# Prefer nvme if there are more drives
if [ "${#sd_disks[@]}" -gt "${#nvme_disks[@]}" ]
then
  disk_list=(${sd_disks[@]})
fi

disk_count=${#disk_list[@]}

if [ "$disk_count" -eq 0 ]
then
  if [ "x$DEBUG" = "x" ]
  then
    shutdown -h now
  else
    echo "Would have shutdown machine; no extra disks attached"
  fi
fi
