# Town OS Install

Builds a bootable Town OS image and launches it in a VM.

For more information, visit the [Town OS website](https://town-os.github.io) or
the [source repository](https://gitea.com/town-os/town-os).

## Quick start

Works on Arch/Manjaro, Fedora (incl. Asahi Remix), and Debian/Ubuntu.

```
git clone https://gitea.com/town-os/install.git
cd install
make deps        # or `make deps-debian` on Debian/Ubuntu — manual, one time
make run         # build the disk image and launch a VM in the background
```

`make` on its own prints the target and variable help; it does not build
anything. `make run` builds the image (~2.5 GB) if it is stale, auto-detects the
available hypervisor (prefers QEMU, falls back to VirtualBox), and launches the
VM in the background — printing its IP address once it is up. `make qemu-fg`
does the same in the foreground with a console attached.

Dependency installation is **manual and separate** (`make deps`): no build or VM
target ever installs packages or modifies host services.

## Build host architecture

Image builds are **native by default**: with no `TARGET`, the image
architecture matches the build host. An x86_64 host produces an x86_64 image; an
aarch64 host produces an aarch64 image. Native builds never cross-compile and
never run under CPU emulation.

To build for a *different* architecture, name it with `TARGET`:

```
make image TARGET=x86_64    # PC (UEFI/GRUB) image — x86_64 host only
make image TARGET=aarch64   # aarch64 (UEFI/GRUB) image — generic Linux / Apple-Silicon VM
make image TARGET=rpi       # native-boot Raspberry Pi image (aarch64)
```

On an aarch64 host, `aarch64`/`rpi` build natively. On an x86_64 host they are
produced by running the ordinary build inside a **full-system**
`qemu-system-aarch64` VM — a whole emulated machine, not `binfmt`/qemu-user and
not a cross-compiler, so the build still runs as native aarch64 code. It is
slow; the native path is unaffected. There is no x86 emulation path, so
`TARGET=x86_64` requires an x86_64 host.

On non-Arch hosts (e.g. Fedora Asahi Remix), a native `make image` builds inside
a **same-architecture** Arch container — native CPU speed, no emulation. The
base container image differs by architecture:

- **x86_64** uses the official `docker.io/library/archlinux` image.
- **aarch64** uses the third-party `docker.io/menci/archlinuxarm` image, because
  the official Arch image is x86_64-only. Arch Linux ARM ships the aarch64
  `linux-aarch64` kernel from its standard repos.

Override the base image with the `BASE_IMAGE` environment variable, e.g.:

```
BASE_IMAGE=docker.io/lopsided/archlinux make image
```

## Multicast DNS (town-os.local)

The VM advertises itself as `town-os.local` via systemd-resolved mDNS. To use a
different name, set the `IMAGE_HOSTNAME` variable at build time (e.g.
`make image IMAGE_HOSTNAME=mybox` will advertise as `mybox.local`).

Use `IMAGE_HOSTNAME` to avoid mDNS collisions when a real Town OS instance is
already running on the network, or when multiple VMs are being tested at the
same time:

```
IMAGE_HOSTNAME=town-os-dev make clean && make qemu-fg
```

Each VM gets its own hostname and mDNS name (e.g. `town-os-dev.local`),
preventing conflicts with production or other test instances.

For mDNS to work from the host when using the default `virbr0` bridge (libvirt
NAT), `make deps` enables mDNS in systemd-resolved and on the bridge interface.

If you've already run `make deps` and `town-os.local` still doesn't resolve,
verify manually:

```
resolvectl mdns virbr0
# should show: yes
```

Once the VM is running, use `make vm-ip` to resolve its IP address.

## Default credentials

- **User:** `root`
- **Password:** `enjoytownos`

## Targets

`make` with no target prints this list. Every build/run target accepts
`TARGET=x86_64|aarch64|rpi` to pick the image architecture/flavor.

| Target              | Description                                                    |
|---------------------|----------------------------------------------------------------|
| `help`              | Print the target and variable summary (**default goal**)        |
| `run`               | Auto-detect hypervisor, build image if stale, launch VM         |
| `stop`              | Stop any tracked VMs (QEMU and/or VirtualBox)                  |
| `image`             | Build the raw disk image (skips if up to date)                 |
| `image TARGET=rpi`  | Build a native-boot Raspberry Pi image (Pi 4/400/CM4, Pi 5/CM5)|
| `image-log`         | Same as `image`, tee'd into a timestamped log under `LOG_DIR`   |
| `image-container`   | Force the same-arch Arch container build path (native only)     |
| `flash`             | Build image if stale, write to USB (`USB_DEV=/dev/sdX`)         |
| `flash RPI=1`       | Flash the Raspberry Pi image (`-rpi` artifact) to USB/SD/NVMe   |
| `image-release`     | Build the image and compress it to `.bz2`                       |
| `build-installer`   | Build the installer OCI image from `town-os.img.bz2` (no push)  |
| `push-installer`    | Build then push it (`release-<arch>` + dated tag)               |
| `release`           | Build, compress, and push the installer image                   |
| `qemu`              | Build image if stale, launch QEMU in the background              |
| `qemu-fg`           | Build image if stale, launch QEMU in the foreground              |
| `qemu-usb`          | Boot an already-flashed USB stick (`USB_DEV=/dev/sdX`); no build |
| `rebuild-qemu`      | `stop` + `clean` + `image` + `qemu`                             |
| `stop-qemu`         | Stop a background QEMU instance                                |
| `virtualbox`        | Build image, create VBox VM, launch headless in background     |
| `virtualbox-fg`     | Build image, create VBox VM, launch with GUI                   |
| `stop-virtualbox`   | Power off the VirtualBox VM                                    |
| `serial`            | Attach to the QEMU serial console (Ctrl-] to disconnect)       |
| `vm-ip`             | Resolve and print the VM's IP address                          |
| `clean`             | Stop VMs and remove the current image and VM disk files         |
| `clean-images`      | Remove all built images (`*.img`, `*.img.bz2`, `image.raw`)     |
| `deps`              | Install host dependencies on Arch or Fedora (manual only)       |
| `deps-debian`       | Install host dependencies on Debian/Ubuntu (manual only)        |
| `cleanup-loopback`  | Kill processes on loopback mounts and detach all loops          |

## Raspberry Pi images

Build a native-boot Raspberry Pi image (one image covers Pi 4/400/CM4 and
Pi 5/CM5) with `TARGET=rpi`, which uses the Pi's GPU bootloader + `config.txt`
instead of GRUB. It is aarch64-only and btrfs-only. On an aarch64 host (e.g.
Fedora Asahi) it builds natively; on an x86_64 host it is cross-produced under
full-system emulation (slow):

```
make image TARGET=rpi     # or: RPI=1 make image  (native aarch64 host only)
```

Flash the resulting `-rpi` image to an SD card, USB stick, or NVMe (the build
and flash steps are user-run):

```
make flash RPI=1 USB_DEV=/dev/sdX     # or: dd the town-os-<date>-aarch64-rpi.img
```

For **Pi 5 NVMe boot**, also set the EEPROM boot order to include NVMe
(`rpi-eeprom-config --edit` → `BOOT_ORDER=0xf416`; add `PCIE_PROBE=1` for
non-HAT+ adapters) — `dtparam=pciex1` is already in `config.txt`.

### USB power

Bus-powered USB SSD/NVMe adapters, hubs, and power-hungry sticks — exactly the
devices a from-USB install image boots off — brown out under the firmware's
default USB current cap. The generated `config.txt` already lifts it on both
boards, so no action is needed in the common case:

- **Pi 5:** `usb_max_current_enable=1` (`[pi5]`) raises the 600 mA total cap to
  the full ~1.6 A even when the PSU doesn't advertise 5 A.
- **Pi 4:** `max_usb_current=1` (`[pi4]`) raises the 600 mA cap to 1.2 A.

If a Pi 5 still browns out a peripheral with a genuine 5 A PSU, the firmware
only unlocks full current when it can confirm the PSU's capability, which some
third-party supplies don't report. Force it in the EEPROM (a **bootloader**
setting, distinct from `config.txt`):

