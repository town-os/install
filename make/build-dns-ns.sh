#!/usr/bin/env bash
# Run a command with an ISOLATED /etc/resolv.conf, in a private mount namespace.
#
#   build-dns-ns.sh "<servers>" command [args...]
#
# WHY: the native (Arch host) image build runs pacstrap, pacman and curl directly
# on the host, so it resolves through the host's /etc/resolv.conf — and this repo
# rewrites that file. Every `make qemu*` target points the host's resolver at the
# dev VM (make/host-dns.sh, VM_DNS) so the workstation resolves through rolodex
# like a real client; that is the qemu targets' job and it stays. But a host that
# has launched the dev VM then hands a NAT'd guest — possibly down, mid-boot, or
# unprovisioned — to an hours-long build, where it surfaces as an unreachable
# package mirror rather than as a DNS problem.
#
# The container build path solves this with `podman --dns`. The native path has
# no such switch (glibc has no per-process resolver), so it gets the equivalent
# with the kernel primitive that does exist: a private mount namespace with our
# own resolv.conf bind-mounted over the host's. The host's real file is NEVER
# modified — the bind exists only inside the namespace and dies with it, so this
# keeps the repo's "builds have no host side effects" rule intact.
#
# Everything the build spawns inherits the namespace, chroots included: pacstrap
# copies the visible resolv.conf into the image, so the in-chroot builds
# (scripts/build-kernel-rg35xx.sh, build-uboot-rg35xx.sh and their curl fetches)
# resolve through the same explicit servers.
#
# Must run as root (it is: image.sh invokes it under the same sudo that runs
# install.sh). An empty server list, a missing unshare, or a failed bind all fall
# back to running the command unchanged — this never blocks a build.
set -euo pipefail

SERVERS="${1:?Usage: build-dns-ns.sh \"<servers>\" command [args...]}"
shift
[ $# -gt 0 ] || { echo "build-dns-ns.sh: no command given" >&2; exit 2; }

if [ -z "${SERVERS// /}" ]; then
  echo "build-dns-ns.sh: no upstream DNS given; using the host's resolver." >&2
  exec "$@"
fi

if ! command -v unshare >/dev/null 2>&1; then
  echo "build-dns-ns.sh: unshare not found (install util-linux); using the host's resolver." >&2
  exec "$@"
fi

# Runtime-only, like every other bit of state this repo writes on the host:
# /run evaporates on reboot, so a build can never leave a resolver behind.
RESOLV="${BUILD_RESOLV_FILE:-/run/town-os-build-resolv.conf}"
if ! { : > "$RESOLV"; } 2>/dev/null; then
  echo "build-dns-ns.sh: cannot write ${RESOLV}; using the host's resolver." >&2
  exec "$@"
fi
for s in $SERVERS; do printf 'nameserver %s\n' "$s" >> "$RESOLV"; done
chmod 0644 "$RESOLV"

# --propagation private: mounts made inside stay inside. The bind target is the
# RESOLVED path — /etc/resolv.conf is a symlink to systemd-resolved's stub on
# these hosts, and bind-mounting a symlink binds over its target anyway; naming
# it explicitly keeps that behaviour obvious rather than incidental.
exec unshare --mount --propagation private -- \
  /usr/bin/env bash -c '
    resolv="$1"; shift
    target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
    [ -n "$target" ] || target=/etc/resolv.conf
    if ! mount --bind "$resolv" "$target" 2>/dev/null; then
      echo "build-dns-ns.sh: could not bind $target; using the host'"'"'s resolver." >&2
    fi
    exec "$@"
  ' _ "$RESOLV" "$@"
