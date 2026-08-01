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

# --- A real controlling terminal and a working stdin for the build -----------
# The kernel hands PID1 fd 0/1/2 on /dev/console but gives it NO session and NO
# controlling terminal, so nothing below us could open /dev/tty, and to_console()
# makes stdout a pipe while nothing reconnected stdin. Between them, a build
# command that asked a question got no terminal, no visible prompt, and no way
# to receive an answer.
#
# The RG35XX target is where that bites, because it is the only one that runs
# real interactive-capable tooling deep inside the chroot — `patch` over the
# ROCKNIX kernel patch series and `pacman -S` for the in-chroot build deps.
# (`patch` prompting "File to patch:" into a >/dev/null was the confirmed hang;
# see scripts/build-kernel-rg35xx.sh. It is fixed at the source with --batch,
# but the console it exposed was broken for everything else too.)
#
# run_build() runs the command in its own session with the serial console as its
# CONTROLLING terminal, so /dev/tty resolves for anything that insists on one
# instead of erroring out. Output still goes through to_console, keeping the
# non-tty plain-line rendering the serial log depends on.
#
# Its stdin is that same tty, so typing into the QEMU stdio console on the host
# actually reaches whatever is running. That is worth having for debugging even
# though the build is meant to be unattended: everything known to ask a question
# is now handled at the source (`patch --batch` in
# scripts/build-{kernel,uboot}-rg35xx.sh; a keyring that already trusts the
# distro keys, via scripts/pacman-keyring.sh, so pacman never asks to import
# one), and a prompt appearing at all means something unforeseen — being able to
# answer it beats staring at a hang.
#
# Everything below inherits this — the terminal, its stdin, and the controlling
# terminal — through plain fd and session inheritance. No environment variable
# carries any of it, which is what makes it survive the `env -i` that
# make/install.sh uses for the chroot builds: a controlling terminal is a
# property of the process, not of its environment, so /dev/tty keeps resolving
# all the way down and gpg finds a terminal without being told where it is.
#
# Resolve the real tty device rather than using /dev/console: /dev/console is a
# redirector (5,1), and TIOCSCTTY wants the underlying terminal.
CTTY="$CONSOLE"
if [ -r /sys/class/tty/console/active ]; then
  for _t in $(cat /sys/class/tty/console/active 2>/dev/null); do
    if [ -c "/dev/$_t" ]; then CTTY="/dev/$_t"; break; fi
  done
fi

# Put the console into known-good line-discipline settings. Nothing else does:
# PID1 never touches termios, so the tty carries whatever the kernel left on it.
# The default IS effectively sane (ICANON|ECHO|ICRNL), but "effectively" is not
# something to rely on when the failure mode is a build that hangs on a question
# you cannot answer. ICRNL specifically is load-bearing: QEMU's stdio chardev
# clears ICRNL on the HOST terminal, so pressing Enter sends a bare CR down the
# wire and only the guest's ICRNL turns it into the newline that terminates a
# canonical read. Without it, a typed answer sits in the line buffer forever.
stty sane < "$CTTY" 2>/dev/null || true

# Probe setsid --ctty for real (it hard-fails if TIOCSCTTY is refused) so a
# kernel/tty combination that won't hand over a controlling terminal degrades to
# "stdin is at least the tty" instead of failing every build command.
SETSID=""
if command -v setsid >/dev/null 2>&1 && setsid -c -w true < "$CTTY" >/dev/null 2>&1; then
  SETSID=setsid
fi

# Usage:  run_build some_command args...
# The tty on fd 0 is both what setsid --ctty hands over (TIOCSCTTY reads fd 0)
# and what the command inherits as its stdin — one redirect, no indirection.
run_build() {
  if [ -n "$SETSID" ]; then
    "$SETSID" -c -w "$@" < "$CTTY" 2>&1 | to_console
  else
    "$@" < "$CTTY" 2>&1 | to_console
  fi
}

# Push the patched-kernel cache onto the 9p share, i.e. into the host's repo dir.
#
# The H700 kernel is by far the most expensive thing this VM does — hours under
# TCG — and make/install.sh already caches it as a content-keyed tarball under
# .kernel-cache/. But install.sh runs against /root/build, the LOCAL copy of the
# repo on the build-env disk, so the tarball it writes lives on a disk the host
# may delete after the run. Anything failing AFTER the kernel (configure.sh,
# U-Boot, squashfs) therefore threw the kernel away with it and the retry
# rebuilt it from scratch.
#
# So export it on EVERY exit path, success or failure: .kernel-cache in the repo
# dir outlives the build-env entirely, and the next run's rsync stages it back
# in, where install.sh finds it by key and skips the build. Entries are
# content-keyed, so one already on the host is already correct — --ignore-existing
# keeps this from re-copying hundreds of MB over 9p every time.
export_kernel_cache() {
  [ -d /root/build/.kernel-cache ] || return 0
  [ -n "$(ls -A /root/build/.kernel-cache 2>/dev/null)" ] || return 0
  mkdir -p /mnt/repo/.kernel-cache 2>/dev/null || return 0
  say "Exporting .kernel-cache to the host (outlives a discarded build-env)"
  rsync -a --ignore-existing /root/build/.kernel-cache/ /mnt/repo/.kernel-cache/ \
    > "$CONSOLE" 2>&1 || say "WARNING: could not export .kernel-cache — the next build recompiles the kernel"
}

