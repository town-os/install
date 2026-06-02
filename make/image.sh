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

# install.sh needs Arch-only tools (pacstrap, arch-chroot, genfstab, mkinitcpio).
# On Arch hosts, build natively. On any other host, build inside an x86_64 Arch
# container (see image-container.sh / Containerfile.build).
ID=""
[ -f /etc/os-release ] && . /etc/os-release

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    if command -v pacstrap >/dev/null 2>&1; then
      exec sudo CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" ROLODEX_IMAGE="${ROLODEX_IMAGE}" \
        UI_IMAGE="${UI_IMAGE}" LOCAL_DNS="${LOCAL_DNS}" TTYFORCE_DEV="${TTYFORCE_DEV}" \
        TTYFORCE_LATEST="${TTYFORCE_LATEST}" IMAGE_HOSTNAME="${IMAGE_HOSTNAME}" \
        "${SCRIPT_DIR}/install.sh" "${IMAGE_SIZE}" "${IMAGE}"
    fi
    ;;
esac

exec "${SCRIPT_DIR}/image-container.sh" "${IMAGE_SIZE}" "${IMAGE}"
