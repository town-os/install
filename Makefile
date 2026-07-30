BUILD_DATE       := $(shell date +%Y-%m-%d)
# The REAL host architecture (uname -m). BUILD_ARCH is derived from TARGET below
# and may differ from it (a cross-target build); HOST_ARCH never changes, so the
# build machinery can always tell a native build from an emulated one.
HOST_ARCH        := $(shell uname -m)

# TARGET selects the architecture/flavor for EVERY build target (image,
# image-release, release, qemu, flash, ...). Empty (the default) is a native
# build for the host arch. Recognized values:
#   x86_64 (x86/amd64) native UEFI/GRUB PC image
#   aarch64 (arm64)    aarch64 UEFI/GRUB image — generic Linux / Apple-Silicon VM
#   rpi                aarch64 native-boot Raspberry Pi image (Pi 4/400/CM4, Pi 5/CM5)
#   rg35xxpro          aarch64 SD-card image for the Anbernic RG35XX Pro and the
#                      rest of the Allwinner H700 handheld family (U-Boot in raw
#                      sectors + extlinux; no UEFI, no GRUB)
# On an x86_64 host the aarch64/rpi/rg35xxpro targets are produced via full-system emulation
# (make/image-aarch64.sh — a whole emulated aarch64 MACHINE, NOT binfmt/qemu-user
# and NOT cross-compilation, so "image arch == build-host arch" still holds; the
# build host is simply virtual). An x86_64 target on a non-x86_64 host is rejected
# (there is no x86 emulation path — build it on an x86_64 host).
TARGET ?=

# Derive BUILD_ARCH (and RPI for the Pi flavor) from TARGET. BUILD_ARCH is the
# image's architecture and thus the right suffix for the filename and for every
# arch-suffixed image tag (rc.latest-<arch>, release-<arch>, ...).
ifeq ($(TARGET),)
BUILD_ARCH := $(HOST_ARCH)
else ifneq ($(filter x86_64 x86 amd64,$(TARGET)),)
BUILD_ARCH := x86_64
else ifneq ($(filter aarch64 arm64,$(TARGET)),)
BUILD_ARCH := aarch64
else ifeq ($(TARGET),rpi)
BUILD_ARCH := aarch64
RPI := 1
else ifneq ($(filter rg35xxpro rg35xx-pro rg35xx anbernic,$(TARGET)),)
BUILD_ARCH := aarch64
RG35XX := 1
else
$(error unknown TARGET '$(TARGET)' — expected one of: x86_64, aarch64, rpi, rg35xxpro)
endif

# EMULATE is set when the requested arch differs from the host arch: the image is
# built inside a full-system qemu-system-aarch64 VM (make/image-aarch64.sh)
# instead of the native builder (make/image.sh). Only aarch64 can be emulated; an
# x86_64 image on a non-x86_64 host has no emulation path and is an error. It is a
# derived variable, not a user knob — set TARGET, not EMULATE.
EMULATE :=
ifneq ($(BUILD_ARCH),$(HOST_ARCH))
ifeq ($(BUILD_ARCH),aarch64)
EMULATE := 1
else
$(error cannot build a $(BUILD_ARCH) image on a $(HOST_ARCH) host — no emulation path; build it on a $(BUILD_ARCH) host)
endif
endif

# The image builder: native (make/image.sh) normally, or the full-system aarch64
# emulator (make/image-aarch64.sh) for a cross-arch build. Both take the same
# "IMAGE_SIZE IMAGE" signature and honor the same env vars.
IMAGE_BUILDER := $(if $(EMULATE),make/image-aarch64.sh,make/image.sh)

