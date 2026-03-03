#!/bin/sh

set -eo pipefail
DEBUG="${DEBUG:-}"

# stub commands for zfs and zpool; set DEBUG to a non-empty string to see the
# commands output instead of actually run.
zfs() {
  if [ "x$DEBUG" = "x" ]
  then
    `which zfs` $*
  else
    echo "$(which zfs) $*"
  fi
  return $?
}

zpool() {
  if [ "x$DEBUG" = "x" ]
  then
    `which zpool` $*
  else
    echo "$(which zpool) $*"
  fi
  return $?
}

debug() {
  if [ "x$DEBUG" != "x" ]
  then
    echo $*
  fi
}
