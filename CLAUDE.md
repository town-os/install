# Town OS Install

Arch-based disk image builder for Town OS. Produces a bootable raw image with a read-only squashfs root, tmpfs overlay, and custom initrd hooks for hardware provisioning.

## Build & Run

```sh
make deps    # install host dependencies (Arch-based host required)
make         # build image and launch VM (auto-detects QEMU or VirtualBox)
make image   # build image only
make qemu-fg # build and launch QEMU with serial console attached
make serial  # attach to running QEMU serial console (Ctrl-] to disconnect)
make stop    # stop all VMs
make clean   # remove all images and VM disks
```

Requires root for image building (install.sh uses loopback mounts, chroot, pacstrap).

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `IMAGE_HOSTNAME` | `town-os` | System hostname and mDNS name |
| `LOCAL_DNS` | *(empty)* | Dev DNS override (`1` = auto, or literal hostname) |
| `CONTROLLER_IMAGE` | `quay.io/town/town:rc.latest` | System controller container |
| `TTYFORCE_DEV` | *(empty)* | Set non-empty to install ttyforce from git instead of crates.io |
| `KEEP_MOUNT` | *(empty)* | Skip unmount after install for debugging |

## Project Layout

```
install.sh              # Main build script — partitions, pacstraps, installs GRUB
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
```

## Image Build Flow

1. `install.sh` creates a sparse raw image with GPT: BIOS boot (1 MiB), EFI (512 MiB), ext4 data (remainder)
2. `pacstrap` bootstraps Arch with base packages, podman, avahi, grub, btrfs-progs, openssh
3. Initcpio hooks and systemd services are copied into the chroot
4. `configure.sh` runs in chroot: installs rust, builds charon + ttyforce, runs mkinitcpio, enables services
5. GRUB is installed for both UEFI and BIOS boot
6. Root filesystem is compressed to squashfs (`root.sfs`) on the data partition
7. Image is shrunk to actual size (~2.5 GB)

## Boot Sequence

1. GRUB loads kernel + initrd from data partition
2. **town-installer hook**: checks if `/town-os` (btrfs) is already provisioned; if not, runs `ttyforce run` for interactive hardware setup
3. **town-squashfs hook**: loop-mounts `root.sfs`, creates tmpfs overlay, switch_root
4. systemd starts: systemcontroller (podman), avahi, networkd, sshd

## Architecture Notes

- **Root is read-only squashfs + tmpfs overlay.** Changes are lost on reboot unless written to `/town-os` (persistent btrfs).
- **ttyforce runs in the initrd**, not as a systemd service. This gives it exclusive console access before anything else starts.
- **Podman uses native btrfs/zfs driver** to avoid overlayfs-on-overlayfs (since root is already an overlay).
- **DNS**: production uses Cloudflare (1.1.1.1) initially; rolodex overwrites `/etc/resolv.conf` with 127.0.0.2 once running. Dev mode (`LOCAL_DNS`) uses 8.8.8.8 and skips rolodex.
- **Sledgehammer mode**: GRUB menu entry sets `town.sledgehammer` kernel param, which triggers full wipe of all non-boot disks.

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

Use `make serial` to attach to a backgrounded VM's serial console for debugging boot issues. Network diagnostics are logged to `/town-os/network-diag.log` on the data partition.
