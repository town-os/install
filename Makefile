BUILD_DATE       := $(shell date +%Y-%m-%d)
# Builds are always native, so the host arch (uname -m) is the image arch. Tag
# the filename with it so x86_64 and aarch64 images don't get confused.
BUILD_ARCH       := $(shell uname -m)
IMAGE            ?= town-os-$(BUILD_DATE)-$(BUILD_ARCH).img
IMAGE_SIZE       ?= 12G
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
INSTALLER_BASE   ?= quay.io/town/installer
INSTALLER_TAG    ?= release-$(BUILD_ARCH)
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
VM_BRIDGE   ?= virbr0
VM_NAME     ?= town-os
# Pin the VM to a specific IP via a libvirt DHCP reservation. Defaults to .50 on
# the default network. Override with any address in that subnet, e.g.
# VM_IP=192.168.122.77. Running multiple VMs at once? Give each its own VM_IP —
# two VMs sharing one VM_IP collide and the second falls back to a dynamic lease.
# (If unset/out-of-subnet, qemu.sh derives a stable IP from VM_NAME instead.)
VM_IP       ?= 192.168.122.50
FOREGROUND  ?=
LOCAL_DNS   ?=
# Physical USB block device to boot with `make qemu-usb` (e.g. /dev/sda).
USB_DEV     ?=
# When non-empty, the built image's GRUB defaults to the serial-console entry
# (console=ttyS0,115200) so the machine boots headless with no keyboard/monitor.
SERIAL_CONSOLE ?=

.PHONY: help run run-release stop image image-x86_64 image-release build-installer push-installer qemu qemu-fg qemu-usb \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial lan-proxy clean clean-images \
        cleanup-loopback deps deps-debian release flash rebuild-qemu image-container

help:
	@echo 'Town OS Install — Makefile targets'
	@echo
	@echo 'Build:'
	@echo '  image            Build the disk image (native on Arch, else same-arch Arch container)'
	@echo '  image-x86_64     Cross-build an x86_64 image on a non-x86_64 host (EMULATED, slow)'
	@echo '  image-container  Force the same-arch Arch container build path (any host)'
	@echo '  image-release    Build the image and compress it to .bz2'
	@echo '  build-installer  Build the installer OCI image from town-os.img.bz2 (no push)'
	@echo '  push-installer   Build then push the installer image (release-$(BUILD_ARCH) + dated tag)'
	@echo '  release          Build, compress, and push the installer image'
	@echo
	@echo 'Run (QEMU):'
	@echo '  qemu             Build if stale, launch QEMU in the background'
	@echo '  qemu-fg          Build if stale, launch QEMU in the foreground (serial attached)'
	@echo '  qemu-usb         Launch QEMU in the foreground from a physical USB (USB_DEV=/dev/sdX); no build'
	@echo '  run              Build if stale, launch a libvirt-managed VM'
	@echo '  rebuild-qemu     stop + clean + image + qemu'
	@echo '  serial           Attach to a running QEMU serial console (Ctrl-] to detach)'
	@echo '  vm-ip            Print the IP address of the running VM'
	@echo '  lan-proxy        Expose the running VM to the LAN as <hostname>.local (mDNS alias + port relays)'
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

rebuild-qemu: stop clean image qemu

run: stop $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

IMAGE_SOURCES := $(wildcard make/install.sh make/image-container.sh make/Containerfile.build \
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
	  'IMAGE_SIZE=$(IMAGE_SIZE)' > $@

$(IMAGE): $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) TARGET_ARCH=$(BUILD_ARCH) ${PWD}/make/image.sh $(IMAGE_SIZE) $(IMAGE)

image: $(IMAGE)

# Cross-build an x86_64 image on a non-x86_64 host under EMULATION (binfmt +
# qemu-user-static — slow). Recursive make so BUILD_ARCH=x86_64 renames the image
# file and threads through the arch-suffixed tags. On an x86_64 host this is just
# the normal native build.
image-x86_64:
	$(MAKE) image BUILD_ARCH=x86_64

# Force the Arch-container build path regardless of host (install.sh runs inside
# an Arch container). On non-Arch hosts `make image` already dispatches here
# automatically; this target also lets you force it on an Arch host.
image-container: $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) TARGET_ARCH=$(BUILD_ARCH) ${PWD}/make/image-container.sh $(IMAGE_SIZE) $(IMAGE)

compress-release:
	sudo pv $(IMAGE) | lbzip2 > $(IMAGE).bz2 && rm -f $(IMAGE)

image-release: image compress-release

# Build a scratch image holding town-os.img.bz2, tagged release-$(BUILD_ARCH)
# (rolling) and release-$(BUILD_ARCH)-$(date) (immutable). Requires the compressed
# image to exist (run image-release first). Builds as root, like the rest of the
# build tooling. Does NOT compress the disk image itself.
build-installer:
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
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) IMAGE=$(IMAGE) \
	  ${PWD}/make/qemu.sh $(IMAGE)

qemu-fg: $(IMAGE)
	FOREGROUND=1 VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) \
	  ${PWD}/make/qemu.sh $(IMAGE)

# Boot QEMU (foreground) from a PHYSICAL USB device instead of the built image.
# Does NOT build an image — point USB_DEV at the flashed stick, e.g.:
#   make qemu-usb USB_DEV=/dev/sda
# The device is opened read-only (snapshot): guest writes are discarded, so the
# real USB is never modified. The four data disks (disk0-3.img) are still used.
qemu-usb:
	@[ -n "$(USB_DEV)" ] || { echo 'error: set USB_DEV=/dev/sdX (the USB block device to boot)'; exit 1; }
	FOREGROUND=1 USB_DEV=$(USB_DEV) VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) VM_IP=$(VM_IP) ${PWD}/make/qemu.sh $(USB_DEV)

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

# Expose the running NAT'd VM to the LAN: avahi alias <IMAGE_HOSTNAME>.local ->
# host IP + socat TCP relays to the guest. Foreground; Ctrl-C stops and cleans
# up. Must NOT depend on $(IMAGE) — it must never trigger a build.
lan-proxy:
	VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) \
	  ${PWD}/make/lan-proxy.sh

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

release: image-release push-installer
