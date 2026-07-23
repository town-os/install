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
# On an x86_64 host the aarch64/rpi targets are produced via full-system emulation
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
else
$(error unknown TARGET '$(TARGET)' — expected one of: x86_64, aarch64, rpi)
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

# RPI=1 produces a fundamentally different (native-boot Raspberry Pi) image, so
# give it a distinct filename: it is a SEPARATE make target/artifact that coexists
# with the normal UEFI/GRUB image instead of clobbering it. `make image` ->
# town-os-DATE-ARCH.img; `make image RPI=1` -> town-os-DATE-ARCH-rpi.img.
IMAGE            ?= town-os-$(BUILD_DATE)-$(BUILD_ARCH)$(if $(RPI),-rpi).img
IMAGE_SIZE       ?= 12G
# Where the *-log build targets tee their transcript. A build always leaves a
# full log here even when it fails (the recipe captures the exit code through
# the tee pipe). Same shape as town-os's test-full-log.
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
# RPI=1 publishes to a SEPARATE tag (release-$(arch)-rpi) so the Raspberry Pi
# installer image never clobbers the PC one — matching the distinct -rpi image
# filename. The website installer pulls the -rpi tag when given RPI=1.
INSTALLER_BASE   ?= quay.io/town/installer
INSTALLER_TAG    ?= release-$(BUILD_ARCH)$(if $(RPI),-rpi)
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
# vCPUs for the dev VM. QEMU defaults to 1, which starves CPU-count-scaled worker
# pools (e.g. rolodex's tokio runtime); give it several cores so it resolves like
# real hardware. Override with VM_CPUS=N.
VM_CPUS     ?= 4
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

.PHONY: help run run-release stop image image-release build-installer push-installer qemu qemu-fg qemu-usb \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial clean clean-images \
        cleanup-loopback deps deps-debian release flash rebuild-qemu image-container \
        image-log

help:
	@echo 'Town OS Install — Makefile targets'
	@echo
	@echo 'Build:'
	@echo '  image            Build the disk image for TARGET (default: native host arch)'
	@echo '                   TARGET=x86_64|aarch64|rpi; aarch64/rpi emulate on an x86 host'
	@echo '  image-log        Same as image, tee'\''d into a timestamped log under $(LOG_DIR)'
	@echo '  image-container  Force the same-arch Arch container build path (native only)'
	@echo '  image-release    Build the image and compress it to .bz2'
	@echo '  build-installer  Build the installer OCI image from town-os.img.bz2 (no push)'
	@echo '  push-installer   Build then push the installer image (release-$(BUILD_ARCH) + dated tag)'
	@echo '  release          Build, compress, and push the installer image'
	@echo '                   TARGET=x86_64|aarch64|rpi picks the arch/flavor'
	@echo '                   (aarch64/rpi cross-build via emulation on an x86 host)'
	@echo
	@echo 'Run (QEMU):'
	@echo '  qemu             Build if stale, launch QEMU in the background'
	@echo '  qemu-fg          Build if stale, launch QEMU in the foreground (serial attached)'
	@echo '  qemu-usb         Launch QEMU in the foreground from a physical USB (USB_DEV=/dev/sdX); no build'
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
	@echo '  flash            Build if stale, write the image to a USB device'
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
	@echo 'Common variables (override with VAR=value):'
	@echo '  IMAGE=$(IMAGE)'
	@echo '  IMAGE_SIZE=$(IMAGE_SIZE)        VM_DISK_SIZE=$(VM_DISK_SIZE)   VM_MEMORY=$(VM_MEMORY)'
	@echo '  CONTROLLER_IMAGE=$(CONTROLLER_IMAGE)'
	@echo '  IMAGE_HOSTNAME, LOCAL_DNS, TTYFORCE_DEV, TTYFORCE_LATEST, KEEP_MOUNT'
	@echo '  SERIAL_CONSOLE   Set non-empty to default the image to a serial console (no keyboard)'
	@echo '  RPI              Set non-empty to build a native Raspberry Pi image (Pi 4+; aarch64 host only)'
	@echo '  TARGET           image/release arch: x86_64 | aarch64 | rpi (aarch64/rpi emulate on x86)'

rebuild-qemu: stop clean image qemu

run: stop $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

IMAGE_SOURCES := $(wildcard make/install.sh make/image-container.sh make/Containerfile.build \
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
	  'IMAGE_SIZE=$(IMAGE_SIZE)' > $@

# Uses $(IMAGE_BUILDER): the native builder (make/image.sh) normally, or the
# full-system aarch64 emulator (make/image-aarch64.sh) when TARGET requests an
# arch the host can't build natively (EMULATE=1). Both take the same
# "IMAGE_SIZE IMAGE" signature and honor the same env vars.
$(IMAGE): $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) RPI=$(RPI) ${PWD}/$(IMAGE_BUILDER) $(IMAGE_SIZE) $(IMAGE)

# Build the disk image for TARGET (default: native host arch). TARGET=aarch64 or
# TARGET=rpi on an x86_64 host build via full-system emulation automatically.
image: $(IMAGE)

# Same as `image`, tee'd into a timestamped log file under $(LOG_DIR). The log is
# always written even if the build fails: set -o pipefail makes the pipeline fail
# with make's exit status, which we capture in $$rc and re-raise after printing
# the log path, so tee still flushes the full transcript on failure.
image-log:
	@bash -c 'set -o pipefail; mkdir -p "$(LOG_DIR)"; logfile="$(LOG_DIR)/image-$$(date +%s).log"; echo "Logging to: $$logfile"; rc=0; $(MAKE) image 2>&1 | tee "$$logfile" || rc=$$?; echo "Log file: $$logfile"; exit $$rc'

# Force the Arch-container build path regardless of host (install.sh runs inside
# a same-arch Arch container). On non-Arch hosts `make image` already dispatches
# here automatically; this target also lets you force it on an Arch host. The
# container build is NATIVE-only (no emulation), so it can't serve a cross-arch
# TARGET — for that use `make image TARGET=aarch64|rpi`, which emulates.
image-container: $(IMAGE_SOURCES) .build-config
	@[ -z "$(EMULATE)" ] || { echo 'image-container: cannot build a $(BUILD_ARCH) image on a $(HOST_ARCH) host via the container path (native-only); use `make image TARGET=$(TARGET)` for the emulated build'; exit 1; }
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) RPI=$(RPI) ${PWD}/make/image-container.sh $(IMAGE_SIZE) $(IMAGE)

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
qemu-usb:
	@[ -n "$(USB_DEV)" ] || { echo 'error: set USB_DEV=/dev/sdX (the USB block device to boot)'; exit 1; }
	FOREGROUND=1 USB_DEV=$(USB_DEV) VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_CPUS=$(VM_CPUS) VM_BRIDGE=$(VM_BRIDGE) \
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
