#!/usr/bin/env bash
# Build an aarch64 Town OS image on ANY host (typically x86_64) by running the
# UNMODIFIED make/install.sh inside a full-system qemu-system-aarch64 VM.
#
# This is emulation of a WHOLE MACHINE (qemu-system, TCG), NOT binfmt/qemu-user
# and NOT cross-compilation: install.sh runs as native aarch64 code inside the
# emulated aarch64 machine, so the "image arch == build-host arch" invariant
# still holds — the build host is simply a virtual aarch64 box. binfmt_misc is
# never touched. The model is: import a cached aarch64 "build environment" disk
# into QEMU, run the build, export the finished image back to the repo.
#
# Consolidation: this is the single mechanism for producing a NON-native arch
# image. Native same-arch builds keep their fast path (make/image.sh -> native
# or same-arch container); there is no reason to emulate when native works.
#
# UNVERIFIED: like the RPI=1 path, this is correct-by-construction but has not
# been booted here. The fragile part (a hand-assembled virtio initramfs + the
# exact module set) is isolated below and commented for easy iteration.
set -euo pipefail

IMAGE_SIZE="${1:?Usage: image-aarch64.sh IMAGE_SIZE IMAGE}"
IMAGE="${2:?Usage: image-aarch64.sh IMAGE_SIZE IMAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QEMU_BIN="qemu-system-aarch64"

# The aarch64 build environment is the same Arch Linux ARM base image the native
# container build uses on aarch64 hosts. Override with BASE_IMAGE.
BASE_IMAGE="${BASE_IMAGE:-docker.io/menci/archlinuxarm:latest}"

# US mirror prepended to the build-env's pacman mirrorlist (same rationale and
# default as make/Containerfile.build: the stock ALARM list is EU-first).
BUILD_MIRROR="${BUILD_MIRROR:-http://ca.us.mirror.archlinuxarm.org/\$arch/\$repo}"

# Cached build environment lives outside the tree (git-ignored). Deleting this
# directory forces a full re-provision on the next build.
BUILD_ENV="${BUILD_ENV_DIR:-$REPO_ROOT/.build-env}"
BUILDER_DISK="$BUILD_ENV/aarch64-builder.ext4"   # persistent build-env rootfs
KERNEL_IMG="$BUILD_ENV/aarch64-Image"            # extracted linux-aarch64 kernel
INITRD_IMG="$BUILD_ENV/aarch64-initramfs.img"    # hand-assembled virtio initramfs
PARAMS_ENV="$BUILD_ENV/guest-params.env"         # build params handed to the guest
STATUS_FILE="$BUILD_ENV/guest-status"            # BUILD_OK / BUILD_FAIL from the guest

# Builder rootfs is sparse; must hold the toolchain + pacman cache + a full
# transient copy of the output image. 32G virtual, sparse — real usage is far
# less. install.sh writes the image to the builder's local ext4 (NOT over 9p,
# which cannot reliably back a loop device), then the guest copies it out.
BUILDER_VDISK_SIZE="${BUILDER_VDISK_SIZE:-32G}"

# Generous RAM: the guest compiles ttyforce (rustc/LLVM linking spikes memory),
# and heavy memory pressure has been observed to make 9p reads flaky. Override
# with VM_MEMORY=.
VM_MEMORY="${VM_MEMORY:-8G}"
# vCPUs for the build VM. The dominant cost is the rustc/cargo compile of
# ttyforce, which parallelizes across cores, so give the guest a good share of
# the host (half its CPUs, min 4). Multi-threaded TCG (below) makes these vCPUs
# actually run concurrently. Override with VM_CPUS=.
_host_cpus="$(nproc 2>/dev/null || echo 4)"
VM_CPUS="${VM_CPUS:-$(( _host_cpus / 2 > 4 ? _host_cpus / 2 : 4 ))}"

# ALARM package repo the kernel is pulled from (download + extract only — no
# aarch64 code runs on the host).
ALARM_CORE="${ALARM_CORE:-http://mirror.archlinuxarm.org/aarch64/core}"
# Alpine static (musl) busybox for the initramfs /init — a fully static aarch64
# binary we can drop into a from-scratch initramfs with no libc.
ALPINE_MAIN="${ALPINE_MAIN:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64}"