finish() {
  status="$1"
  mkdir -p /mnt/repo/.build-env 2>/dev/null || true
  printf '%s\n' "$status" > /mnt/repo/.build-env/guest-status 2>/dev/null || true
  # Everything that has to reach the HOST goes over 9p here, while the share is
  # still mounted — the status above, and the kernel cache (see above: it is what
  # makes a failure after the kernel cost minutes rather than hours).
  export_kernel_cache
  # Report status over the 9p share FIRST, then bring the ext4 build-env disk to
  # a consistent on-disk state before the forced poweroff. Without this the disk
  # is powered off mounted rw (cache=writeback), leaving pacman/gnupg files
  # half-written so the cached disk fails the NEXT build at `pacman -Sy`. This
  # is exactly why make/image-aarch64.sh KEEPS the build-env whenever a status
  # was reported and discards it only when none was: reaching this point at all
  # is what makes the disk reusable, whether the build passed or failed.
  # sysrq 's' = emergency sync, 'u' =
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

# --- 0. Minimal /dev, before anything that needs it. ---------------------------
# This VM runs a bare shell as PID1 with NO udev, so a fresh devtmpfs has none of
# the /dev entries a normal Arch host gets from udev/systemd. devtmpfs is a
# SINGLE shared kernel instance, so creating them here also makes them appear in
# the chroot's /dev later (pacstrap mirrors the same fs) — the reason one setup
# covers both the VM and the chroot.
#
# It runs FIRST, ahead of the keyring work below, because pacman-key is bash and
# leans on process substitution — key_is_lsigned() and key_is_revoked() both read
# from `< <(gpg ...)`, which is /dev/fd/NN. Without /dev/fd every one of those
# reads dies with "/dev/fd/63: No such file or directory", pacman-key silently
# mis-classifies each key it inspects (already-signed keys look unsigned, revoked
# keys look live), and the keyring it builds is not the keyring it reports.
#
#   /dev/shm  install.sh's pacstrap mounts a tmpfs on <root>/dev/shm and aborts
#             with "mount point /dev/shm does not exist" if the dir isn't there.
#   /dev/fd   mkinitcpio (run by install.sh in the chroot) hard-fails without it:
#             `[[ -e /dev/fd ]] || die "/dev must be mounted!"`. Plus the
#             pacman-key dependency above.
mkdir -p /dev/shm
mount -t tmpfs shm /dev/shm 2>/dev/null || true
ln -sfn /proc/self/fd   /dev/fd
ln -sfn /proc/self/fd/0 /dev/stdin
ln -sfn /proc/self/fd/1 /dev/stdout
ln -sfn /proc/self/fd/2 /dev/stderr

# --- 1. Ensure a healthy pacman keyring (every boot; cheap, self-heals). -------
# A cached build-env can carry a gnupg home that has a trustdb.gpg file but no
# usable keys — `podman export` of the base image ships exactly such a home — and
# then EVERY pacman db sync (including install.sh's own `pacman -Sy`) dies with
# "GPGME error: No data / invalid or corrupted database (PGP signature)". This
# lives OUTSIDE the /.town-provisioned gate so it also repairs an already-cached
# disk. virtio-rng feeds the guest so --init's master-key generation won't stall.
#
# The verdict comes from scripts/pacman-keyring.sh over the 9p share, the same
# checker make/install.sh runs inside the image chroot: every fingerprint the
# distro lists in /usr/share/pacman/keyrings/*-trusted must be present AND fully
# valid. Read its header for why the weaker "is anything trusted" question is not
# good enough and why `trust-model always` is a trap rather than a shortcut.
#
# A failed repair is FATAL, never `|| true`: a half-built keyring reaching
# install.sh is what produced BUILD_FAIL with a wall of "unknown trust" errors.
PACMAN_GPGDIR="$(pacman-conf gpgdir 2>/dev/null || true)"
[ -n "$PACMAN_GPGDIR" ] || PACMAN_GPGDIR=/etc/pacman.d/gnupg
# `archlinuxarm` is named as REQUIRED: this VM is always an Arch Linux ARM
# build-env, and its one builder key signs every package the build installs.
KEYRING_CHECK=/mnt/repo/scripts/pacman-keyring.sh

# Undo an earlier revision of this script, which appended gpg overrides
# (including that `trust-model always`) to the keyring config. The build-env disk
# outlives the run that wrote them, so a stale cached disk would keep failing
# every package as untrusted no matter how good its keyring is.
for f in "$PACMAN_GPGDIR/gpg.conf" "$PACMAN_GPGDIR/dirmngr.conf"; do
  if grep -q '^# town-os-batch$' "$f" 2>/dev/null; then
    say "Removing stale town-os gpg overrides from $f"
    sed -i '/^# town-os-batch$/,$d' "$f"
  fi
done

if ! sh "$KEYRING_CHECK" verify archlinuxarm > "$CONSOLE" 2>&1; then
  say "pacman keyring does not trust the distro signing keys — rebuilding it"
  rm -rf "$PACMAN_GPGDIR"
  run_build pacman-key --init || finish BUILD_FAIL
  run_build pacman-key --populate || finish BUILD_FAIL
  # Re-verify through run_build so the fingerprints it names reach the console.
  run_build sh "$KEYRING_CHECK" verify archlinuxarm || finish BUILD_FAIL
fi

# --- 2. Provision the toolchain once (cached on the build-env disk). -----------
# Same host-side tool set make/Containerfile.build installs; compilation (rust)
# happens later inside install.sh's pacstrapped chroot, so base-devel is enough.
if [ ! -f /.town-provisioned ]; then
  say "Provisioning aarch64 build toolchain (one-time; slow under TCG)"
  run_build pacman -Syu --noconfirm --needed \
      base-devel arch-install-scripts parted e2fsprogs dosfstools squashfs-tools \
      rsync psmisc lsof util-linux gptfdisk btrfs-progs mdadm \
      podman fuse-overlayfs crun \
      || finish BUILD_FAIL
  touch /.town-provisioned
fi

# --- 3. Copy the repo to local ext4 and run the build. ------------------------
# install.sh reads ./relative paths and writes $IMAGE to its cwd; it also
# loop-mounts that image. 9p cannot reliably back a loop device, so build on the
# local ext4 and export the result afterward. Exclude the host's images and the
# build-env cache from the copy.
#
# .kernel-cache is deliberately NOT excluded: this is the inbound half of the
# kernel cache (export_kernel_cache above is the outbound half), so a kernel
# built by an earlier run arrives here and install.sh reuses it by key instead of
# spending hours rebuilding it. The `P` (protect) filter is the belt to that
# brace: entries already on this disk are never deleted by --delete even if the
# host's copy is missing one, so a kernel survives here too when a preserved
# build-env is reused after a failure.
say "Staging repo -> /root/build"
mkdir -p /root/build
rsync -a --delete \
  --exclude '.git' --exclude '.build-env' --exclude '.claude' \
  --exclude '*.img' --exclude '*.img.*' --exclude '*.raw' \
  --filter 'P .kernel-cache/**' \
  /mnt/repo/ /root/build/ >/dev/console 2>&1 || finish BUILD_FAIL

cd /root/build || finish BUILD_FAIL

# install.sh loop-mounts the image (losetup) and may touch fs modules; ensure
# they're loaded (best-effort — some may be built into the kernel).
modprobe loop 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe btrfs 2>/dev/null || true

say "Running install.sh ${IMAGE_SIZE} ${IMAGE} (RPI='${RPI}' RG35XX='${RG35XX:-}')"
if run_build env \
     CONTROLLER_IMAGE="${CONTROLLER_IMAGE}" ROLODEX_IMAGE="${ROLODEX_IMAGE}" \
     UI_IMAGE="${UI_IMAGE}" LOCAL_DNS="${LOCAL_DNS}" \
     TTYFORCE_DEV="${TTYFORCE_DEV}" TTYFORCE_LATEST="${TTYFORCE_LATEST}" \
     IMAGE_HOSTNAME="${IMAGE_HOSTNAME}" SERIAL_CONSOLE="${SERIAL_CONSOLE}" \
     RPI="${RPI}" RG35XX="${RG35XX:-}" RG35XX_DTB="${RG35XX_DTB:-}" \
     UBOOT_BIN="${UBOOT_BIN:-}" \
     RG35XX_DRAM="${RG35XX_DRAM:-}" \
     ./make/install.sh "${IMAGE_SIZE}" "${IMAGE}"
then
  # --- 4. Export the finished image to the host over 9p. ----------------------
  if [ -e "/root/build/${IMAGE}" ]; then
    say "Exporting ${IMAGE} to the host"
    cp -f "/root/build/${IMAGE}" "/mnt/repo/${IMAGE}" >/dev/console 2>&1 \
      && finish BUILD_OK
  fi
fi
finish BUILD_FAIL
