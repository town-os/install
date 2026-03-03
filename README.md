# Town OS Install

Builds a bootable Town OS image and launches it in a VM.

For more information, visit the [Town OS website](https://town-os.github.io) or
the [source repository](https://gitea.com/town-os/town-os).

## Usage

```
make                # build the image (calls sudo internally)
make qemu           # build + launch in QEMU
make virtualbox     # build + create/launch VirtualBox VM
make cleanup-loopback  # emergency loopback cleanup
```

### Targets

| Target              | Description                                              |
|---------------------|----------------------------------------------------------|
| `build-image`       | Build the raw disk image (default target)                |
| `qemu`              | Build image, create sparse data disks, launch QEMU       |
| `virtualbox`        | Build image, create VBox VM with VDI disks, launch it    |
| `cleanup-loopback`  | Kill processes on loopback mounts and detach all loops    |

### Tunable variables

Override on the command line, e.g. `make qemu VM_MEMORY=8G`.

| Variable       | Default                          | Description                              |
|----------------|----------------------------------|------------------------------------------|
| `IMAGE`        | `image.raw`                      | Output image filename                    |
| `IMAGE_SIZE`   | `10G`                            | Size of the raw disk image               |
| `VM_DISK_SIZE` | `50G` (from `town-os.yaml`)      | Size of each sparse data disk            |
| `VM_MEMORY`    | `4G`                             | RAM allocated to the QEMU VM             |
| `VM_NAME`      | `town-os`                        | VirtualBox VM name                       |

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
   - Enables systemd services: storage provisioning, buckle, charon, gild,
     panel, avahi, networkd, and resolved.
   - Writes a DHCP network configuration for ethernet interfaces.
   - Sets the GRUB distributor to Town OS.

5. **Install GRUB** — Both `x86_64-efi` (removable) and `i386-pc` targets are
   installed so the image can boot on UEFI and legacy BIOS systems.

### Environment variables

| Variable     | Effect                                                        |
|--------------|---------------------------------------------------------------|
| `DEBUG`      | When non-empty, storage scripts run in debug/dry-run mode     |
| `KEEP_MOUNT` | When non-empty, skip unmount and USB write; print mount path |
