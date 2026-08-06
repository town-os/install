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
export RPI="${RPI:-}"
# Anbernic RG35XX Pro (Allwinner H700) SD image: U-Boot in the raw sectors +
# extlinux instead of UEFI/GRUB. RG35XX_DTB picks the device tree, UBOOT_BIN
# supplies a prebuilt bootloader instead of building one (paths are resolved by
# install.sh with the repo as cwd, so keep them repo-relative or absolute).
export RG35XX="${RG35XX:-}"
export RG35XX_DTB="${RG35XX_DTB:-}"
export UBOOT_BIN="${UBOOT_BIN:-}"
export RG35XX_DRAM="${RG35XX_DRAM:-}"

# DNS for the build, resolved once here and used by whichever path runs below.
#
# Builds do NOT resolve through the host's configured resolver: `make qemu*`
# points it at the dev VM (make/host-dns.sh) so the workstation resolves through
# rolodex, and that guest must never end up as the resolver for an hours-long
# image build. make/upstream-dns.sh returns what the HOST got from the local
# network instead — DHCP values first, loopback and every local virtual-bridge
# subnet (the VM's included) filtered out. Set BUILD_DNS='1.1.1.1 9.9.9.9' to pin
# it, or BUILD_DNS=' ' to opt out and inherit the host's resolver.
export BUILD_DNS="${BUILD_DNS:-$("${SCRIPT_DIR}/upstream-dns.sh" --fallback 2>/dev/null || true)}"

# install.sh needs Arch-only tools (pacstrap, arch-chroot, genfstab, mkinitcpio).
# On Arch hosts, build natively. On any other host, build inside a same-arch Arch
# container (native CPU, no emulation/binfmt — see image-container.sh /
# Containerfile.build). Either way the image is the host's architecture.
ID=""
[ -f /etc/os-release ] && . /etc/os-release

case "${ID:-}" in
  arch|manjaro|endeavouros|garuda)
    if command -v pacstrap >/dev/null 2>&1; then
      # `if`, not `a && b`: under `set -e` a bare failing && chain exits the
      # script, which would silently skip the build when BUILD_DNS is opted out.
      if [ -n "${BUILD_DNS// /}" ]; then
        echo "Build DNS (isolated from the host's resolver): $(echo ${BUILD_DNS})"
      fi
      # install.sh runs through build-dns-ns.sh, which gives it a private mount
      # namespace whose /etc/resolv.conf is ours — the native equivalent of the
      # `podman --dns` the container path uses. It falls through to running
      # install.sh unchanged when there is nothing to isolate with.
      exec sudo CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" ROLODEX_IMAGE="${ROLODEX_IMAGE}" \
        UI_IMAGE="${UI_IMAGE}" LOCAL_DNS="${LOCAL_DNS}" TTYFORCE_DEV="${TTYFORCE_DEV}" \
        TTYFORCE_LATEST="${TTYFORCE_LATEST}" IMAGE_HOSTNAME="${IMAGE_HOSTNAME}" \
        SERIAL_CONSOLE="${SERIAL_CONSOLE}" RPI="${RPI}" \
        RG35XX="${RG35XX}" RG35XX_DTB="${RG35XX_DTB}" UBOOT_BIN="${UBOOT_BIN}" \
        RG35XX_DRAM="${RG35XX_DRAM}" \
        "${SCRIPT_DIR}/build-dns-ns.sh" "${BUILD_DNS}" \
        "${SCRIPT_DIR}/install.sh" "${IMAGE_SIZE}" "${IMAGE}"
    fi
    ;;
esac

exec "${SCRIPT_DIR}/image-container.sh" "${IMAGE_SIZE}" "${IMAGE}"
