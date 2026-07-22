#!/bin/sh
# Runs INSIDE the emulated aarch64 build VM as PID1 (exec'd by /sbin/town-init
# once /mnt/repo — the host repo, shared over virtio-9p — is mounted).
#
# Responsibilities:
#   1. Provision the aarch64 build toolchain into the cached build-env (once).
#   2. Run the UNMODIFIED make/install.sh to produce the aarch64 image.
#   3. Export the image to the host (copy onto the 9p share), record status,
#      and power the machine off.
#
# It lives in the repo (not baked into the build-env disk) so it can be iterated
# without recreating the cached disk. As PID1 it must NEVER return — every exit
# path goes through finish(), which powers off.
set -u

# /bin/sh is bash on Arch/ALARM; enable pipefail so a command that fails while
# piped through to_console() (below) still propagates its real exit status to the
# surrounding `if`/`||`, not cat's. Guarded no-op if the shell lacks pipefail.
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

# Inherited from /sbin/town-init, but PID1 environments are fragile — set it
# explicitly so bare command names resolve even if run standalone.
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

CONSOLE=/dev/console
say() { printf '\n[town-build] %s\n' "$*" > "$CONSOLE" 2>&1; }

# Pipe a build command's output through this so the captured serial log stays
# readable. Piping makes the command's stdout/stderr a NON-tty, which is the
# switch that turns pacman/pacstrap/mkfs/cargo OFF their interactive rendering:
# they then emit plain, newline-terminated lines instead of carriage-return +
# ANSI-cursor progress redraws (^M, ^[[4F, ^[[K, ^[[?25l ...) that paste as one
# unreadable blob. A real tty stays at /dev/console for anything that needs one.
# Usage:  some_command 2>&1 | to_console
to_console() { cat > "$CONSOLE"; }

finish() {
  status="$1"
  mkdir -p /mnt/repo/.build-env 2>/dev/null || true
  printf '%s\n' "$status" > /mnt/repo/.build-env/guest-status 2>/dev/null || true
  # Report status over the 9p share FIRST, then bring the ext4 build-env disk to
  # a consistent on-disk state before the forced poweroff. Without this the disk
  # is powered off mounted rw (cache=writeback), leaving pacman/gnupg files
  # half-written so the cached disk fails the NEXT build at `pacman -Sy`. The
  # host discards the cache on failure anyway, but a clean shutdown means a
  # SUCCESSFUL build's cache is reusable too. sysrq 's' = emergency sync, 'u' =
  # remount every filesystem read-only (works even with sub-mounts still busy,
  # which a plain `mount -o remount,ro /` cannot).
  sync
  umount /mnt/repo 2>/dev/null || true
  echo s > /proc/sysrq-trigger 2>/dev/null || true
  echo u > /proc/sysrq-trigger 2>/dev/null || true
  say "status=${status} — powering off"
  sleep 1
  # Prefer a clean poweroff; fall back to sysrq and a busy loop so PID1 never
  # returns (which would panic the kernel and hang the host's qemu).
  poweroff -f 2>/dev/null
  echo o > /proc/sysrq-trigger 2>/dev/null || true
  while :; do sleep 10; done
}

[ -f /mnt/repo/.build-env/guest-params.env ] || finish BUILD_FAIL
# shellcheck disable=SC1091
. /mnt/repo/.build-env/guest-params.env

# --- 1. Ensure a healthy pacman keyring (every boot; cheap, self-heals). -------
# A cached build-env can carry a gnupg home that has a trustdb.gpg file but NO
# imported keys — `podman export` of the base image ships exactly such a home —
# and then EVERY pacman db sync (including install.sh's own `pacman -Sy`) dies
# with "GPGME error: No data / invalid or corrupted database (PGP signature)".
# So: gate the slow, entropy-hungry --init on whether real keys are actually
# present (not merely on the trustdb file existing), and treat a failed
# --populate as FATAL instead of swallowing it with `|| true` — a half-built
# keyring silently reaching install.sh is exactly what caused BUILD_FAIL. This
# lives OUTSIDE the /.town-provisioned gate so it also repairs an already-cached
# disk. virtio-rng feeds the guest so --init's master-key generation won't stall.
if ! pacman-key --list-keys 2>/dev/null | grep -q '^pub'; then
  say "Initializing pacman keyring (empty/absent — regenerating)"
  rm -rf /etc/pacman.d/gnupg
  pacman-key --init >/dev/console 2>&1 || finish BUILD_FAIL
  pacman-key --populate archlinuxarm >/dev/console 2>&1 || finish BUILD_FAIL