```
rpi-eeprom-config --edit     # add: PSU_MAX_CURRENT=5000
```

Verify on a booted Pi 5 with `vcgencmd get_config usb_max_current_enable` and
`vcgencmd pmic_read_adc` (per-rail current).

## Image freshness

The image is rebuilt automatically when any source file changes (scripts, systemd
units, initcpio hooks, `town-os.yaml`, `Makefile`) or when build variables change
(`CONTROLLER_TAG`, `TTYFORCE_DEV`, etc.). A `.build-config` stamp file tracks the
current variable values; if they differ from the last build, the image is rebuilt.

## Tunable variables

Override on the command line, e.g. `make qemu VM_MEMORY=8G`.

| Variable           | Default                          | Description                              |
|--------------------|----------------------------------|------------------------------------------|
| `TARGET`           | *(empty)*                        | Image arch/flavor: `x86_64`, `aarch64`, or `rpi`. Empty = native host arch |
| `IMAGE`            | `town-os-<date>-<arch>[-rpi].img`| Output image filename                    |
| `IMAGE_SIZE`       | `12G`                            | Size of the raw disk image               |
| `LOG_DIR`          | `/tmp/town-os-install/log`       | Where `image-log` writes its build transcript |
| `CONTROLLER_BASE`  | `quay.io/town/town`              | Controller image repository (no tag)      |
| `CONTROLLER_TAG`   | `rc.latest-<arch>`               | Controller image tag (arch-suffixed; composed onto base) |
| `CONTROLLER_IMAGE` | `$(CONTROLLER_BASE):$(CONTROLLER_TAG)` | Full controller image reference (override to use a different registry) |
| `UI_IMAGE`         | `quay.io/town/ui:rc.latest-<arch>`| UI container image                       |
| `INSTALLER_BASE`   | `quay.io/town/installer`         | Repository `push-installer` publishes the compressed image to |
| `INSTALLER_TAG`    | `release-<arch>[-rpi]`           | Rolling installer tag (a dated tag is pushed alongside it) |
| `VM_DISK_SIZE`     | `50G` (from `town-os.yaml`)      | Size of each sparse data disk            |
| `VM_MEMORY`        | `4G`                             | RAM allocated to the QEMU VM             |
| `VM_CPUS`          | `4`                              | vCPUs for the VM (QEMU's default of 1 starves CPU-scaled worker pools) |
| `VM_BRIDGE`        | `virbr0`                         | Bridge interface for VM networking       |
| `VM_NAME`          | `town-os`                        | VM name; also seeds the VM's stable MAC  |
| `VM_IP`            | `192.168.122.50`                 | IP pinned for the VM via a libvirt DHCP reservation. Give each concurrent VM its own |
| `VM_NET6_PREFIX`   | `fd00:c0a8:7a`                   | IPv6 ULA /64 offered to the guest via SLAAC (only when the host has working IPv6). Empty disables |
| `VM_LAN`           | `1`                              | Expose the NAT'd VM to the LAN so a phone can reach it. `0` disables |
| `USB_DEV`          | *(empty)*                        | USB block device for `flash` (write) and `qemu-usb` (boot read-only) |
| `USB_PHONE`        | *(empty)*                        | Pass a live phone through to the guest: `auto`, `vid:pid`, or `bus.port` |
| `SERIAL_CONSOLE`   | *(empty)*                        | Build an image whose GRUB defaults to the serial console (no keyboard/monitor needed) |
| `IMAGE_HOSTNAME`   | `town-os`                        | System hostname and mDNS name            |
| `LOCAL_DNS`        | *(empty)*                        | Dev DNS override (see below)             |

## Local DNS mode (development)

In production, Town OS routes DNS through rolodex (listening on `127.0.0.2`) to
resolve package names and other services. For local development you can bypass
rolodex entirely by setting `LOCAL_DNS`:

```
make image LOCAL_DNS=1                    # use the build machine's hostname
make image LOCAL_DNS=myhost.example.com   # use an explicit hostname
```

When `LOCAL_DNS` is set:

- The systemcontroller receives `-package-dns <hostname>` so it resolves
  packages and services against the given host instead of rolodex.
- The network configuration drops `127.0.0.2` from the DNS list (no rolodex).
- Login banners (`/etc/issue`, `/etc/motd`) point to the specified host
  instead of `town-os.local`.

When `LOCAL_DNS` is empty or unset (the default), the image is built in
production mode with rolodex DNS.

## Console and display

QEMU VMs open a **graphical window** on both x86_64 and aarch64, with an
absolute-position USB tablet and keyboard attached so the installer TUI can be
driven without the display grabbing your cursor. Serial is exported alongside it
on a unix socket at `/tmp/town-os-serial.sock`:

```
make serial     # socat against that socket; Ctrl-] to disconnect
```

The QEMU monitor is also exported, at `/tmp/town-os-monitor.sock` — useful when
the guest looks wedged, since `screendump` captures the framebuffer even if the
window never mapped, and `sendkey` injects input without the compositor:

```
socat - UNIX-CONNECT:/tmp/town-os-monitor.sock
```

In the image itself, **serial is off by default**: the GRUB "Town OS" entry only
sets `console=tty0`. Pick the "Town OS (Serial Console)" entry for
`console=<serial>,115200`, or build with `SERIAL_CONSOLE=1` to make that entry
the default, so the machine boots headless with no keyboard or monitor. The
serial device is architecture-specific — `ttyS0` on x86_64, `ttyAMA0` on
aarch64, and on a real Raspberry Pi the firmware picks it per board (`ttyS0` on
Pi 4, `ttyAMA10` on Pi 5).

## Booting a flashed USB stick

To test a stick that has already been written (rather than the image in the
build directory):

```
make qemu-usb USB_DEV=/dev/sdX                    # native, KVM
make qemu-usb TARGET=aarch64 USB_DEV=/dev/sdX     # foreign-arch stick, emulated (slow)
make qemu-usb TARGET=rpi USB_DEV=/dev/sdX         # Raspberry Pi image, emulated
```

This builds nothing. The device is opened read-only (`snapshot=on`), so guest
writes are discarded and the physical stick is never modified. A Pi image has no
UEFI bootloader, so that path extracts the kernel and initramfs from the stick's
FAT partition and boots them directly; its console appears as the **`serial0`
tab** inside the QEMU window.

## Reaching the VM from other devices

The QEMU guest sits behind libvirt's NAT, so a phone on the same wireless
network can neither route to it nor resolve its mDNS name — and a passthrough
bridge is not possible on a WiFi-only host. `make qemu`/`qemu-fg` therefore
start a relay by default (`VM_LAN=1`) that forwards the control API (5309), the
UI (80/443), and ssh (2222 → 22) from the host's LAN address to the guest, plus
the WireGuard UDP port range so custom networks work. Point the phone client at
the **host's** LAN address; the box records the address the client dialed as the
tunnel endpoint, so no manual override is needed. Turn it off with `VM_LAN=0`.

The VM also gets a pinned IP (`VM_IP`, default `192.168.122.50`) via a libvirt
DHCP reservation — without it the guest's address changes on every boot, since
its read-only root can't persist a DHCP client id. Run several VMs at once and
each needs its own `VM_IP` (and its own `IMAGE_HOSTNAME`).

## Publishing the installer image

The compressed image is distributed as a container image rather than a file
download: `make release` builds the image, compresses it to `.bz2`, and pushes a
`scratch` OCI image holding it to `quay.io/town/installer`, tagged
`release-<arch>` (rolling) plus a dated tag. Raspberry Pi builds publish to a
separate `release-<arch>-rpi` tag. The website's `curl | bash` installer pulls
that image and streams the file straight onto a USB stick.

```
make release                  # native host arch
make release TARGET=aarch64   # aarch64 (cross-built under emulation on x86)
make release TARGET=rpi       # Raspberry Pi
```

## Network diagnostics

`town-os-network-diag.service` records network state to
`/town-os/network-diag.log` on the data partition. Each snapshot includes
`ip addr`, `ip route`, `nft list ruleset`, `iptables-save`, and loaded `nf`
kernel modules, and the log persists on the btrfs data disk even if the network
goes down — which is the point: it is there for post-mortem debugging.

It appends **only when the state actually changed**. The comparison ignores
fields that move on their own (DHCP lifetime countdowns, packet counters, the
`iptables-save` timestamp header, module refcounts), so the log holds the
handful of transitions that matter instead of an identical dump every few
seconds. The logged snapshot itself is the full verbatim state.

## Configuration

Edit `town-os.yaml` before building to configure how the image behaves. The
file is copied into the image at `/usr/lib/town-os/town-os.yaml` and read by
the storage provisioning scripts at boot time.

| Setting            | Values                | Default  | Description                                    |
|--------------------|-----------------------|----------|------------------------------------------------|
| `storage_backend`  | `btrfs`, `zfs`        | `btrfs`  | Filesystem used for the storage pool           |
| `btrfs_raid_mode`  | `native`, `mdadm`     | `native` | Multi-disk redundancy strategy (btrfs only)    |
| `vm_disk_size`     | any `truncate -s` val | `50G`    | Size of each VM data disk (sparse)             |

## Dependencies

Dependency installation is **manual**: run `make deps` (Arch/Manjaro or
Fedora/RHEL, auto-detected) or `make deps-debian` (Debian/Ubuntu) once. No
build, VM, or flash target ever installs packages or touches host services.

**Arch Linux** (`make deps`):

```
base-devel arch-install-scripts parted e2fsprogs dosfstools rsync psmisc lsof
squashfs-tools libvirt dnsmasq qemu-full socat lbzip2 pv podman dbus curl cpio
```

**Fedora / RHEL / Rocky / Alma** (`make deps`):

```
gcc make parted e2fsprogs dosfstools rsync psmisc lsof squashfs-tools libvirt
libvirt-client dnsmasq qemu-system-x86 qemu-system-aarch64 qemu-img socat
lbzip2 pv podman util-linux curl cpio
```

**Debian / Ubuntu** (`make deps-debian`):

```
build-essential parted e2fsprogs dosfstools rsync psmisc lsof squashfs-tools
libvirt-daemon-system libvirt-clients dnsmasq-base qemu-system-x86
qemu-system-arm qemu-utils socat lbzip2 pv podman dbus util-linux curl cpio
```

The `arch-install-scripts` tooling (`pacstrap`, `genfstab`, `arch-chroot`) has
no equivalent on Fedora or Debian, so on those hosts the build runs inside a
same-architecture Arch container — hence `podman` in every list. The aarch64
emulator plus `curl`/`cpio` are what the cross-arch `TARGET=aarch64|rpi` build
needs. `virtualbox` (for `VBoxManage`) is not installed by `deps`; install it
yourself if you want the VirtualBox targets.

## Installation process

The install script performs the following steps:

1. **Create a raw disk image** — A sparse file (`IMAGE_SIZE`, default 12 GB) is
   created and attached to a loopback device.

2. **Partition the image** — A GPT partition table is written with three
   partitions:
   - **Partition 1** (1–2 MiB) — raw BIOS boot partition for GRUB's core image.
     Created on every architecture to keep the numbering identical, but flagged
     `bios_grub` and used only on x86_64.
   - **Partition 2** (2–66 MiB) — FAT32 EFI System Partition (`TOWN_EFI`).
     Raspberry Pi images grow this to 512 MiB, because the Pi boot partition
     must also hold the kernel, initramfs, board DTBs, overlays, and GPU
     firmware.
   - **Partition 3** (rest of the disk) — ext4 data partition (`TOWN_DATA`),
     holding `/boot` and the squashfs root.

3. **Bootstrap the root filesystem** — `pacstrap` installs the package set from
   `make/base-packages.txt` (podman, GRUB, openssh, dhcpcd, WiFi and WireGuard
   tools, and a curated set of admin utilities). The kernel is chosen by
   architecture (`linux618` on x86_64, `linux-aarch64`, or `linux-rpi` for Pi
   images) and storage packages by `town-os.yaml`: `linux618-zfs` for the `zfs`
   backend (x86_64 only), `mdadm` for btrfs in `mdadm` raid mode.

4. **Configure the system** — Inside the chroot the configure script:
   - Sets the root password, locale, timezone, and hostname (`town-os`).
   - Builds and installs the ttyforce provisioning TUI from source via Cargo.
   - Runs `mkinitcpio` with the Town OS initrd hooks (installer + squashfs root).
   - Enables systemd services: the system controller (container image set by
     `CONTROLLER_IMAGE`), rolodex DNS, the UI (`UI_IMAGE`), networkd, and
     resolved (with mDNS).
   - Trims the image: firmware is cut to the drivers actually used, the Rust
     toolchain and build dependencies are removed, and translation catalogs,
     man pages, and package docs are stripped.

5. **Install the bootloader** — On x86_64, GRUB is installed for both
   `x86_64-efi` (removable) and `i386-pc`, so the image boots on UEFI and legacy
   BIOS. On aarch64 only `arm64-efi` is installed. Raspberry Pi images use **no
   GRUB at all** — the FAT partition is staged with `kernel8.img`, the
   initramfs, DTBs, overlays, GPU firmware, and a generated `config.txt` /
   `cmdline.txt` for the Pi's own bootloader.

6. **Compress and shrink** — The root filesystem is packed into a gzip squashfs
   (`root.sfs`) on the data partition, and the image is shrunk to its actual
   size. At boot the squashfs is loop-mounted read-only with a tmpfs overlay,
   and persistent state lives on the btrfs pool at `/town-os`.

### Environment variables

| Variable           | Effect                                                        |
|--------------------|---------------------------------------------------------------|
| `CONTROLLER_BASE`  | Repository portion of the controller image (default `quay.io/town/town`) |
| `CONTROLLER_TAG`   | Tag portion of the controller image (default `rc.latest-<arch>`; tags are arch-suffixed, not multi-arch manifests) |
| `CONTROLLER_IMAGE` | Full controller image reference; overrides `CONTROLLER_BASE`/`CONTROLLER_TAG` when set |
| `UI_IMAGE`         | Container image for the UI service                            |
| `DEBUG`            | When non-empty, storage scripts run in debug/dry-run mode     |
| `KEEP_MOUNT`       | When non-empty, skip unmount and USB write; print mount path  |
| `IMAGE_HOSTNAME`   | Set the system hostname and mDNS name (default: `town-os`, i.e. `town-os.local`) |
| `LOCAL_DNS`        | Bypass rolodex DNS; `1` = build host's hostname, other = literal hostname |
| `TTYFORCE_DEV`     | When non-empty, install ttyforce from git HEAD instead of crates.io |
| `TTYFORCE_LATEST`  | When non-empty, install the latest ttyforce from crates.io (ignores version pin) |
| `SERIAL_CONSOLE`   | When non-empty, the image's GRUB defaults to the serial-console entry (headless, no keyboard) |
| `RPI`              | When non-empty, build a native-boot Raspberry Pi image (aarch64 + btrfs only) |
