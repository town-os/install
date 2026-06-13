#!/usr/bin/env bash
# Build a Town OS disk image inside a SAME-ARCHITECTURE Arch Linux container.
#
# Used on non-Arch hosts, where pacstrap/arch-chroot/mkinitcpio don't exist. The
# container is the host's native architecture (aarch64 Arch on aarch64, x86_64
# Arch on x86_64) — it runs at native CPU speed, with NO emulation and NO binfmt.
# It exists only to supply Arch's build tooling; the produced image is the host's
# architecture. The unmodified make/install.sh runs inside the builder container
# (see Containerfile.build); the finished image is written back to the repo on the
# host.
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image-container.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image-container.sh IMAGE_SIZE IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pick a same-architecture Arch base image. We never pass --arch, so podman uses
# the host's native architecture for both build and run. The base image may be
# overridden via the BASE_IMAGE environment variable
# (e.g. `BASE_IMAGE=docker.io/lopsided/archlinux make image`), which is useful
# when the default aarch64 Arch Linux ARM image isn't desired.
if [ -z "${BASE_IMAGE:-}" ]; then
  case "$(uname -m)" in
    x86_64)  BASE_IMAGE="docker.io/library/archlinux:latest" ;;
    aarch64) BASE_IMAGE="docker.io/menci/archlinuxarm:latest" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi
echo "Using builder base image: ${BASE_IMAGE}"

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
sudo podman build --network=host --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "BUILD_MIRROR=${BUILD_MIRROR:-}" -t town-os-builder \
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
  podman run --rm --privileged --cgroupns=host --network=host "${TTY_ARG[@]}" \
  -v /dev:/dev \
  -v "$REPO_ROOT":/build -w /build \
  -e CONTROLLER_IMAGE -e ROLODEX_IMAGE -e UI_IMAGE -e LOCAL_DNS \
  -e TTYFORCE_DEV -e TTYFORCE_LATEST -e IMAGE_HOSTNAME -e SERIAL_CONSOLE \
  town-os-builder /build/make/install.sh "$IMAGE_SIZE" "$IMAGE"

# The image is created root-owned (consistent with today's sudo native build).
# Hand it back to the invoking user when run under sudo.
if [ -n "${SUDO_USER:-}" ] && [ -e "$REPO_ROOT/$IMAGE" ]; then
  sudo chown "$SUDO_USER" "$REPO_ROOT/$IMAGE" 2>/dev/null || true
fi