log() { printf '\n\033[1;34m[image-aarch64]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[image-aarch64] error:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$QEMU_BIN" >/dev/null 2>&1 || die "$QEMU_BIN not found.
  Arch:          sudo pacman -S qemu-full    (or 'make deps')
  Fedora:        sudo dnf install qemu-system-aarch64
  Debian/Ubuntu: sudo apt install qemu-system-arm"
command -v podman >/dev/null 2>&1 || die "podman not found (needed to import the aarch64 base image)."
command -v curl   >/dev/null 2>&1 || die "curl not found (needed to fetch the aarch64 kernel + busybox)."
command -v depmod >/dev/null 2>&1 || die "depmod not found (install kmod — part of 'make deps')."

if [ "$(uname -m)" = "aarch64" ]; then
  log "NOTE: host is already aarch64 — 'make image' builds natively and much faster."
  log "      Continuing with the emulated path only because you asked for image-aarch64."
fi

mkdir -p "$BUILD_ENV"
rm -f "$STATUS_FILE"

# ===========================================================================
# 1. Build the cached build environment (rootfs disk + kernel + initramfs).
# ===========================================================================
# Everything here is host-side file assembly. `podman pull/create/export` only
# DOWNLOAD and unpack an aarch64 filesystem, and the kernel package is untarred,
# never executed — so NO aarch64 instruction runs on the host and binfmt is
# never involved. The disk, kernel, and initramfs are produced together from one
# kernel-package extraction so the running kernel's modules are guaranteed to be
# present (and depmod'd) inside the rootfs.
if [ ! -f "$BUILDER_DISK" ] || [ ! -f "$KERNEL_IMG" ] || [ ! -f "$INITRD_IMG" ]; then
  log "Creating aarch64 build environment (one-time): $BUILD_ENV"
  WORK="$(mktemp -d "$BUILD_ENV/work.XXXXXX")"
  ROOTFS_DIR="$WORK/rootfs"; PKGDIR="$WORK/pkg"; IRD="$WORK/initramfs"
  mkdir -p "$ROOTFS_DIR" "$PKGDIR" "$IRD"
  trap 'sudo rm -rf "$WORK" 2>/dev/null || true' EXIT

  # --- 1a. Import the aarch64 base rootfs (download + unpack only). ----------
  log "Pulling aarch64 base image: $BASE_IMAGE"
  sudo podman pull --arch arm64 "$BASE_IMAGE"
  cid="$(sudo podman create --arch arm64 "$BASE_IMAGE" /bin/true)"
  log "Exporting base rootfs (no aarch64 execution)"
  sudo podman export "$cid" | sudo tar -xp -C "$ROOTFS_DIR" -f -
  sudo podman rm "$cid" >/dev/null

  # Prepend the US mirror (EU-first stock list kept as fallback) + parallel
  # downloads — same treatment as Containerfile.build.
  sudo sh -c "printf 'Server = %s\n' '$BUILD_MIRROR' > '$ROOTFS_DIR/etc/pacman.d/mirrorlist.town'
    cat '$ROOTFS_DIR/etc/pacman.d/mirrorlist' >> '$ROOTFS_DIR/etc/pacman.d/mirrorlist.town'
    mv '$ROOTFS_DIR/etc/pacman.d/mirrorlist.town' '$ROOTFS_DIR/etc/pacman.d/mirrorlist'
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' '$ROOTFS_DIR/etc/pacman.conf' || true"

  # Nested podman (install.sh's town-build step) must use vfs + cgroupfs inside
  # this VM, exactly like the container builder. Drop-in, not an append, to
  # avoid a duplicate [engine] table (see Containerfile.build).
  sudo sh -c "mkdir -p '$ROOTFS_DIR/etc/containers/containers.conf.d'
    printf '[storage]\ndriver = \"vfs\"\n' > '$ROOTFS_DIR/etc/containers/storage.conf'
    printf '[engine]\ncgroup_manager = \"cgroupfs\"\n' > '$ROOTFS_DIR/etc/containers/containers.conf.d/00-town-build.conf'"

  # Minimal PID1 bootstrap baked into the rootfs. It sets PATH (PID1 gets no
  # environment), mounts the pseudo-filesystems, brings up SLIRP networking + the
  # 9p repo share, then hands off to the REPO-TRACKED build script — so the real
  # build logic (make/image-aarch64-guest.sh) stays editable without recreating
  # this disk. town-init itself rarely changes.
  sudo tee "$ROOTFS_DIR/sbin/town-init" >/dev/null <<'TOWN_INIT'
#!/bin/sh
# PID1 inside the aarch64 build VM (exec'd by the initramfs via switch_root).
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc     proc /proc          2>/dev/null || true
mount -t sysfs    sys  /sys           2>/dev/null || true
mount -t devtmpfs dev  /dev           2>/dev/null || true
mkdir -p /dev/pts /sys/fs/cgroup      2>/dev/null || true
mount -t devpts   pts  /dev/pts       2>/dev/null || true
mount -t tmpfs    tmp  /tmp           2>/dev/null || true
mount -t tmpfs    run  /run           2>/dev/null || true
mount -t cgroup2  cg   /sys/fs/cgroup 2>/dev/null || true

# QEMU user-mode (SLIRP) networking uses a FIXED addressing plan, so configure
# statically — no DHCP client needed.
modprobe virtio_net 2>/dev/null || true
IFACE="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" { print $2; exit }')"
if [ -n "$IFACE" ]; then
  ip link set "$IFACE" up
  ip addr add 10.0.2.15/24 dev "$IFACE" 2>/dev/null || true
  ip route add default via 10.0.2.2 2>/dev/null || true
fi
printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf

# Mount the repo (shared read-write via virtio-9p, tag "repo").
modprobe 9pnet_virtio 2>/dev/null || true
modprobe 9p 2>/dev/null || true
mkdir -p /mnt/repo
mount -t 9p -o trans=virtio,version=9p2000.L,msize=524288 repo /mnt/repo 2>/dev/null \
  || echo "town-init: FAILED to mount 9p repo share" > /dev/console

if [ -r /mnt/repo/make/image-aarch64-guest.sh ]; then
  # Run the guest script from tmpfs, NOT directly off the 9p share. PID1 reads
  # its script lazily, line by line; a 9p read hiccup late in a long build makes
  # the shell exit with "script file read error", which the kernel treats as init
  # dying ("Attempted to kill init!") and PANICS — instead of letting the script
  # reach its clean poweroff. A local tmpfs copy is immune (and tiny).
  if cp /mnt/repo/make/image-aarch64-guest.sh /run/guest.sh 2>/dev/null; then
    chmod +x /run/guest.sh
    exec /run/guest.sh
  fi
  exec /mnt/repo/make/image-aarch64-guest.sh
fi
echo "town-init: guest build script missing; dropping to a shell" > /dev/console
exec /bin/sh
TOWN_INIT
  sudo chmod +x "$ROOTFS_DIR/sbin/town-init"

  # --- 1b. Fetch the linux-aarch64 kernel package (download + untar only). ---
  log "Fetching linux-aarch64 kernel package from $ALARM_CORE"
  PKG="$(curl -fsSL "$ALARM_CORE/" \
    | grep -oE 'linux-aarch64-[0-9][^"]*\.pkg\.tar\.(xz|zst)' \
    | grep -vE 'headers' | sort -V | tail -1)"
  [ -n "$PKG" ] || die "could not find a linux-aarch64 package at $ALARM_CORE/"
  curl -fsSL "$ALARM_CORE/$PKG" -o "$WORK/linux.pkg"
  tar -xpf "$WORK/linux.pkg" -C "$PKGDIR"
  [ -f "$PKGDIR/boot/Image" ] || die "no /boot/Image in $PKG"
  KVER="$(ls "$PKGDIR/usr/lib/modules" | head -1)"
  [ -n "$KVER" ] || die "no modules directory in $PKG"
  MODROOT="$PKGDIR/usr/lib/modules/$KVER/kernel"
  cp "$PKGDIR/boot/Image" "$KERNEL_IMG"

  # Install the running kernel's modules INTO the rootfs and depmod them, so
  # modprobe (9p, virtio_net, loop, ...) works inside the VM. depmod is a host
  # tool but arch-agnostic when given an explicit basedir + kver; it resolves
  # <base>/lib/modules via the base rootfs's /lib -> usr/lib symlink.
  # The base image ships NO usr/lib/modules dir (no kernel), so create it first
  # and copy to an explicit $KVER target — otherwise `cp -a $KVER modules/`
  # would land the module *contents* at .../modules and depmod couldn't find it.
  log "Installing kernel modules ($KVER) into the build-env rootfs + depmod"
  sudo mkdir -p "$ROOTFS_DIR/usr/lib/modules"
  sudo cp -a "$PKGDIR/usr/lib/modules/$KVER" "$ROOTFS_DIR/usr/lib/modules/$KVER"
  sudo depmod -b "$ROOTFS_DIR" "$KVER"

  # --- 1c. Static busybox for the initramfs /init. ---------------------------
  log "Fetching static busybox from $ALPINE_MAIN"
  BBPKG="$(curl -fsSL "$ALPINE_MAIN/" \
    | grep -oE 'busybox-static-[0-9][^"]*\.apk' | sort -V | tail -1)"
  [ -n "$BBPKG" ] || die "could not find busybox-static at $ALPINE_MAIN/"
  curl -fsSL "$ALPINE_MAIN/$BBPKG" -o "$WORK/busybox.apk"
  mkdir -p "$WORK/bb"
  tar -xzf "$WORK/busybox.apk" -C "$WORK/bb" 2>/dev/null || true  # .apk = gzip tar
  BB="$(find "$WORK/bb" -type f -name 'busybox*' | head -1)"
  [ -n "$BB" ] || die "no busybox binary in $BBPKG"

  # --- 1d. Assemble the initramfs (just enough to reach the ext4 root). ------
  mkdir -p "$IRD"/{bin,proc,sys,dev,newroot,modules}
  cp "$BB" "$IRD/bin/busybox"; chmod +x "$IRD/bin/busybox"
  # Only the drivers to reach the ext4 root over virtio-blk-pci. Everything else
  # (net, 9p, loop, ...) is modprobed from the rootfs AFTER switch_root. On the
  # current linux-aarch64, virtio_blk/virtio_pci/ext4 are BUILTIN (=y), so these
  # copies find little and the init's insmod loop no-ops — harmless. They're
  # listed so the path still works if a future kernel modularizes any of them
  # (virtio_blk lives in drivers/block, not drivers/virtio).
  for sub in drivers/virtio drivers/block/virtio_blk.ko fs/ext4 fs/jbd2 fs/mbcache.ko lib/crc16.ko crypto/crc32c_generic.ko; do
    find "$MODROOT/$sub" -name '*.ko*' 2>/dev/null -exec cp {} "$IRD/modules/" \; || true
  done
  cat > "$IRD/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin
mount -t proc     proc /proc
mount -t sysfs    sys  /sys
mount -t devtmpfs dev  /dev
# Insmod the bundled virtio + ext4 modules; three passes resolve load order
# without a modules.dep. Already-loaded / built-in failures are ignored.
for pass in 1 2 3; do
  for m in virtio virtio_ring virtio_pci virtio_mmio virtio_blk \
           crc16 crc32c_generic mbcache jbd2 ext4; do
    for f in /modules/${m}.ko*; do [ -e "$f" ] && insmod "$f" 2>/dev/null; done
  done
done
for i in $(seq 1 100); do [ -b /dev/vda ] && break; sleep 0.1; done
mount -t ext4 /dev/vda /newroot || { echo "initramfs: cannot mount /dev/vda"; exec sh; }
exec switch_root /newroot /sbin/town-init
INIT
  chmod +x "$IRD/init"
  ( cd "$IRD" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$INITRD_IMG"

  # --- 1e. Bake the rootfs into an ext4 disk (mkfs -d; no loop mount). -------
  log "Building ext4 build-env disk from the rootfs"
  rm -f "$BUILDER_DISK"
  truncate -s "$BUILDER_VDISK_SIZE" "$BUILDER_DISK"
  sudo mkfs.ext4 -q -F -d "$ROOTFS_DIR" "$BUILDER_DISK"
  sudo chown "$(id -u):$(id -g)" "$BUILDER_DISK" 2>/dev/null || true

  sudo rm -rf "$WORK"; trap - EXIT
  log "Build environment ready (kernel $KVER). Toolchain provisions on first boot."
fi

# ===========================================================================
# 2. Hand build parameters to the guest and boot the VM.
# ===========================================================================
cat > "$PARAMS_ENV" <<EOF
IMAGE_SIZE='${IMAGE_SIZE}'
IMAGE='${IMAGE}'
RPI='${RPI:-}'
CONTROLLER_IMAGE='${CONTROLLER_IMAGE:-}'
ROLODEX_IMAGE='${ROLODEX_IMAGE:-}'
UI_IMAGE='${UI_IMAGE:-}'
LOCAL_DNS='${LOCAL_DNS:-}'
TTYFORCE_DEV='${TTYFORCE_DEV:-}'
TTYFORCE_LATEST='${TTYFORCE_LATEST:-}'
IMAGE_HOSTNAME='${IMAGE_HOSTNAME:-}'
SERIAL_CONSOLE='${SERIAL_CONSOLE:-}'
EOF

log "Booting aarch64 build VM (TCG — slow; grab a coffee). RPI='${RPI:-}' vCPUs=${VM_CPUS} mem=${VM_MEMORY}"
# -cpu max under TCG; no KVM (foreign architecture on this host). virtio-rng
# feeds guest entropy so pacman-key/gnupg don't stall. The repo is shared
# read-write over virtio-9p (tag "repo", security_model=none -> guest root maps
# to the invoking user, so the exported image ends up user-owned). User-mode
# networking gives outbound access for pacstrap + image pulls with no bridge.
#
# accel=tcg,thread=multi: MULTI-THREADED TCG — each guest vCPU is emulated on its
# own host thread, so -smp actually scales (single-threaded TCG round-robins all
# vCPUs on one host thread, and extra -smp buys almost nothing). Safe here: an
# aarch64 (weak-ordering) guest on an x86_64 (TSO, stronger) host needs no extra
# barriers. tb-size grows the translation-block cache (MiB) to cut re-translation
# churn during the big rustc/pacstrap workloads.
#
# Ctrl-C must abort the build. Discard the (now half-written) build-env on
# INT/TERM — same cache-hygiene rule as a failed build — then propagate. The
# stdio serial below uses signal=on so Ctrl-C actually reaches us as SIGINT
# instead of being swallowed by the guest (which is what -nographic does).
on_interrupt() {
  trap - INT TERM
  log "Interrupted — discarding cached build-env so the next run starts clean."
  sudo -n rm -rf "$BUILD_ENV" 2>/dev/null || rm -rf "$BUILD_ENV" 2>/dev/null || true
  exit 130
}
trap on_interrupt INT TERM

# -display none + a stdio serial chardev with signal=on: the guest console
# (ttyAMA0) is on our stdio AND Ctrl-C is delivered to QEMU as SIGINT (QEMU then
# exits), so the build is interruptible. -nographic would instead route Ctrl-C
# into the guest (signal=off), leaving Ctrl-A X as the only way out.
"$QEMU_BIN" \
  -machine virt \
  -accel tcg,thread=multi,tb-size=512 \
  -cpu max \
  -m "$VM_MEMORY" \
  -smp "$VM_CPUS" \
  -kernel "$KERNEL_IMG" \
  -initrd "$INITRD_IMG" \
  -append "root=/dev/vda rw rootfstype=ext4 console=ttyAMA0 panic=1" \
  -drive "file=$BUILDER_DISK,if=none,id=root,format=raw,cache=writeback" \
  -device virtio-blk-pci,drive=root \
  -device virtio-rng-pci \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -fsdev "local,id=repo,path=$REPO_ROOT,security_model=none" \
  -device virtio-9p-pci,fsdev=repo,mount_tag=repo \
  -display none \
  -chardev stdio,id=serial0,signal=on \
  -serial chardev:serial0 \
  -no-reboot

trap - INT TERM

# ===========================================================================
# 3. Report result. The image was exported to the repo by the guest.
# ===========================================================================
STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo BUILD_UNKNOWN)"
if [ "$STATUS" = "BUILD_OK" ] && [ -e "$REPO_ROOT/$IMAGE" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    sudo chown "$SUDO_USER" "$REPO_ROOT/$IMAGE" 2>/dev/null || true
  fi
  log "Done: $IMAGE (aarch64, built under emulation)."
else
  # NEVER preserve the cached build-env across a failure. A failed build leaves
  # the builder disk dirty: the guest is force-powered-off with the ext4 root
  # still mounted rw (cache=writeback), so its pacman DBs and gnupg keyring can
  # be left half-written. Reusing that disk makes the NEXT build fail at
  # `pacman -Sy` with "GPGME error: No data / invalid or corrupted database (PGP
  # signature)" even though the keyring provisioned fine originally. Discard the
  # whole cache so the next run rebuilds and re-provisions from a clean rootfs.
  log "Build failed — discarding cached build-env so the next run starts clean: $BUILD_ENV"
  sudo rm -rf "$BUILD_ENV" 2>/dev/null || rm -rf "$BUILD_ENV"
  die "aarch64 build did not complete (status: $STATUS).
  The build runs over the serial console above — scroll up for the failure.
  The cached build-env was discarded; the next 'make image-aarch64' re-provisions from scratch."
fi
