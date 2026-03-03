#!/bin/bash

# make-storage.sh — entry point for storage provisioning.
# Reads town-os.yaml and dispatches to the appropriate backend script.

set -euo pipefail

SCRIPT_DIR="$(dirname $0)"

town_config() {
  grep "^${1}:" /usr/lib/town-os/town-os.yaml | awk '{ print $2 }' | tr -d '"' | tr -d "'"
}

BACKEND=$(town_config storage_backend)
BACKEND="${BACKEND:-btrfs}"

case "$BACKEND" in
  btrfs)
    exec "$SCRIPT_DIR/make-btrfs.sh"
    ;;
  zfs)
    exec "$SCRIPT_DIR/make-zfs.sh"
    ;;
  *)
    echo "ERROR: unknown storage_backend '$BACKEND' in /usr/lib/town-os/town-os.yaml" >&2
    exit 1
    ;;
esac