fi

# --- 2. Provision the toolchain once (cached on the build-env disk). -----------
# Same host-side tool set make/Containerfile.build installs; compilation (rust)
# happens later inside install.sh's pacstrapped chroot, so base-devel is enough.
if [ ! -f /.town-provisioned ]; then
  say "Provisioning aarch64 build toolchain (one-time; slow under TCG)"
  pacman -Syu --noconfirm --needed \
      base-devel arch-install-scripts parted e2fsprogs dosfstools squashfs-tools \
      rsync psmisc lsof util-linux gptfdisk btrfs-progs mdadm \
      podman fuse-overlayfs crun \
      2>&1 | to_console || finish BUILD_FAIL
  touch /.town-provisioned
fi

# --- 3. Copy the repo to local ext4 and run the build. ------------------------
# install.sh reads ./relative paths and writes $IMAGE to its cwd; it also
# loop-mounts that image. 9p cannot reliably back a loop device, so build on the
# local ext4 and export the result afterward. Exclude the host's images and the
# build-env cache from the copy.
say "Staging repo -> /root/build"
mkdir -p /root/build
rsync -a --delete \
  --exclude '.git' --exclude '.build-env' --exclude '.claude' \
  --exclude '*.img' --exclude '*.img.*' --exclude '*.raw' \
  /mnt/repo/ /root/build/ >/dev/console 2>&1 || finish BUILD_FAIL

cd /root/build || finish BUILD_FAIL

# install.sh's pacstrap sets up the chroot's API mounts, including a tmpfs on
# <root>/dev/shm. devtmpfs is a SINGLE shared kernel instance, so pacstrap's
# fresh <root>/dev mirrors the VM's /dev — and town-init only created /dev/pts,
# never /dev/shm, so pacstrap aborts with "mount point /dev/shm does not exist".
# Create the dir (appears in pacstrap's chroot /dev via the shared devtmpfs) and
# give the build VM a real /dev/shm too.
mkdir -p /dev/shm
mount -t tmpfs shm /dev/shm 2>/dev/null || true

# mkinitcpio (run by install.sh inside the chroot) refuses to build unless
# /dev/fd exists: it does `[[ -e /dev/fd ]] || die "/dev must be mounted!"`. On a
# normal Arch host udev/systemd populate /dev/{fd,stdin,stdout,stderr}; this
# emulated VM runs a bare shell as PID1 with NO udev, so a fresh devtmpfs has
# none of them. devtmpfs is a single shared instance, so creating them here makes
# them appear in the chroot's /dev too (same fs) — the same trick as /dev/shm.
ln -sfn /proc/self/fd   /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr

# install.sh loop-mounts the image (losetup) and may touch fs modules; ensure
# they're loaded (best-effort — some may be built into the kernel).
modprobe loop 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe btrfs 2>/dev/null || true

say "Running install.sh ${IMAGE_SIZE} ${IMAGE} (RPI='${RPI}')"
if env \
     CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" ROLODEX_IMAGE="${ROLODEX_IMAGE}" \
     UI_IMAGE="${UI_IMAGE}" LOCAL_DNS="${LOCAL_DNS}" \
     TTYFORCE_DEV="${TTYFORCE_DEV}" TTYFORCE_LATEST="${TTYFORCE_LATEST}" \
     IMAGE_HOSTNAME="${IMAGE_HOSTNAME}" SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
     RPI="${RPI}" \
     ./make/install.sh "${IMAGE_SIZE}" "${IMAGE}" 2>&1 | to_console
then
  # --- 4. Export the finished image to the host over 9p. ----------------------
  if [ -e "/root/build/${IMAGE}" ]; then
    say "Exporting ${IMAGE} to the host"
    cp -f "/root/build/${IMAGE}" "/mnt/repo/${IMAGE}" >/dev/console 2>&1 \
      && finish BUILD_OK
  fi
fi
finish BUILD_FAIL
