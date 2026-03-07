#!/usr/bin/env bash
set -euo pipefail

mount | grep loop | awk '{ print $3 }' | xargs -I{} sudo -E fuser -cfk {} || :
mount | grep loop | awk '{ print $3 }' | xargs -I{} sudo -E umount -Rf {} || :
sudo -E losetup -D
