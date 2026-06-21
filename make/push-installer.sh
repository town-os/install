#!/usr/bin/env bash
set -euo pipefail

# Build a minimal OCI image that carries the compressed USB image and push it to
# the installer repository. Usage: push-installer.sh [build|push|all] (default
# all). The website's curl|bash installer pulls this image
# and streams /town-os.img.bz2 straight to the USB stick (see ../website
# install.sh), so the layout here must stay in lockstep with that consumer: a
# single file at /town-os.img.bz2 on a scratch base, plus a dummy CMD so the
# installer's `podman create` works (see make/Containerfile.installer).
#
# Tags follow the same arch-suffixed scheme as the controller/rolodex/ui images
# (rc.latest-$(uname -m)): builds are always native, so the build arch is the
# right suffix. Two tags are published:
#   release-<arch>            rolling "latest release for this arch" (the tag the
#                             website pulls)
#   release-<arch>-<YYYYMMDD> immutable point-in-time tag for rollback/audit

# Mode: build (build only), push (push only), or all (build then push).
MODE="${1:-all}"

IMAGE="${IMAGE:?IMAGE is required}"
INSTALLER_BASE="${INSTALLER_BASE:-quay.io/town/installer}"
INSTALLER_TAG="${INSTALLER_TAG:-release-$(uname -m)}"
DATED_TAG="${INSTALLER_TAG}-$(date +%Y%m%d)"

ROLLING_REF="${INSTALLER_BASE}:${INSTALLER_TAG}"
DATED_REF="${INSTALLER_BASE}:${DATED_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERFILE="${SCRIPT_DIR}/Containerfile.installer"

# Build and push with `sudo podman`, consistent with the rest of the build
# tooling (make/image-container.sh) — root's podman storage holds the images.
build_image() {
  local bz2="${IMAGE}.bz2"
  if [ ! -f "$bz2" ]; then
    echo "ERROR: Compressed image ${bz2} not found. Run 'make image-release' first." >&2
    exit 1
  fi

  # Build from a throwaway context holding only the bz2 (named exactly what the
  # Containerfile COPYs). Hardlink it in so we don't copy several GB or hand the
  # whole repo to podman as build context; mktemp inside $PWD keeps the link on
  # the same filesystem, with a cp fallback if that ever spans mounts. The
  # context is user-owned; root reads it fine.
  local ctx
  ctx="$(mktemp -d -p "$PWD" .installer-ctx.XXXXXX)"
  trap 'rm -rf "$ctx"' RETURN
  ln "$bz2" "$ctx/town-os.img.bz2" 2>/dev/null || cp "$bz2" "$ctx/town-os.img.bz2"

  echo "Building ${ROLLING_REF} (also tagged ${DATED_TAG})..."
  sudo podman build -f "$CONTAINERFILE" -t "$ROLLING_REF" -t "$DATED_REF" "$ctx"
}

push_image() {
  echo "Pushing ${ROLLING_REF}..."
  sudo podman push "$ROLLING_REF"
  echo "Pushing ${DATED_REF}..."
  sudo podman push "$DATED_REF"
  echo "Installer image published: ${ROLLING_REF} and ${DATED_REF}"
}

case "$MODE" in
  build) build_image ;;
  push)  push_image ;;
  all)   build_image; push_image ;;
  *)     echo "ERROR: unknown mode '${MODE}' (expected build|push|all)" >&2; exit 1 ;;
esac
