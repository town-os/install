#!/bin/sh

# btrfs-debug.sh — debug wrappers for btrfs commands.
# Source this file to get stub commands that print instead of execute
# when DEBUG is set to a non-empty string.

set -eo pipefail
DEBUG="${DEBUG:-}"

btrfs() {
  if [ "x$DEBUG" = "x" ]
  then
    $(which btrfs) $*
  else
    echo "$(which btrfs) $*"
  fi
  return $?
}

mkfs_btrfs() {
  if [ "x$DEBUG" = "x" ]
  then
    $(which mkfs.btrfs) $*
  else
    echo "$(which mkfs.btrfs) $*"
  fi
  return $?
}

mdadm() {
  if [ "x$DEBUG" = "x" ]
  then
    $(which mdadm) $*
  else
    echo "$(which mdadm) $*"
  fi
  return $?
}

debug() {
  if [ "x$DEBUG" != "x" ]
  then
    echo "$*"
  fi
}
