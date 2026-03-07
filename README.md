# Town OS Install

Builds a bootable Town OS image and launches it in a VM.

For more information, visit the [Town OS website](https://town-os.github.io) or
the [source repository](https://gitea.com/town-os/town-os).

## Dependencies

The build host must be Arch-based (Arch Linux or Manjaro).

### Required (image build)

| Package                | Provides                                      | Install                              |
|------------------------|-----------------------------------------------|--------------------------------------|
| `base-devel`           | `make`, core build tools                      | `pacman -S base-devel`               |
| `arch-install-scripts` | `pacstrap`, `genfstab`, `arch-chroot`         | `pacman -S arch-install-scripts`     |
| `parted`               | `parted`, `partprobe`                         | `pacman -S parted`                   |
| `util-linux`           | `losetup`, `mountpoint`, `truncate`, `mount`  | included in base                     |
| `e2fsprogs`            | `mkfs.ext4`                                   | `pacman -S e2fsprogs`                |
| `dosfstools`           | `mkfs.fat`                                    | `pacman -S dosfstools`               |
| `rsync`                | `rsync`                                       | `pacman -S rsync`                    |
| `psmisc`               | `fuser`                                       | `pacman -S psmisc`                   |
| `lsof`                 | `lsof`                                        | `pacman -S lsof`                     |

### Optional (VM targets)

| Package                         | Provides             | Install                               |
|---------------------------------|----------------------|---------------------------------------|
| `qemu-full` or `qemu-system-x86` | `qemu-system-x86_64` | `pacman -S qemu-full`                |
| `virtualbox`                    | `VBoxManage`         | `pacman -S virtualbox`                |

### Install all required dependencies

```
make deps
```

For QEMU support add `qemu-full`. For VirtualBox support add `virtualbox`.

## Quick start

```
make deps           # install build dependencies
make image          # build a dev image (rc.latest controller)
make image-release  # build a release image (latest controller)
make qemu           # build + launch QEMU in background, print VM IP when ready
make qemu-fg        # build + launch QEMU in foreground
make stop-qemu      # stop the background QEMU instance
```

### Targets

| Target              | Description                                                    |
|---------------------|----------------------------------------------------------------|
| `image`             | Build the raw disk image (default target)                      |
| `image-release`     | Build a release image (`quay.io/town/town:latest`)             |
| `qemu`              | Build image, launch QEMU in background, wait for VM IP         |
| `qemu-fg`           | Build image, launch QEMU in foreground                         |
| `stop-qemu`         | Stop a background QEMU instance                                |
| `virtualbox`        | Build image, create VBox VM, launch headless in background     |
| `virtualbox-fg`     | Build image, create VBox VM, launch with GUI                   |
| `stop-virtualbox`   | Power off the VirtualBox VM                                    |
| `vm-ip`             | Resolve and print the VM's IP address                          |
| `clean`             | Remove all image and VM disk files                             |
| `deps`              | Install required build dependencies via pacman                  |
| `cleanup-loopback`  | Kill processes on loopback mounts and detach all loops          |

### Tunable variables

Override on the command line, e.g. `make qemu VM_MEMORY=8G`.

| Variable           | Default                          | Description                              |
|--------------------|----------------------------------|------------------------------------------|
| `IMAGE`            | `image.raw`                      | Output image filename                    |
| `IMAGE_SIZE`       | `12G`                            | Size of the raw disk image               |
| `CONTROLLER_IMAGE` | `quay.io/town/town:rc.latest`    | System controller container image        |
| `VM_DISK_SIZE`     | `50G` (from `town-os.yaml`)      | Size of each sparse data disk            |
| `VM_MEMORY`        | `4G`                             | RAM allocated to the QEMU VM             |
| `VM_BRIDGE`        | `virbr0`                         | Bridge interface for VM networking       |
| `VM_NAME`          | `town-os`                        | VirtualBox VM name                       |

## Multicast DNS (town-os.local)

The VM advertises itself as `town-os.local` via avahi/mDNS. For this to work
from the host when using the default `virbr0` bridge (libvirt NAT), the host's
avahi daemon must have mDNS reflection enabled. `make deps` configures this
automatically by setting `enable-reflector=yes` in `/etc/avahi/avahi-daemon.conf`
and restarting the service.

If you've already run `make deps` and `town-os.local` still doesn't resolve,
verify manually:

```
grep enable-reflector /etc/avahi/avahi-daemon.conf
# should show: enable-reflector=yes
```

Once the VM is running, use `make vm-ip` to resolve its IP address.

## Default credentials

- **User:** `root`
- **Password:** `enjoytownos`

## Configuration

Edit `town-os.yaml` before building to configure how the image behaves. The
file is copied into the image at `/usr/lib/town-os/town-os.yaml` and read by
the storage provisioning scripts at boot time.

| Setting            | Values                | Default  | Description                                    |
|--------------------|-----------------------|----------|------------------------------------------------|
| `storage_backend`  | `btrfs`, `zfs`        | `btrfs`  | Filesystem used for the storage pool           |
| `btrfs_raid_mode`  | `native`, `mdadm`     | `native` | Multi-disk redundancy strategy (btrfs only)    |
| `vm_disk_size`     | any `truncate -s` val | `50G`    | Size of each VM data disk (sparse)             |

## Installation process

The install script performs the following steps:

1. **Create a raw disk image** — A sparse file (default 10 GB) is created and
   attached to a loopback device.

2. **Partition the image** — A GPT partition table is written with three
   partitions:
   - **Partition 1** (1 MiB–513 MiB) — ext4 boot partition (`TOWN_BOOT`), marked `bios_grub`.
   - **Partition 2** (513 MiB–1 GiB) — FAT32 EFI System Partition (`TOWN_EFI`).
   - **Partition 3** (1 GiB–end) — ext4 data partition (`TOWN_DATA`).

3. **Bootstrap the root filesystem** — `pacstrap` installs a base Arch/Manjaro
   system plus runtime dependencies (podman, avahi, GRUB, etc.). When `zfs` is
   selected as the storage backend, `linux618-zfs` is included; for `btrfs`
   with `mdadm` raid mode, `mdadm` is included.

4. **Configure the system** — Inside the chroot the configure script:
   - Sets the root password, locale, timezone, and hostname (`town-os`).
   - Installs the Charon control-plane binary from source via Cargo.
   - Enables systemd services: storage provisioning, the system controller
     (container image set by `CONTROLLER_IMAGE`), avahi, networkd, and resolved.
   - Writes a DHCP network configuration for ethernet interfaces.
   - Sets the GRUB distributor to Town OS.

5. **Install GRUB** — Both `x86_64-efi` (removable) and `i386-pc` targets are
   installed so the image can boot on UEFI and legacy BIOS systems.

### Environment variables

| Variable           | Effect                                                        |
|--------------------|---------------------------------------------------------------|
| `CONTROLLER_IMAGE` | Container image for the system controller service             |
| `DEBUG`            | When non-empty, storage scripts run in debug/dry-run mode     |
| `KEEP_MOUNT`       | When non-empty, skip unmount and USB write; print mount path  |
