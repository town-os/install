#!/usr/bin/env bash
# Build a Town OS disk image inside an x86_64 Arch Linux container.
#
# Used on non-Arch hosts, where pacstrap/arch-chroot/mkinitcpio don't exist. The
# unmodified make/install.sh runs inside the builder container (see
# Containerfile.build); the finished image is written back to the repo on the
# host. On aarch64 hosts the x86_64 build executes via whatever x86_64 emulation
# the host already provides (FEX-Emu on Asahi, qemu-user-static elsewhere); this
# script never inspects, registers, or configures binfmt — that is the host's job.
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image-container.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image-container.sh IMAGE_SIZE IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Build the builder image (amd64; podman layer cache makes repeat runs cheap).
sudo podman build --arch amd64 -t town-os-builder \
  -f "$SCRIPT_DIR/Containerfile.build" "$SCRIPT_DIR"

# Run the unmodified install.sh inside the container.
#   --privileged + --cgroupns=host: loopback (losetup --partscan), mount, and the
#     nested town-build systemd container all need real /dev access and cgroups.
#   -v REPO_ROOT:/build -w /build: install.sh uses ./relative paths and writes
#     $IMAGE to the cwd, so the finished image lands in the repo dir on the host.
# Build vars are forwarded explicitly across the sudo boundary (never sudo -E),
# then handed to podman via `-e VAR` so they reach install.sh inside the container.
sudo \
  CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-}" ROLODEX_IMAGE="${ROLODEX_IMAGE:-}" \
  UI_IMAGE="${UI_IMAGE:-}" LOCAL_DNS="${LOCAL_DNS:-}" \
  TTYFORCE_DEV="${TTYFORCE_DEV:-}" TTYFORCE_LATEST="${TTYFORCE_LATEST:-}" \
  IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-}" \
  podman run --rm --privileged --cgroupns=host --arch amd64 \
  -v "$REPO_ROOT":/build -w /build \
  -e CONTROLLER_IMAGE -e ROLODEX_IMAGE -e UI_IMAGE -e LOCAL_DNS \
  -e TTYFORCE_DEV -e TTYFORCE_LATEST -e IMAGE_HOSTNAME \
  town-os-builder /build/make/install.sh "$IMAGE_SIZE" "$IMAGE"

# The image is created root-owned (consistent with today's sudo native build).
# Hand it back to the invoking user when run under sudo.
if [ -n "${SUDO_USER:-}" ] && [ -e "$REPO_ROOT/$IMAGE" ]; then
  sudo chown "$SUDO_USER" "$REPO_ROOT/$IMAGE" 2>/dev/null || true
fi