# RPI=1 and RG35XX=1 each produce a fundamentally different (native-boot) image,
# so each gets a distinct filename: they are SEPARATE make targets/artifacts that
# coexist with the normal UEFI/GRUB image instead of clobbering it. `make image`
# -> town-os-DATE-ARCH.img; `make image RPI=1` -> town-os-DATE-ARCH-rpi.img;
# `make image TARGET=rg35xxpro` -> town-os-DATE-aarch64-rg35xxpro.img.
IMAGE_FLAVOR     := $(if $(RPI),-rpi)$(if $(RG35XX),-rg35xxpro)
IMAGE            ?= town-os-$(BUILD_DATE)-$(BUILD_ARCH)$(IMAGE_FLAVOR).img
IMAGE_SIZE       ?= 12G
# Where the *-log build targets tee their transcript (`make image-log`, and any
# other `make <target>-log` — see the %-log pattern rule). A build always leaves
# a full log here even when it fails: the recipe captures the exit code through
# the tee pipe. Same facility as town-os's `test-full-log`.
LOG_DIR          ?= /tmp/town-os-install/log
# Image tags are arch-suffixed (rc.latest-x86_64 / rc.latest-aarch64): each
# repository publishes per-arch tags rather than a multi-arch manifest. Builds
# are always native, so BUILD_ARCH is the right suffix for everything pulled.
CONTROLLER_BASE  ?= quay.io/town/town
CONTROLLER_TAG   ?= rc.latest-$(BUILD_ARCH)
CONTROLLER_IMAGE ?= $(CONTROLLER_BASE):$(CONTROLLER_TAG)
ROLODEX_IMAGE    ?= quay.io/town/rolodex:$(lastword $(subst :, ,$(CONTROLLER_IMAGE)))
UI_IMAGE         ?= quay.io/town/ui:rc.latest-$(BUILD_ARCH)
# The installer image carries the compressed USB image (town-os.img.bz2) for the
# website's curl|bash installer. Same arch-suffixed tag scheme as the others:
# `make push-installer` publishes release-$(arch) (rolling) plus a dated tag.
# Each native-boot flavor publishes to a SEPARATE tag (release-$(arch)-rpi,
# release-$(arch)-rg35xxpro) so it never clobbers the PC one — matching the
# distinct image filename. The website installer pulls the -rpi tag when given
# RPI=1.
INSTALLER_BASE   ?= quay.io/town/installer
INSTALLER_TAG    ?= release-$(BUILD_ARCH)$(IMAGE_FLAVOR)
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
# vCPUs for the VMs (the dev VM and the emulated cross-arch build VM both take it).
# QEMU defaults to 1, which starves CPU-count-scaled worker pools (e.g. rolodex's
# tokio runtime) and leaves an emulated build's rustc/kernel compile single-file.
# Default to three quarters of the host's cores: enough to behave like real
# multi-core hardware, while leaving the host responsive (under TCG each vCPU is a
# busy emulation thread). Falls back to 4 if nproc is unavailable, floors at 1.
# Override with VM_CPUS=N.
VM_CPUS     ?= $(shell n=$$(nproc 2>/dev/null || echo 4); c=$$(( n / 4 * 3 )); if [ "$$c" -lt 1 ]; then c=1; fi; echo "$$c")
VM_BRIDGE   ?= virbr0
VM_NAME     ?= town-os
# Pin the VM to a specific IP via a libvirt DHCP reservation. Defaults to .50 on
# the default network. Override with any address in that subnet, e.g.
# VM_IP=192.168.122.77. Running multiple VMs at once? Give each its own VM_IP —
# two VMs sharing one VM_IP collide and the second falls back to a dynamic lease.
# (If unset/out-of-subnet, qemu.sh derives a stable IP from VM_NAME instead.)
VM_IP       ?= 192.168.122.50
# IPv6 ULA /64 added to the libvirt default network so the guest gets an IPv6
# address (SLAAC) alongside its NAT'd IPv4 — lets rolodex/Town OS be set up over
# IPv6 too. `::1` is the gateway; the guest auto-derives a stable EUI-64 address
# from its MAC. Set empty to disable. VM_IP6 overrides the printed guest address.
VM_NET6_PREFIX ?= fd00:c0a8:7a
VM_IP6      ?=

