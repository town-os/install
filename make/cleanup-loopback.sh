#!/usr/bin/env bash
set -euo pipefail

mount | grep loop | awk '{ print $3 }' | xargs -I{} sudo fuser -cfk {} || :
mount | grep loop | awk '{ print $3 }' | xargs -I{} sudo umount -Rf {} || :
sudo losetup -D
