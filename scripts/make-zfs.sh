#!/bin/bash

set -euo pipefail

POOL="${POOL:-town-os}"
DEBUG="${DEBUG:-}"

. $(dirname $0)/zfs-debug.sh
. $(dirname $0)/detect-disks.sh

# check if the pool already exists before provisioning it. If the pool is
# already imported, just exit. If not, try to import it and ensure it imported
# correctly, then exit. Otherwise, continue with the script.
if ! (zpool list | grep -qE "^$POOL") && ! (zpool import $POOL && (zpool list | grep -qE "^$POOL"))
then
  if [ "$disk_count" -eq 1 ]
  then
    zpool create $POOL ${disk_list[@]}
  elif [ "$disk_count" -eq 2 ]
  then
    zpool create $POOL mirror ${disk_list[@]}
  else
    zpool create $POOL raidz ${disk_list[@]}
  fi

  # Create containers dataset for podman storage
  zfs create -o mountpoint=/town-os/containers $POOL/containers

  for sub in var etc
  do
    mkdir -p /overlays/$sub

    # FIXME: storage percentage sizing
    zfs create -V 50G $POOL/$sub
    if [ "x$DEBUG" = "x" ]
    then
      mkfs.ext4 /dev/zvol/$POOL/$sub
    else
      debug making $sub filesystem: /dev/zvol/$POOL/$sub
    fi
  done

  systemctl daemon-reload
  mount -a
fi

if [ "x$DEBUG" = "x" ]
then
  for sub in var etc
  do
    mount /dev/zvol/$POOL/$sub /overlays/$sub
    mkdir -p /overlays/$sub/work
    mkdir -p /overlays/$sub/root
    mkdir -p /overlays/$sub/merged
  done

  perl -i -pe 's!^# premount (\w+)\n.*$!# premount $1\noverlay /$1 overlay rw,upperdir=/overlays/$1/root,lowerdir=/usb/$1,workdir=/overlays/$1/work 0 0!mg' /etc/fstab
  mount -a
fi