# Expose the NAT'd VM to the LAN so other devices on the wireless network (a
# phone running the Town OS client) can reach it: socat relays the control API
# (5309), the UI (80/443) and ssh (2222) from the host's LAN address to the
# guest, and a DNAT range rule forwards the WireGuard UDP ports (51820-55915) so
# every custom network works. See make/vm-relay.sh. On by default; turn it off
# with VM_LAN=0.
VM_LAN ?= 1
FOREGROUND  ?=
LOCAL_DNS   ?=
# Physical USB block device to boot with `make qemu-usb` (e.g. /dev/sda).
USB_DEV     ?=
# Pass a physical phone through to the guest over USB. This is passthrough of a
# LIVE device, not a disk to boot from (that's USB_DEV above).
#   make qemu USB_PHONE=auto          # find the attached Android device
#   make qemu USB_PHONE=18d1:4ee1     # by vendor:product
#   make qemu USB_PHONE=1.1           # by physical bus.port
# The phone leaves the host while the VM holds it (adb on the host stops seeing
# it). Enable USB tethering on the phone and the box gets a direct network link
# to it -- no libvirt NAT in the path.
USB_PHONE   ?=
# Pass a real game controller through to the guest for `make qemu-usb`. The
# RG35XX installer is gamepad-driven (its on-screen keyboard is the only way to
# type on that device), so an RG35XX guest auto-detects one; other targets only
# use a pad if given an explicit /dev/input/eventN. GAMEPAD=0 disables. The host
# loses the controller while the VM holds it.
GAMEPAD     ?=
# When non-empty, the built image's GRUB defaults to the serial-console entry
# (console=ttyS0,115200) so the machine boots headless with no keyboard/monitor.
SERIAL_CONSOLE ?=

# RPI=1 is shorthand for TARGET=rpi's Pi flavor on a native aarch64 host: a
# native-boot Raspberry Pi image (Pi 4/400/CM4, Pi 5/CM5) — linux-rpi kernel + GPU
# firmware + config.txt on the FAT partition, no GRUB. It is aarch64-only and gives
# the image a distinct -rpi filename so it coexists with the UEFI/GRUB image
# instead of clobbering it. To cross-build a Pi image on an x86_64 host use
# TARGET=rpi (which sets RPI=1 and emulates); bare RPI=1 stays native (aarch64
# host only). TARGET=rpi and RPI=1 both flow: `make image` -> town-os-DATE-arch.img,
# with the Pi flavor -> town-os-DATE-aarch64-rpi.img.
RPI ?=

# RG35XX=1 (what TARGET=rg35xxpro sets) builds the Anbernic RG35XX Pro SD image:
# an Allwinner H700 box has no onboard firmware, so the image carries a
# bootloader — mainline U-Boot + TF-A, compiled during the build and written into
# the card's raw sectors — and boots via extlinux instead of UEFI/GRUB. Like
# RPI=1 it is aarch64-only and btrfs-only, and gives the image a distinct
# -rg35xxpro filename. Bare RG35XX=1 builds natively (aarch64 host only); use
# TARGET=rg35xxpro to cross-build one on x86_64 (emulated, like TARGET=rpi).
RG35XX ?=
# Device tree for the RG35XX build. Mainline has no rg35xx-pro DT; the -h DT is
# the closest superset (see make/install.sh). Any of the four staged H700 DTBs
# works here, as does an absolute path to a .dtb from another distro.
RG35XX_DTB ?=
# Skip the in-chroot U-Boot build and use this prebuilt u-boot-sunxi-with-spl.bin.
UBOOT_BIN ?=
# DRAM type of the target unit: lpddr4 (default) or lpddr3. H700 handhelds
# shipped with both; the wrong one means the board never powers up. Both
# bootloaders are staged on the card so the other can be written by hand.
RG35XX_DRAM ?=

.PHONY: help run run-release stop image image-release compress-release build-installer push-installer qemu qemu-fg qemu-usb \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial clean clean-images \
        cleanup-loopback deps deps-debian release flash rebuild-qemu image-container
# NOTE: no *-log target may be listed above. `make <target>-log` is served by the
# `%-log` pattern rule (below, next to `image:`), and GNU make skips the
# implicit-rule search entirely for .PHONY targets — listing image-log here makes
# it match nothing and fail with "No rule to make target 'image-log'".

