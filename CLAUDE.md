# Town OS Install

Arch-based disk image builder for Town OS. Produces a bootable raw image with a read-only squashfs root, tmpfs overlay, and custom initrd hooks for hardware provisioning.

## Build & Run

```sh
make deps        # install host dependencies (Arch Linux)
make deps-debian # install host dependencies (Debian/Ubuntu)
make image       # build image (native on Arch, same-arch Arch container elsewhere)
make image-container # force the same-arch Arch container build path on any host
make             # build image and launch VM
make qemu-fg     # build and launch QEMU with serial console attached
make serial      # attach to running QEMU serial console (Ctrl-] to disconnect)
make stop        # stop all VMs
make flash        # build image if stale, write to USB
make clean        # remove current image and VM disks
make clean-images # remove all built images
```

Requires root for image building (make/install.sh uses loopback mounts, chroot, pacstrap).

### Arch Linux Setup

```sh
make deps
sudo make image
make qemu-fg
```

### Debian/Ubuntu Setup

Image building requires Arch-specific tools (`pacstrap`, `mkinitcpio`, `arch-chroot`) that have no Debian equivalent. Install host dependencies for VM launching:

```sh
make deps-debian
make image       # builds automatically inside a same-arch Arch container
make qemu-fg
```

On non-Arch hosts `make image` transparently runs the build inside a same-architecture Arch container (see [Container Image Builds](#container-image-builds)). The produced image is this host's architecture — there is no cross-build.

### Fedora Setup (incl. Asahi Remix)

`make deps` auto-detects Fedora (and RHEL/CentOS/Rocky/AlmaLinux) and installs host dependencies via `dnf`. Image building uses Arch-specific tools (`pacstrap`, `mkinitcpio`, `arch-chroot`), so on non-Arch hosts `make image` automatically builds inside a **same-architecture** Arch container — no manual container/transfer step, no emulation. On aarch64 hosts (e.g. Fedora Asahi Remix on Apple Silicon) the build runs as native aarch64 and produces an aarch64 image:

```sh
make deps
make image       # builds inside a same-arch (aarch64) Arch container, native speed
make qemu-fg
```

### Container Image Builds

`make/install.sh` needs Arch-only tools (`pacstrap`, `arch-chroot`, `genfstab`, `mkinitcpio`). On **non-Arch hosts**, `make/image.sh` detects the distro (via `/etc/os-release` `ID`) and dispatches to `make/image-container.sh`, which runs the **unmodified `install.sh`** inside a **same-architecture** Arch container built from `make/Containerfile.build`. The repo is bind-mounted at `/build`, so the finished image is written back to the repo dir on the host. `make image-container` forces this path on any host (including Arch).

- **Always native, never emulated:** the builder container is the host's native architecture (no `--arch`), so it runs at native CPU speed and the produced image's architecture equals the host's. The container exists only to supply Arch's build tooling on a non-Arch distro — it is **not** for cross-building. **The build never inspects, registers, or otherwise touches `binfmt_misc`, and never uses CPU emulation.** If you want a different-architecture image, run the build on a host of that architecture.
- **Base image by architecture:** `image-container.sh` picks the base via `uname -m` — `docker.io/library/archlinux` on x86_64, the third-party `docker.io/menci/archlinuxarm` on aarch64 (the official Arch image is x86_64-only). It is passed to `Containerfile.build` as the `BASE_IMAGE` build ARG. Override with the `BASE_IMAGE` **environment variable**, e.g. `BASE_IMAGE=docker.io/lopsided/archlinux make image` (it flows through `make` → `image.sh` → `image-container.sh` via the environment; no Makefile wiring needed).
- **Architecture in `install.sh`:** `install.sh` selects the kernel package (`linux618` on x86_64, `linux-aarch64` on aarch64), the GRUB target (`x86_64-efi`+`i386-pc` BIOS on x86_64, `arm64-efi` only on aarch64), and the `bios_grub` partition flag (x86_64 only) from `uname -m`. The 1 MiB BIOS-boot partition is still created on aarch64 (unused) to keep partition numbering identical. **zfs is x86_64-only** — there is no prebuilt `linux-aarch64-zfs` module package (aarch64 ZFS would need `zfs-dkms`), so `install.sh` errors if `storage_backend: zfs` on aarch64.
- **Privilege/devices:** the container runs rootful (`sudo podman run`) and `--privileged --cgroupns=host` because `install.sh` uses loopback (`losetup --partscan`), `mount`, and a nested `podman` systemd container (`town-build`). Rootless podman cannot create loop devices, so this must be rootful.
- **Nested podman:** the build-time `town-build` systemd container (used to enable units via `busctl`) becomes podman-in-podman. The builder image (`Containerfile.build`) sets podman to `vfs` storage + `cgroupfs` cgroup manager to keep that step reliable.
- Downstream targets (`qemu`, `qemu-fg`, `flash`, `run`) all funnel through the `$(IMAGE)` rule → `image.sh`, so they inherit the build path automatically.

### Host Dependencies

**Arch Linux** (`make deps`):
`base-devel` `arch-install-scripts` `parted` `e2fsprogs` `dosfstools` `rsync` `psmisc` `lsof` `squashfs-tools` `libvirt` `dnsmasq` `qemu-full` `socat` `lbzip2` `pv` `podman` `dbus`

**Fedora/RHEL** (`make deps`):
`gcc` `make` `parted` `e2fsprogs` `dosfstools` `rsync` `psmisc` `lsof` `squashfs-tools` `libvirt` `libvirt-client` `dnsmasq` `qemu-system-x86` `qemu-img` `socat` `lbzip2` `pv` `podman` `util-linux`

**Debian/Ubuntu** (`make deps-debian`):
`build-essential` `parted` `e2fsprogs` `dosfstools` `rsync` `psmisc` `lsof` `squashfs-tools` `libvirt-daemon-system` `libvirt-clients` `dnsmasq-base` `qemu-system-x86` `qemu-utils` `socat` `lbzip2` `pv` `podman` `dbus` `util-linux`

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_HOSTNAME` | `town-os` | System hostname and mDNS name |
| `LOCAL_DNS` | *(empty)* | Dev DNS override (`1` = auto, or literal hostname) |
| `CONTROLLER_BASE` | `quay.io/town/town` | Controller image repository (no tag) |
| `CONTROLLER_TAG` | `rc.latest` | Controller image tag; composed onto `CONTROLLER_BASE` |
| `CONTROLLER_IMAGE` | `$(CONTROLLER_BASE):$(CONTROLLER_TAG)` | Full controller image reference; set directly to override base+tag |
| `TTYFORCE_DEV` | *(empty)* | Set non-empty to install ttyforce from git instead of crates.io |
| `TTYFORCE_LATEST` | *(empty)* | Set non-empty to install the latest ttyforce from crates.io (ignores version pin) |
| `KEEP_MOUNT` | *(empty)* | Skip unmount after install for debugging |
| `BASE_IMAGE` | *(arch default)* | Override the same-arch Arch base image for the container build (`docker.io/library/archlinux` on x86_64, `docker.io/menci/archlinuxarm` on aarch64). Environment variable. |

## Project Layout

```
make/install.sh         # Main build script — partitions, pacstraps, installs GRUB
make/image.sh           # Build dispatcher — native on Arch, else same-arch Arch container
make/image-container.sh # Runs install.sh inside a same-arch Arch container (non-Arch hosts)
make/Containerfile.build # Builder image: same-arch Arch base (BASE_IMAGE ARG) + host-side build tools
scripts/configure.sh    # Runs inside chroot — installs rust binaries, configures systemd
town-os.yaml            # Build config (storage_backend, btrfs_raid_mode, vm_disk_size)
make/                   # Helper scripts for each Makefile target
initcpio/
  install/town-installer  # Bundles ttyforce + btrfs into initrd
  hooks/town-installer    # Runs ttyforce in initrd before root mount
  install/town-squashfs   # Bundles squashfs/overlay/loop modules
  hooks/town-squashfs     # Mounts squashfs root with tmpfs overlay
systemd/
  town-os-systemcontroller.service  # Podman-based system controller
  town-os-system--rolodex.service   # Rolodex DNS, runs before systemcontroller
  town-os-podman-api.service        # Persistent podman REST API at /run/podman/podman.sock
  town-os-sledgehammer.service      # Erase permanent storage on demand
  town-os-network-diag.*            # Periodic network state logging
  town-os-overlays.service           # Mount persistent etc/var overlays from btrfs
  town-os-getty@.service            # ttyforce getty for virtual consoles
  town-os-serial-getty@.service     # ttyforce getty for serial consoles
```

## Image Build Flow

1. `make/install.sh` creates a sparse raw image with GPT: BIOS boot (1 MiB), EFI (64 MiB), ext4 data (remainder)
2. `pacstrap` bootstraps Arch with base packages, podman, grub, btrfs-progs, openssh, dhcpcd, parted, and a curated set of admin/debug utilities (inetutils, iputils, less, vim, nano, htop, strace, tcpdump, lsof, jq, tmux, etc. — see `BASE_UTILS` in `make/install.sh`)
3. Initcpio hooks and systemd services are copied into the chroot
4. `configure.sh` runs in chroot: installs rust, builds charon + ttyforce, runs mkinitcpio, trims firmware, removes build deps
5. systemd units are enabled via D-Bus in a Podman container (`--rootfs` + `--systemd=true --unit=basic.target`)
6. GRUB is installed for both UEFI and BIOS boot
7. Root filesystem is compressed to squashfs with gzip (`root.sfs`) on the data partition
8. Image is shrunk to actual size

## Boot Sequence

1. GRUB loads kernel + initrd from data partition
2. **town-installer hook**:
   - Starts serial console (`agetty` on ttyS0)
   - Waits for udev to settle (block devices to appear)
   - Scans for existing btrfs on data disks — if found, skips ttyforce (already provisioned)
   - Prepares dhcpcd directories and resolv.conf
   - Runs `ttyforce initrd --etc-prefix /town-os/etc/overlays/root`
   - After ttyforce: re-mounts btrfs, creates overlay dirs, masks catch-all networkd config
3. **town-squashfs hook**: loop-mounts `root.sfs`, creates tmpfs overlay, scans for btrfs and mounts `/town-os`, overlays `/etc` and `/var` with btrfs-backed upper dirs, switch_root
4. systemd starts: systemcontroller (podman), networkd, resolved (mDNS), sshd, ttyforce getty (agetty on tty1/ttyS0 with ttyforce as login program — ttyforce manages /bin/login)

## systemd Operations

All systemd operations MUST use D-Bus (`busctl`) instead of the `systemctl` CLI. During image build, systemd calls run inside a Podman container (`--rootfs` + `--systemd=true`) so nothing affects the host. Use `podman exec <container> busctl call org.freedesktop.systemd1 ...` for build-time operations. For host-side developer tooling (`deps.sh`), use `busctl call` directly.

## Architecture Notes

- **Root is read-only squashfs + tmpfs overlay.** Changes are lost on reboot unless written to `/town-os` (persistent btrfs).
- **ttyforce runs in the initrd** via `ttyforce initrd --etc-prefix /town-os/etc/overlays/root`. The `initrd` subcommand uses syscalls and dhcpcd directly (no systemd/dbus). `--etc-prefix` tells ttyforce to write network config (networkd units, resolv.conf, wpa_supplicant) directly into the btrfs overlay upper dir, so it persists across reboots. ttyforce handles disk partitioning, btrfs formatting, mounting/unmounting `/town-os`, and all networking. **All file operations that ttyforce uses to configure the machine (network config, SSH keys, etc.) must come after filesystem creation** — `/town-os` is not a real filesystem until ttyforce creates and mounts the btrfs. Any directories created before ttyforce runs are on the initrd tmpfs and get lost when the btrfs is formatted and mounted.
- **Serial console is off by default**: The default GRUB "Town OS" entry only sets `console=tty0` — the serial device (`ttyS0`) is not used at all. Serial is only active when the "Town OS (Serial Console)" entry is selected (`console=ttyS0,115200`). The serial getty service (`town-os-serial-getty@.service`) is gated by `ConditionKernelCommandLine=console=ttyS0,115200` so it only starts when serial is selected. ttyforce must NOT unconditionally write to the serial console; it should only use the TTY it is given (via `--tty` or the kernel `console=` parameter).
- **Persistent storage layout on `/town-os` (btrfs):**
  - `/town-os/etc/overlays/root` — overlay upper dir for `/etc`
  - `/town-os/etc/overlays/work` — overlay work dir for `/etc`
  - `/town-os/var/overlays/root` — overlay upper dir for `/var`
  - `/town-os/var/overlays/work` — overlay work dir for `/var`
  - `/town-os/containers` — podman container storage (graphroot)
- **Podman uses native btrfs/zfs driver** to avoid overlayfs-on-overlayfs (since root is already an overlay).
- **DNS**: `/etc/resolv.conf` is always a symlink to resolved's stub (`/run/systemd/resolve/stub-resolv.conf`). systemd-resolved is the broker: it is configured with `DNS=127.0.0.2 1.1.1.1 8.8.8.8` and `FallbackDNS=1.1.1.1 8.8.8.8`, so queries prefer rolodex when it's up and fall through to Cloudflare/Google automatically on timeout or refusal. Nothing else edits `/etc/resolv.conf` at runtime — the systemcontroller's `ExecStartPre`/`ExecStopPost` re-assert the stub symlink defensively, but the upstream fallthrough in resolved is the real guarantee. Dev mode (`LOCAL_DNS`) uses 8.8.8.8 and skips rolodex. **Per-link DNS gotcha**: networkd populates per-link DNS from DHCP by default, which can override the global `DNS=` list. ttyforce's generated networkd units must set `[DHCPv4] UseDNS=no` (and v6 equivalent) so the global list wins. Rolodex MUST always run with `--net host` — it needs direct access to the host network stack to bind its DNS listeners and detect the external interface. It binds to `127.0.0.2:53` (local resolution) and `primary:53` (default-route outbound IP, auto-detected by rolodex). It MUST NOT bind to `0.0.0.0` — that would conflict with podman's DNS listener. The `dns.bind` config field is a YAML list of single-key maps: `{udp: "addr"}` or `{tcp: "addr"}`; the special value `primary` tells rolodex to bind to the OS default-route IP address.
- **Sledgehammer mode**: GRUB menu entry "Sledgehammer - Erase Permanent Storage And Reboot" sets `town.sledgehammer` kernel param, which triggers full wipe of all non-boot disks. ttyforce getty receives the entry name via `--sledgehammer-grub-entry` so it can trigger a sledgehammer reboot from the TUI. This flag must always match the exact GRUB menuentry title in `make/install.sh`.
- **`/.town` directory** holds internal mounts that back the root overlay (squashfs at `/.town/sfs`, data partition at `/.town/data`, tmpfs overlay at `/.town/overlay`). The squashfs is also exposed at `/usb`. Do not modify these.
- **`/var` overlay is mounted in the initrd, `/etc` overlay by systemd**: The `/var` overlay MUST be mounted in the initrd (town-squashfs hook) because mounting over `/var` after systemd starts breaks journald, sockets, and PID files. The mount options MUST use post-pivot paths (`/.town/sfs/var`, `/town-os/var/overlays/root`) — never `$newroot/...` — so `/proc/mounts` is clean after `switch_root`. This works because the underlying mounts (`/.town/*`, `/town-os`) are already `mount --move`d into `$newroot` before the overlay is created. The mount target itself (`$newroot/var`) still needs the prefix since we haven't pivoted yet, but the `-o` paths must be the final paths. The `/etc` overlay is mounted by `town-os-overlays.service` using the same post-pivot paths (`/.town/sfs/etc`, `/town-os/etc/overlays/root`) and runs before `local-fs.target` so it's in place before networkd/sshd/resolved start.
- **`/boot`** is bind-mounted from the data partition so kernel/GRUB updates persist.
- **Build cleanup**: `make/install.sh` uses a trap to clean up loopback devices and mounts on failure. Use `make cleanup-loopback` to manually clean stale loopback devices.
- **Image size optimization**: The base runtime ships a curated set of admin utilities (see `BASE_UTILS` in `make/install.sh`); adjust that list to tune image size. The build strips `base-devel`, `clang`, and the Rust toolchain after compiling charon/ttyforce. `linux-firmware` is trimmed to only WiFi (`iwlwifi`, `ath9k`, `ath10k`, `ath11k`, `brcmfmac`, `mt76x2u`, `rtw88`, `rtw89`), Ethernet (`rtl_nic`, `tigon`, `bnxt`, `intel`, `i40e`, `ice`, `mellanox`), GPU framebuffer (`amdgpu`, `radeon`, `i915`, `nvidia`), and regulatory DB firmware. The package cache is cleaned after all installs. Squashfs uses zstd compression (the `zstd` kernel module is explicitly included in the initrd MODULES list to ensure decompression support at boot). The EFI partition is 64 MiB (minimal but safe for UEFI firmware compatibility). These optimizations target a final image under 4 GB for USB flash drives.
- **Kernel modules in initrd**: Filesystem support (`loop`, `overlay`, `squashfs`, `zstd`), storage drivers (`ahci`, `sd_mod`, `virtio_blk`, `virtio_scsi`, `nvme`, `usb_storage`, `uas`), wired network drivers (`e1000`, `e1000e`, `igb`, `ixgbe`, `i40e`, `ice`, `virtio_net`, `r8169`, `tg3`, `bnxt_en`, `mlx4_en`, `mlx5_core`), and WiFi drivers (`cfg80211`, `mac80211`, `iwlwifi`, `iwlmvm`, `ath9k`, `ath10k_pci`, `ath11k_pci`, `brcmfmac`, `mt76x2u`, `rtw88_pci`, `rtw89_pci`) are explicitly included since `autodetect` is disabled.
- **Initrd binaries**: `ttyforce`, `dhcpcd`, `ip`, `iw`, `iwlist`, `wpa_supplicant`, `rfkill`, `ping`, `pkill`, `setsid`, `agetty`, `parted`, `partprobe`, `udevadm`, `mkfs.btrfs`, `wipefs`, `btrfs`, plus standard mount/umount/mkdir/mountpoint. WiFi tools (`iw`, `iwlist`, `wpa_supplicant`, `rfkill`) are required for ttyforce's initrd WiFi provisioning — it scans with `iw`/`iwlist`, unblocks radios with `rfkill`, and authenticates with `wpa_supplicant`.
- **`sudo` environment**: NEVER use `sudo -E` — it leaks the entire user environment (XDG_RUNTIME_DIR, DBUS_SESSION_BUS_ADDRESS, HOME, etc.) into root processes, causing root-owned files in `/run/user/1000` and `~/.gnupg` (pacman/pacstrap uses GPG with `$HOME/.gnupg`). Use plain `sudo` and pass only specific variables needed on the command line (e.g. `sudo VAR=value command`). None of the current build/VM scripts need HOME or SSH_AUTH_SOCK.
- **SSH authorized_keys**: ttyforce writes per-user SSH keys to `/town-os/ssh/authorized_keys/{username}` (dir 755, files 644) via `--ssh-user root,status`. The image (squashfs) always ships with password auth enabled and the default `AuthorizedKeysFile` — this is the safe fallback for fresh installs with no keys. At boot, `town-os-overlays.service` checks if any keys exist in `/town-os/ssh/authorized_keys/`; if so, it rewrites sshd_config to point `AuthorizedKeysFile` at `/town-os/ssh/authorized_keys/%u` and disables password auth. This change persists in the `/etc` overlay. If no keys exist, sshd_config is untouched and password auth works normally. `AuthorizedKeysFile` MUST only point at the `/town-os` directory structure when keys are present — never `.ssh/authorized_keys`. Keys are deduplicated by ttyforce.
- **DNS bootstrap**: systemd-resolved is configured with `DNS=127.0.0.2 1.1.1.1 8.8.8.8` and `FallbackDNS=1.1.1.1 8.8.8.8` so DNS works immediately at boot — rolodex is preferred once it's listening, and the upstream servers carry resolution until it is. A drop-in (`no-disable.conf`) sets `RefuseManualStop=yes` so resolved can't be taken down. The systemcontroller re-asserts the resolv.conf → stub symlink in its `ExecStartPre`/`ExecStopPost` as a defensive measure, but nothing at runtime repoints resolv.conf away from the stub.
- **`StartLimitIntervalSec` belongs in `[Unit]`**: systemd silently ignores this directive if placed in `[Service]`. Always put it in `[Unit]`.
- **Service restart resilience**: Systemd services that depend on network (e.g. systemcontroller pulling container images) must use `StartLimitIntervalSec=0` to disable the start rate limit, and a reasonable `RestartSec` (e.g. 5s) to avoid spamming. Without this, systemd's default rate limit (5 starts in 10s) permanently stops restarting the service if the network isn't ready yet (e.g. DNS unavailable before rolodex is running).
- **Container image pull policy**: Both the systemcontroller and rolodex services MUST use `--pull=always` so that container images are re-pulled on every (re)start. This ensures updates are picked up without manual intervention.
- **Podman API socket for the systemcontroller**: `town-os-podman-api.service` runs `podman system service -t 0 unix:///run/podman/podman.sock` as a long-running process (not socket-activated) so the host's podman REST API is always reachable. The systemcontroller container `Requires=` and `After=` this unit, and bind-mounts the socket (`-v /run/podman/podman.sock:/run/podman/podman.sock`) so it can drive sibling containers via the host podman. The host podman's graphroot remains `/town-os/containers` (set in `/etc/containers/storage.conf`), so all images and containers managed via the socket land on the persistent btrfs. The systemcontroller also bind-mounts `/var/lib/containers:/var/lib/containers:shared`; note that this is **not** the host graphroot — `/var/lib/containers` lives on the btrfs-backed `/var` overlay and is exposed as a separate persistent path distinct from `/town-os/containers`. The `:shared` propagation lets nested mounts under that path become visible across the bind in both directions. The systemcontroller's `ExecStartPre` `mkdir -p /var/lib/containers` ensures the host directory exists before podman creates the bind.
- **Always native builds; never cross-arch, never emulation, never binfmt**: The image architecture ALWAYS equals the build host's (or same-arch builder container's) architecture — x86_64 host → x86_64 image, aarch64 host → aarch64 image. The build MUST NEVER cross-compile, run under CPU emulation, or inspect/register/configure `binfmt_misc`. Non-Arch hosts build inside a **same-architecture** Arch container only (it supplies Arch's `pacstrap`/`mkinitcpio`, nothing more). To produce an image for a different architecture, build on a host of that architecture. `install.sh` keys all arch-specific choices (kernel package, GRUB target, BIOS partition) off `uname -m`.
- **No host side effects**: Build and VM tasks (image, qemu, qemu-fg, run) MUST NOT install packages, modify host services, or touch the host's package manager. The `deps` target is manual-only and must never be a dependency of other targets. `pacstrap` inside `make/install.sh` uses the host's pacman database (unavoidable), but no other host state should be modified during builds.
- **NEVER run image builds or flash commands**: Claude MUST NOT run `make image`, `make flash`, `make qemu-fg`, `make qemu`, `make run`, `sudo make`, or any command that builds images or writes to USB devices. These are destructive, long-running, require root, and must only be initiated by the user. Claude may edit source files, Makefile rules, and scripts, but must leave building and flashing to the user.
- **Image freshness**: `$(IMAGE)` depends on `IMAGE_SOURCES` (a wildcard of all scripts, systemd units, initcpio hooks, town-os.yaml, and Makefile) plus `.build-config` (a stamp file tracking build-relevant variables like `CONTROLLER_IMAGE`, `TTYFORCE_DEV`, etc.). Changing a source file or passing a different variable triggers an automatic rebuild when any target that depends on the image is invoked (flash, qemu, qemu-fg, run, virtualbox).

## Default Credentials

- **User:** root
- **Password:** enjoytownos
- **SSH:** password auth enabled by default in the image; disabled at boot when authorized_keys exist on `/town-os`

## Storage Config (town-os.yaml)

```yaml
storage_backend: btrfs    # btrfs or zfs
btrfs_raid_mode: native   # native (btrfs RAID profiles) or mdadm
vm_disk_size: 50G
```

## Testing Changes

After modifying hooks or scripts, rebuild and launch:

```sh
make clean && make qemu-fg
```

Use `IMAGE_HOSTNAME` to avoid mDNS collisions when a real Town OS instance is already running on the network, or when multiple VMs are being tested simultaneously:

```sh
IMAGE_HOSTNAME=town-os-dev make clean && make qemu-fg
```

Each VM gets its own hostname and mDNS name (e.g. `town-os-dev.local`), preventing conflicts with production or other test instances.

Use `make serial` to attach to a backgrounded VM's serial console for debugging boot issues. Network diagnostics are logged to `/town-os/network-diag.log` on the data partition.
