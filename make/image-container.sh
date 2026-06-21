#!/usr/bin/env bash
# Build a Town OS disk image inside an Arch Linux container.
#
# Used on non-Arch hosts, where pacstrap/arch-chroot/mkinitcpio don't exist, and
# for cross-architecture builds. By DEFAULT the container is the host's native
# architecture (aarch64 Arch on aarch64, x86_64 Arch on x86_64) — native CPU
# speed, NO emulation, NO binfmt — and produces a host-arch image. Set
# TARGET_ARCH to a different arch (e.g. TARGET_ARCH=x86_64 on aarch64) to
# cross-build under qemu-user-static EMULATION instead; see the binfmt block.
# The unmodified make/install.sh runs inside the builder container (see
# Containerfile.build); the finished image is written back to the repo on the host.
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image-container.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image-container.sh IMAGE_SIZE IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Target architecture for the produced image. Defaults to the host arch (native,
# no-emulation path). Set TARGET_ARCH to a DIFFERENT arch to cross-build under
# emulation. Threaded from the Makefile (BUILD_ARCH) via image.sh.
HOST_ARCH="$(uname -m)"
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"

# Pick the Arch base image and podman arch for the TARGET arch. Override the base
# via BASE_IMAGE (e.g. `BASE_IMAGE=docker.io/lopsided/archlinux make image`).
case "$TARGET_ARCH" in
  x86_64)  PODMAN_ARCH="amd64"; DEFAULT_BASE="docker.io/library/archlinux:latest" ;;
  aarch64) PODMAN_ARCH="arm64"; DEFAULT_BASE="docker.io/menci/archlinuxarm:latest" ;;
  *) echo "Unsupported TARGET_ARCH: ${TARGET_ARCH}" >&2; exit 1 ;;
esac
: "${BASE_IMAGE:=$DEFAULT_BASE}"

# Per-arch builder tag so a cross (emulated) builder never clobbers the native one.
BUILDER_IMAGE="town-os-builder-${TARGET_ARCH}"

# Native (TARGET_ARCH == host): no platform flags, no emulation. Cross-build
# (TARGET_ARCH != host): register qemu-user-static binfmt handlers with the F
# ("fix-binary") flag so the emulator works inside containers without qemu in the
# image, and pass --arch to build+run so podman pulls/runs the foreign image. This
# is the ONLY place the build touches host binfmt, and only on explicit opt-in.
# SLOW: pacstrap and the Rust ttyforce build run emulated.
PLATFORM_ARGS=()
if [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
  echo "CROSS-BUILD: ${TARGET_ARCH} image on ${HOST_ARCH} host — EMULATED (qemu-user-static). This is slow."
  BINFMT_IMAGE="${BINFMT_IMAGE:-docker.io/multiarch/qemu-user-static:latest}"
  sudo podman run --rm --privileged "${BINFMT_IMAGE}" --reset -p yes
  PLATFORM_ARGS=(--arch "${PODMAN_ARCH}")
fi
echo "Using builder base image: ${BASE_IMAGE} (target ${TARGET_ARCH})"

# Build the builder image natively (podman layer cache makes repeat runs cheap).
#
# --network=host for BOTH the build and the run below: the build needs working
# DNS, and podman's bridged (netavark) DNS uses plain UDP/53 from glibc, which
# some networks (e.g. guest WiFi) block while still allowing DNS over TCP. The
# host's systemd-resolved degrades to TCP automatically and keeps resolving;
# sharing the host network lets the container use that full resolver path. It
# also makes builds immune to netavark rule flushes (a known side effect of
# `firewall-cmd --reload`). Isolation buys nothing here — the run is already
# --privileged, and the nested town-build container uses --network=none.
sudo podman build --network=host "${PLATFORM_ARGS[@]}" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "BUILD_MIRROR=${BUILD_MIRROR:-}" -t "${BUILDER_IMAGE}" \
  -f "$SCRIPT_DIR/Containerfile.build" "$SCRIPT_DIR"

# Run the unmodified install.sh inside the container.
#   --privileged + --cgroupns=host: loopback (losetup --partscan), mount, and the
#     nested town-build systemd container all need real device access and cgroups.
#     (--privileged already grants the full capability set and all host devices,
#     so an explicit --cap-add=ALL would be redundant.)
#   -v /dev:/dev: share the host's devtmpfs so the partition nodes that
#     `losetup --partscan` creates (/dev/loopNp1..p3) are visible inside the
#     container. Without this, podman gives the container a private /dev and the
#     loop partition nodes never appear, so install.sh's wait for ${DEVICE}p3
#     times out and the subsequent mkfs on the partitions fails.
#   -v REPO_ROOT:/build -w /build: install.sh uses ./relative paths and writes
#     $IMAGE to the cwd, so the finished image lands in the repo dir on the host.
# Build vars are forwarded explicitly across the sudo boundary (never sudo -E),
# then handed to podman via `-e VAR` so they reach install.sh inside the container.
#
# Allocate a pseudo-TTY (-t) when stdout is a terminal so pacman/pacstrap show
# live per-package download and progress output inside the container — pacman
# suppresses that output when stdout is not a TTY, which is why an interactive
# `make image` otherwise sits silent during the long pacstrap download. Skip -t
# when stdout isn't a terminal (CI, pipes) to avoid carriage-return spam in logs.
TTY_ARG=()
[ -t 1 ] && TTY_ARG=(-t)
sudo \
  CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-}" ROLODEX_IMAGE="${ROLODEX_IMAGE:-}" \
  UI_IMAGE="${UI_IMAGE:-}" LOCAL_DNS="${LOCAL_DNS:-}" \
  TTYFORCE_DEV="${TTYFORCE_DEV:-}" TTYFORCE_LATEST="${TTYFORCE_LATEST:-}" \
  IMAGE_HOSTNAME="${IMAGE_HOSTNAME:-}" SERIAL_CONSOLE="${SERIAL_CONSOLE:-}" \
  podman run --rm --privileged --cgroupns=host --network=host "${PLATFORM_ARGS[@]}" "${TTY_ARG[@]}" \
  -v /dev:/dev \
  -v "$REPO_ROOT":/build -w /build \
  -e CONTROLLER_IMAGE -e ROLODEX_IMAGE -e UI_IMAGE -e LOCAL_DNS \
  -e TTYFORCE_DEV -e TTYFORCE_LATEST -e IMAGE_HOSTNAME -e SERIAL_CONSOLE \
  "${BUILDER_IMAGE}" /build/make/install.sh "$IMAGE_SIZE" "$IMAGE"

# The image is created root-owned (consistent with today's sudo native build).
# Hand it back to the invoking user when run under sudo.
if [ -n "${SUDO_USER:-}" ] && [ -e "$REPO_ROOT/$IMAGE" ]; then
  sudo chown "$SUDO_USER" "$REPO_ROOT/$IMAGE" 2>/dev/null || true
fi