help:
	@echo 'Town OS Install — Makefile targets'
	@echo
	@echo 'Build:'
	@echo '  image            Build the disk image for TARGET (default: native host arch)'
	@echo '                   TARGET=x86_64|aarch64|rpi|rg35xxpro; non-x86 targets emulate'
	@echo '                   on an x86 host'
	@echo '  <target>-log     Any build target, tee'\''d into a timestamped log under $(LOG_DIR)'
	@echo '                   (image-log, image-release-log, release-log, ...); the log is'
	@echo '                   kept when the build fails, and named for the arch/flavor'
	@echo '  image-container  Force the same-arch Arch container build path (native only)'
	@echo '  image-release    Build the image and compress it to .bz2'
	@echo '  build-installer  Build the installer OCI image from town-os.img.bz2 (no push)'
	@echo '  push-installer   Build then push the installer image (release-$(BUILD_ARCH) + dated tag)'
	@echo '  release          Build, compress, and push the installer image'
	@echo '                   TARGET=x86_64|aarch64|rpi|rg35xxpro picks the arch/flavor'
	@echo '                   (non-x86 targets cross-build via emulation on an x86 host)'
	@echo
	@echo 'Run (QEMU):'
	@echo '  qemu             Build if stale, launch QEMU in the background'
	@echo '  qemu-fg          Build if stale, launch QEMU in the foreground (serial attached)'
	@echo '  qemu-usb         Launch QEMU in the foreground from a physical USB (USB_DEV=/dev/sdX); no build'
	@echo '                   TARGET=aarch64|rpi|rg35xxpro emulates a foreign-arch stick on x86'
	@echo '  run              Build if stale, launch a libvirt-managed VM'
	@echo '  rebuild-qemu     stop + clean + image + qemu'
	@echo '  serial           Attach to a running QEMU serial console (Ctrl-] to detach)'
	@echo '  vm-ip            Print the IP address of the running VM'
	@echo
	@echo 'Run (VirtualBox):'
	@echo '  virtualbox       Build if stale, launch a VirtualBox VM in the background'
	@echo '  virtualbox-fg    Build if stale, launch a VirtualBox VM in the foreground'
	@echo
	@echo 'Flash:'
	@echo '  flash            Build if stale, write the image to a USB device (USB_DEV=/dev/sdX)'
	@echo
	@echo 'Stop:'
	@echo '  stop             Stop all VMs for this image/name'
	@echo '  stop-qemu        Stop the QEMU VM only'
	@echo '  stop-virtualbox  Stop the VirtualBox VM only'
	@echo
	@echo 'Clean:'
	@echo '  clean            Stop VMs and remove the current image and VM disks'
	@echo '  clean-images     Remove all built images (*.img, *.img.bz2, image.raw)'
	@echo '  cleanup-loopback Detach stale loopback devices left by a failed build'
	@echo
	@echo 'Host dependencies (manual only):'
	@echo '  deps             Install host dependencies on Arch or Fedora'
	@echo '  deps-debian      Install host dependencies on Debian/Ubuntu'
	@echo
	@echo 'Aliases:'
	@echo '  compress-release = image-release; run-release = run;'
	@echo '  qemu-release = qemu; virtualbox-release = virtualbox'
	@echo
	@echo 'Build variables (override with VAR=value):'
	@echo '  TARGET           Arch/flavor for every build target:'
	@echo '                   x86_64 | aarch64 | rpi | rg35xxpro'
	@echo '                   (empty = native host arch; non-x86 emulate on an x86 host)'
	@echo '  RPI              Non-empty builds a native-boot Raspberry Pi image (Pi 4/400/CM4,'
	@echo '                   Pi 5/CM5): linux-rpi + config.txt, no GRUB. aarch64 host only —'
	@echo '                   use TARGET=rpi to cross-build one on x86_64'
	@echo '  RG35XX           Non-empty builds an Anbernic RG35XX Pro (Allwinner H700) SD'
	@echo '                   image: U-Boot built into the raw sectors + extlinux, no GRUB.'
	@echo '                   aarch64 host only — use TARGET=rg35xxpro to cross-build on x86'
	@echo '  RG35XX_DTB       Device tree for the RG35XX image (default: the Pro DT this'
	@echo '                   repo carries in dts/). A .dtb name or an absolute path'
	@echo '  RG35XX_DRAM      lpddr4 (default) or lpddr3 — must match the unit'
	@echo '  UBOOT_BIN        Use this prebuilt u-boot-sunxi-with-spl.bin instead of building'
	@echo '                   U-Boot during the image build'
	@echo '  SERIAL_CONSOLE   Non-empty defaults the built image to the serial-console GRUB'
	@echo '                   entry, so it boots headless with no keyboard/monitor'
	@echo '  IMAGE            = $(IMAGE)'
	@echo '  IMAGE_SIZE       = $(IMAGE_SIZE)  (sparse build size; the image is shrunk afterwards)'
	@echo '  IMAGE_HOSTNAME   Hostname and mDNS name baked into the image (default: town-os)'
	@echo '  LOCAL_DNS        Dev DNS override (1 = auto, or a literal hostname); skips rolodex'
	@echo '  CONTROLLER_IMAGE = $(CONTROLLER_IMAGE)'
	@echo '                   (compose it instead with CONTROLLER_BASE / CONTROLLER_TAG;'
	@echo '                    ROLODEX_IMAGE and UI_IMAGE follow the same arch-suffixed tag)'
	@echo '  TTYFORCE_DEV     Non-empty installs ttyforce from git instead of crates.io'
	@echo '  TTYFORCE_LATEST  Non-empty installs the latest crates.io ttyforce (ignores the pin)'
	@echo '  KEEP_MOUNT       Non-empty skips the unmount after install, for debugging'
	@echo '  LOG_DIR          = $(LOG_DIR)  (where <target>-log tees its transcript)'
	@echo '  BASE_IMAGE       Arch base image for the container build path (env var)'
	@echo '  BUILD_MIRROR     Pacman mirror for the container build; defaults to a US mirror (env var)'
	@echo
	@echo 'Release variables:'
	@echo '  INSTALLER_BASE   = $(INSTALLER_BASE)'
	@echo '  INSTALLER_TAG    = $(INSTALLER_TAG)  (push-installer also pushes a dated tag)'
	@echo
	@echo 'VM variables:'
	@echo '  VM_NAME          = $(VM_NAME)'
	@echo '  VM_BRIDGE        = $(VM_BRIDGE)'
	@echo '  VM_MEMORY        = $(VM_MEMORY)'
	@echo '  VM_CPUS          = $(VM_CPUS)  (3/4 of the host'\''s cores; dev VM and the emulated build VM)'
	@echo '  VM_DISK_SIZE     = $(VM_DISK_SIZE)  (each of the four data disks)'
	@echo '  VM_IP            = $(VM_IP)  (libvirt DHCP reservation;'
	@echo '                   give each concurrently-running VM its own address)'
	@echo '  VM_NET6_PREFIX   = $(VM_NET6_PREFIX)  ULA /64 giving the guest IPv6 via SLAAC;'
	@echo '                   empty disables. Only offered when the host itself reaches the'
	@echo '                   v6 internet — VM_NET6_FORCE=1 skips that probe, VM_IP6'
	@echo '                   overrides the printed guest address'
	@echo '  VM_LAN           = $(VM_LAN)  Expose the NAT'\''d guest to the LAN so a phone on the'
	@echo '                   same wireless network can reach it (socat TCP relays + WireGuard'
	@echo '                   UDP DNAT). VM_LAN=0 disables; VM_RELAY_TCP overrides the port'
	@echo '                   map (default: 5309 80 443 2222:22)'
	@echo '  USB_DEV          Physical USB block device for flash (write) and qemu-usb (read-only boot)'
	@echo '  GAMEPAD          Game controller for qemu-usb: auto (RG35XX only) | /dev/input/eventN'
	@echo '                   | 0. The host loses the pad while the VM holds it'
	@echo '  USB_PHONE        Pass a live phone through to the guest: auto | vid:pid | bus.port'
	@echo '                   (the host loses the phone, adb included, while the VM holds it)'
	@echo '  FOREGROUND       Non-empty runs the VM in the foreground (what qemu-fg sets)'

