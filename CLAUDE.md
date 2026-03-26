# Town OS Install

Arch-based disk image builder for Town OS. Produces a bootable raw image with a read-only squashfs root, tmpfs overlay, and custom initrd hooks for hardware provisioning.

## Build & Run

```sh
make deps        # install host dependencies (Arch Linux)
make deps-debian # install host dependencies (Debian/Ubuntu)
make image       # build image only (requires root, Arch host)
make             # build image and launch VM
make qemu-fg     # build and launch QEMU with serial console attached
make serial      # attach to running QEMU serial console (Ctrl-] to disconnect)
make stop        # stop all VMs
make clean       # remove all images and VM disks
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
```

To build images on Debian/Ubuntu, use an Arch Linux container or build on an Arch host and transfer the image.

### Host Dependencies

**Arch Linux** (`make deps`):
`base-devel` `arch-install-scripts` `parted` `e2fsprogs` `dosfstools` `rsync` `psmisc` `lsof` `squashfs-tools` `libvirt` `dnsmasq` `qemu-full` `socat` `lbzip2` `pv` `podman` `dbus`

**Debian/Ubuntu** (`make deps-debian`):
`build-essential` `parted` `e2fsprogs` `dosfstools` `rsync` `psmisc` `lsof` `squashfs-tools` `libvirt-daemon-system` `libvirt-clients` `dnsmasq-base` `qemu-system-x86` `qemu-utils` `socat` `lbzip2` `pv` `podman` `dbus` `util-linux`

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_HOSTNAME` | `town-os` | System hostname and mDNS name |
| `LOCAL_DNS` | *(empty)* | Dev DNS override (`1` = auto, or literal hostname) |
| `CONTROLLER_IMAGE` | `quay.io/town/town:rc.latest` | System controller container |
| `TTYFORCE_DEV` | *(empty)* | Set non-empty to install ttyforce from git instead of crates.io |
| `TTYFORCE_LATEST` | *(empty)* | Set non-empty to install the latest ttyforce from crates.io (ignores version pin) |
| `KEEP_MOUNT` | *(empty)* | Skip unmount after install for debugging |

## Project Layout

```
make/install.sh         # Main build script — partitions, pacstraps, installs GRUB
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
  town-os-sledgehammer.service      # Erase permanent storage on demand
  town-os-network-diag.*            # Periodic network state logging
  town-os-getty@.service            # ttyforce getty for virtual consoles
  town-os-serial-getty@.service     # ttyforce getty for serial consoles
```

## Image Build Flow

1. `make/install.sh` creates a sparse raw image with GPT: BIOS boot (1 MiB), EFI (64 MiB), ext4 data (remainder)
2. `pacstrap` bootstraps Arch with base packages, podman, grub, btrfs-progs, openssh, dhcpcd, parted
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
- **ttyforce runs in the initrd** via `ttyforce initrd --etc-prefix /town-os/etc/overlays/root`. The `initrd` subcommand uses syscalls and dhcpcd directly (no systemd/dbus). `--etc-prefix` tells ttyforce to write network config (networkd units, resolv.conf, wpa_supplicant) directly into the btrfs overlay upper dir, so it persists across reboots. ttyforce handles disk partitioning, btrfs formatting, mounting/unmounting `/town-os`, and all networking.
- **Persistent storage layout on `/town-os` (btrfs):**
  - `/town-os/etc/overlays/root` — overlay upper dir for `/etc`
  - `/town-os/etc/overlays/work` — overlay work dir for `/etc`
  - `/town-os/var/overlays/root` — overlay upper dir for `/var`
  - `/town-os/var/overlays/work` — overlay work dir for `/var`
  - `/town-os/containers` — podman container storage (graphroot)
- **Podman uses native btrfs/zfs driver** to avoid overlayfs-on-overlayfs (since root is already an overlay).
- **DNS**: production uses Cloudflare (1.1.1.1) initially; rolodex overwrites `/etc/resolv.conf` with 127.0.0.2 once running. Dev mode (`LOCAL_DNS`) uses 8.8.8.8 and skips rolodex.
- **Sledgehammer mode**: GRUB menu entry sets `town.sledgehammer` kernel param, which triggers full wipe of all non-boot disks.
- **`/.town` directory** holds internal mounts that back the root overlay (squashfs at `/.town/sfs`, data partition at `/.town/data`, tmpfs overlay at `/.town/overlay`). The squashfs is also exposed at `/usb`. Do not modify these.
- **`/boot`** is bind-mounted from the data partition so kernel/GRUB updates persist.
- **Build cleanup**: `make/install.sh` uses a trap to clean up loopback devices and mounts on failure. Use `make cleanup-loopback` to manually clean stale loopback devices.
- **Image size optimization**: The build strips `base-devel`, `clang`, and the Rust toolchain after compiling charon/ttyforce. `linux-firmware` is trimmed to only WiFi (`iwlwifi`, `ath9k`, `ath10k`, `ath11k`, `brcmfmac`, `mt76x2u`, `rtw88`, `rtw89`), Ethernet (`rtl_nic`, `tigon`, `bnxt`, `intel`, `i40e`, `ice`, `mellanox`), GPU framebuffer (`amdgpu`, `radeon`, `i915`, `nvidia`), and regulatory DB firmware. The package cache is cleaned after all installs. Squashfs uses gzip compression. The EFI partition is 64 MiB (minimal but safe for UEFI firmware compatibility). These optimizations target a final image under 4 GB for USB flash drives.
- **Kernel modules in initrd**: Storage drivers (`ahci`, `sd_mod`, `virtio_blk`, `virtio_scsi`, `nvme`, `usb_storage`, `uas`), wired network drivers (`e1000`, `e1000e`, `igb`, `ixgbe`, `i40e`, `ice`, `virtio_net`, `r8169`, `tg3`, `bnxt_en`, `mlx4_en`, `mlx5_core`), and WiFi drivers (`cfg80211`, `mac80211`, `iwlwifi`, `iwlmvm`, `ath9k`, `ath10k_pci`, `ath11k_pci`, `brcmfmac`, `mt76x2u`, `rtw88_pci`, `rtw89_pci`) are explicitly included since `autodetect` is disabled.
- **Initrd binaries**: `ttyforce`, `dhcpcd`, `ip`, `iw`, `iwlist`, `wpa_supplicant`, `rfkill`, `ping`, `pkill`, `setsid`, `agetty`, `parted`, `partprobe`, `udevadm`, `mkfs.btrfs`, `wipefs`, `btrfs`, plus standard mount/umount/mkdir/mountpoint. WiFi tools (`iw`, `iwlist`, `wpa_supplicant`, `rfkill`) are required for ttyforce's initrd WiFi provisioning — it scans with `iw`/`iwlist`, unblocks radios with `rfkill`, and authenticates with `wpa_supplicant`.
- **`sudo -E`**: All `sudo` calls in make scripts and make/install.sh MUST use `-E` to preserve the environment.
- **No host side effects**: Build and VM tasks (image, qemu, qemu-fg, run) MUST NOT install packages, modify host services, or touch the host's package manager. The `deps` target is manual-only and must never be a dependency of other targets. `pacstrap` inside `make/install.sh` uses the host's pacman database (unavoidable), but no other host state should be modified during builds.

## Default Credentials

- **User:** root
- **Password:** enjoytownos
- **SSH:** enabled with password auth

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
