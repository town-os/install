#!/usr/bin/env bash
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image.sh IMAGE_SIZE IMAGE}"

sudo -E CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" UI_IMAGE="${UI_IMAGE}" "${PWD}/install.sh" "${IMAGE_SIZE}" "${IMAGE}"