rebuild-qemu: stop clean image qemu

run: stop $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

IMAGE_SOURCES := $(wildcard make/install.sh make/image-container.sh make/Containerfile.build \
                           dts/*.dts \
                           make/image-aarch64.sh make/image-aarch64-guest.sh \
                           scripts/*.sh systemd/*.service systemd/*.timer \
                           initcpio/hooks/* initcpio/install/* town-os.yaml Makefile)

# Rebuild the image when build-relevant variables change.
# The stamp file is always re-evaluated but only touched when content differs.
FORCE:
.build-config: FORCE
	@printf '%s\n' \
	  'CONTROLLER_IMAGE=$(CONTROLLER_IMAGE)' \
	  'ROLODEX_IMAGE=$(ROLODEX_IMAGE)' \
	  'UI_IMAGE=$(UI_IMAGE)' \
	  'TTYFORCE_DEV=$(TTYFORCE_DEV)' \
	  'TTYFORCE_LATEST=$(TTYFORCE_LATEST)' \
	  'IMAGE_HOSTNAME=$(IMAGE_HOSTNAME)' \
	  'LOCAL_DNS=$(LOCAL_DNS)' \
	  'SERIAL_CONSOLE=$(SERIAL_CONSOLE)' \
	  'RPI=$(RPI)' \
	  'RG35XX=$(RG35XX)' \
	  'RG35XX_DTB=$(RG35XX_DTB)' \
	  'RG35XX_DRAM=$(RG35XX_DRAM)' \
	  'UBOOT_BIN=$(UBOOT_BIN)' \
	  'IMAGE_SIZE=$(IMAGE_SIZE)' | cmp -s - $@ || \
	printf '%s\n' \
	  'CONTROLLER_IMAGE=$(CONTROLLER_IMAGE)' \
	  'ROLODEX_IMAGE=$(ROLODEX_IMAGE)' \
	  'UI_IMAGE=$(UI_IMAGE)' \
	  'TTYFORCE_DEV=$(TTYFORCE_DEV)' \
	  'TTYFORCE_LATEST=$(TTYFORCE_LATEST)' \
	  'IMAGE_HOSTNAME=$(IMAGE_HOSTNAME)' \
	  'LOCAL_DNS=$(LOCAL_DNS)' \
	  'SERIAL_CONSOLE=$(SERIAL_CONSOLE)' \
	  'RPI=$(RPI)' \
	  'RG35XX=$(RG35XX)' \
	  'RG35XX_DTB=$(RG35XX_DTB)' \
	  'RG35XX_DRAM=$(RG35XX_DRAM)' \
	  'UBOOT_BIN=$(UBOOT_BIN)' \
	  'IMAGE_SIZE=$(IMAGE_SIZE)' > $@

# Uses $(IMAGE_BUILDER): the native builder (make/image.sh) normally, or the
# full-system aarch64 emulator (make/image-aarch64.sh) when TARGET requests an
# arch the host can't build natively (EMULATE=1). Both take the same
# "IMAGE_SIZE IMAGE" signature and honor the same env vars.
#
# VM_CPUS is passed for the EMULATE=1 path: the emulated build VM runs
# multi-threaded TCG, so its -smp genuinely scales the (dominant) rustc and kernel
# compiles. The native builder ignores it. VM_MEMORY is deliberately NOT passed —
# the build VM's own 8G default is sized for rustc/LLVM link peaks and must not be
# overwritten by the dev VM's smaller default; set it explicitly to change it.
$(IMAGE): $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) RPI=$(RPI) RG35XX=$(RG35XX) RG35XX_DTB=$(RG35XX_DTB) RG35XX_DRAM=$(RG35XX_DRAM) UBOOT_BIN=$(UBOOT_BIN) VM_CPUS=$(VM_CPUS) ${PWD}/$(IMAGE_BUILDER) $(IMAGE_SIZE) $(IMAGE)

# Build the disk image for TARGET (default: native host arch). TARGET=aarch64 or
# TARGET=rpi on an x86_64 host build via full-system emulation automatically.
image: $(IMAGE)

# `make <target>-log` runs `make <target>` with the whole transcript tee'd into a
# timestamped file under $(LOG_DIR) — `make image-log`, `make image-release-log`,
# `make release-log`, `make image-container-log`. Same facility as town-os's
# `test-full-log`, generalized to a pattern rule so a new build target gets its
# logged variant for free.
#
# The log is always written even when the build FAILS, which is the case that
# matters: `set -o pipefail` makes the pipeline carry make's exit status rather
# than tee's, so it is captured in $$rc, the path is printed, and only then is
# the failure re-raised — tee has already flushed the full transcript by then.
#
# The name carries the arch/flavor, so an emulated `TARGET=rg35xxpro` run and a
# native x86_64 run of the same target don't leave two indistinguishable logs
# (they take completely different code paths and fail in completely different
# ways). The timestamp is sortable rather than epoch seconds so `ls` orders the
# runs, and a `<target>-<arch><flavor>-latest.log` symlink tracks the newest —
# keyed the same way, so tailing an rg35xxpro build isn't hijacked by a native
# build started next to it.
#
# That symlink is placed BEFORE the build runs, not after: its whole purpose is
# `tail -F $(LOG_DIR)/image-aarch64-rg35xxpro-latest.log` from another terminal
# while the build is still going, which is how you watch an emulated build that
# takes hours. tee creates the file immediately, so there is nothing to race.
#
# stdin is deliberately left alone: the emulated build hands the guest's serial
# console our stdin (make/image-aarch64.sh), so a build under this wrapper is
# still typeable if something unforeseen asks a question.
#
# Pattern rules are skipped for .PHONY targets, so nothing matched by this may be
# listed there.
%-log:
	@bash -c 'set -o pipefail; \
	  mkdir -p "$(LOG_DIR)"; \
	  stem="$*-$(BUILD_ARCH)$(IMAGE_FLAVOR)"; \
	  logfile="$(LOG_DIR)/$$stem-$$(date +%Y%m%d-%H%M%S).log"; \
	  : > "$$logfile"; \
	  ln -sfn "$$logfile" "$(LOG_DIR)/$$stem-latest.log"; \
	  echo "Logging to: $$logfile"; \
	  echo "Follow it with: tail -F $(LOG_DIR)/$$stem-latest.log"; \
	  rc=0; $(MAKE) $* 2>&1 | tee "$$logfile" || rc=$$?; \
	  echo "Log file: $$logfile"; \
	  exit $$rc'

# Force the Arch-container build path regardless of host (install.sh runs inside
# a same-arch Arch container). On non-Arch hosts `make image` already dispatches
# here automatically; this target also lets you force it on an Arch host. The
# container build is NATIVE-only (no emulation), so it can't serve a cross-arch
# TARGET — for that use `make image TARGET=aarch64|rpi`, which emulates.
image-container: $(IMAGE_SOURCES) .build-config
	@[ -z "$(EMULATE)" ] || { echo 'image-container: cannot build a $(BUILD_ARCH) image on a $(HOST_ARCH) host via the container path (native-only); use `make image TARGET=$(TARGET)` for the emulated build'; exit 1; }
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) RPI=$(RPI) RG35XX=$(RG35XX) RG35XX_DTB=$(RG35XX_DTB) RG35XX_DRAM=$(RG35XX_DRAM) UBOOT_BIN=$(UBOOT_BIN) ${PWD}/make/image-container.sh $(IMAGE_SIZE) $(IMAGE)

# Compressed release image, as a real file target so it is NOT rebuilt when the
# .bz2 is already fresh. It depends on the image's *sources* rather than on
# $(IMAGE): the raw image is deleted right after compression to save disk, so a
# dependency on $(IMAGE) would see it missing and force a needless second image
# build every time. The recipe (re)builds the raw image only if its own sources
# changed, then compresses and removes it.
$(IMAGE).bz2: $(IMAGE_SOURCES) .build-config
	$(MAKE) $(IMAGE)
	sudo pv $(IMAGE) | lbzip2 > $@ && rm -f $(IMAGE)

compress-release: $(IMAGE).bz2

image-release: $(IMAGE).bz2

# Build a scratch image holding town-os.img.bz2, tagged release-$(BUILD_ARCH)
# (rolling) and release-$(BUILD_ARCH)-$(date) (immutable). Depends on the
# compressed image file so it is built once if stale and reused if already
# fresh (no double image build). Builds as root, like the rest of the build
# tooling. Does NOT compress the disk image itself.
build-installer: $(IMAGE).bz2
	INSTALLER_BASE=$(INSTALLER_BASE) INSTALLER_TAG=$(INSTALLER_TAG) IMAGE=$(IMAGE) \
	  ${PWD}/make/push-installer.sh build

# Push the (already built) installer image to the registry. Depends on
# build-installer, so `make push-installer` builds then pushes — same shape as
# `image-release: image compress-release`.
push-installer: build-installer
	INSTALLER_BASE=$(INSTALLER_BASE) INSTALLER_TAG=$(INSTALLER_TAG) IMAGE=$(IMAGE) \
	  ${PWD}/make/push-installer.sh push

run-release: run
qemu-release: qemu
virtualbox-release: virtualbox

qemu: $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) USB_PHONE=$(USB_PHONE) VM_NET6_PREFIX=$(VM_NET6_PREFIX) VM_IP6=$(VM_IP6) IMAGE=$(IMAGE) \
	  VM_LAN=$(VM_LAN) \
	  ${PWD}/make/qemu.sh $(IMAGE)

qemu-fg: $(IMAGE)
	FOREGROUND=1 VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) USB_PHONE=$(USB_PHONE) VM_NET6_PREFIX=$(VM_NET6_PREFIX) VM_IP6=$(VM_IP6) \
	  VM_LAN=$(VM_LAN) \
	  ${PWD}/make/qemu.sh $(IMAGE)

# Boot QEMU (foreground) from a PHYSICAL USB device instead of the built image.
# Does NOT build an image — point USB_DEV at the flashed stick, e.g.:
#   make qemu-usb USB_DEV=/dev/sda
# The device is opened read-only (snapshot): guest writes are discarded, so the
# real USB is never modified. The four data disks (disk0-3.img) are still used.
#
# TARGET selects the guest ARCHITECTURE (via BUILD_ARCH): with no TARGET the
# stick boots natively (KVM). TARGET=aarch64 (or rpi) on an x86_64 host boots the
# stick under full-system qemu-system-aarch64 emulation (no KVM, slow) so an
# aarch64 image can be tested without aarch64 hardware, e.g.:
#   make qemu-usb TARGET=aarch64 USB_DEV=/dev/sda
qemu-usb:
	@[ -n "$(USB_DEV)" ] || { echo 'error: set USB_DEV=/dev/sdX (the USB block device to boot)'; exit 1; }
	FOREGROUND=1 USB_DEV=$(USB_DEV) QEMU_ARCH=$(BUILD_ARCH) RPI=$(RPI) RG35XX=$(RG35XX) GAMEPAD=$(GAMEPAD) VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) USB_PHONE=$(USB_PHONE) VM_NET6_PREFIX=$(VM_NET6_PREFIX) VM_IP6=$(VM_IP6) ${PWD}/make/qemu.sh $(USB_DEV)

stop:
	IMAGE=$(IMAGE) VM_NAME=$(VM_NAME) ${PWD}/make/stop.sh

stop-qemu:
	IMAGE=$(IMAGE) ${PWD}/make/stop-qemu.sh

virtualbox: $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_BRIDGE=$(VM_BRIDGE) VM_NAME=$(VM_NAME) \
	  ${PWD}/make/virtualbox.sh $(IMAGE)

virtualbox-fg: $(IMAGE)
	FOREGROUND=1 VM_DISK_SIZE=$(VM_DISK_SIZE) VM_BRIDGE=$(VM_BRIDGE) VM_NAME=$(VM_NAME) \
	  ${PWD}/make/virtualbox.sh $(IMAGE)

stop-virtualbox:
	VM_NAME=$(VM_NAME) ${PWD}/make/stop-virtualbox.sh

vm-ip:
	VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) ${PWD}/make/vm-ip.sh

serial:
	${PWD}/make/serial.sh

clean: stop
	IMAGE=$(IMAGE) VM_NAME=$(VM_NAME) ${PWD}/make/clean.sh

deps:
	${PWD}/make/deps.sh

deps-debian:
	${PWD}/make/deps-debian.sh

clean-images:
	rm -f town-os-*.img town-os-*.img.bz2 image.raw

cleanup-loopback:
	${PWD}/make/cleanup-loopback.sh

flash: $(IMAGE)
	${PWD}/make/flash.sh $(IMAGE)

# Build, compress, and push the installer image for TARGET (default: native host
# arch, honoring RPI=1). TARGET is resolved at the top of this Makefile into
# BUILD_ARCH / RPI / EMULATE, so the whole chain (push-installer -> build-installer
# -> $(IMAGE).bz2 -> $(IMAGE)) already targets the right arch/flavor — including
# the emulated aarch64/rpi cross-build on an x86_64 host — with no re-entry here.
release: push-installer
