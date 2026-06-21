#!/usr/bin/env bash
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image.sh IMAGE_SIZE IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export CONTROLLER_IMAGE ROLODEX_IMAGE UI_IMAGE
export LOCAL_DNS="${LOCAL_DNS:-}"
export TTYFORCE_DEV="${TTYFORCE_DEV:-}"
export TTYFORCE_LATEST="${TTYFORCE_LATEST:-}"
export IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-}"
export SERIAL_CONSOLE="${SERIAL_CONSOLE:-}"

# Target architecture for the produced image. Defaults to the host arch. Set
# TARGET_ARCH to a different arch (threaded from the Makefile's BUILD_ARCH) to
# cross-build under emulation — that path is container-only (see below).
export TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"

# install.sh needs Arch-only tools (pacstrap, arch-chroot, genfstab, mkinitcpio).
# Native, host-arch builds on Arch hosts run install.sh directly. Cross-arch
# builds (TARGET_ARCH != host) can't run natively, so they always go through the
# container path, which emulates the target via qemu-user-static binfmt. Non-Arch
# hosts use the container path too (native when TARGET_ARCH == host).
ID=""
[ -f /etc/os-release ] && . /etc/os-release

if [ "${TARGET_ARCH}" = "$(uname -m)" ]; then
  case "${ID:-}" in
    arch|manjaro|endeavouros|garuda)
      if command -v pacstrap >/dev/null 2>&1; then
        exec sudo CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" ROLODEX_IMAGE="${ROLODEX_IMAGE}" \
          UI_IMAGE="${UI_IMAGE}" LOCAL_DNS="${LOCAL_DNS}" TTYFORCE_DEV="${TTYFORCE_DEV}" \
          TTYFORCE_LATEST="${TTYFORCE_LATEST}" IMAGE_HOSTNAME="${IMAGE_HOSTNAME}" \
          SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
          "${SCRIPT_DIR}/install.sh" "${IMAGE_SIZE}" "${IMAGE}"
      fi
      ;;
  esac
fi

exec "${SCRIPT_DIR}/image-container.sh" "${IMAGE_SIZE}" "${IMAGE}"
