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
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
VM_BRIDGE   ?= virbr0
VM_NAME     ?= town-os
FOREGROUND  ?=
LOCAL_DNS   ?=
# Physical USB block device to boot with `make qemu-usb` (e.g. /dev/sda).
USB_DEV     ?=
# When non-empty, the built image's GRUB defaults to the serial-console entry
# (console=ttyS0,115200) so the machine boots headless with no keyboard/monitor.
SERIAL_CONSOLE ?=

.PHONY: help run run-release stop image image-release qemu qemu-fg qemu-usb \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial clean clean-images \
        cleanup-loopback deps deps-debian release flash rebuild-qemu image-container

help:
	@echo 'Town OS Install — Makefile targets'
	@echo
	@echo 'Build:'
	@echo '  image            Build the disk image (native on Arch, else same-arch Arch container)'
	@echo '  image-container  Force the same-arch Arch container build path (any host)'
	@echo '  image-release    Build the image and compress it to .bz2'
	@echo '  release          Build, compress, and publish a release'
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
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) ${PWD}/make/image.sh $(IMAGE_SIZE) $(IMAGE)

image: $(IMAGE)

# Force the Arch-container build path regardless of host (install.sh runs inside
# an x86_64 Arch container). On non-Arch hosts `make image` already dispatches
# here automatically; this target also lets you force it on an Arch host.
image-container: $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) SERIAL_CONSOLE=$(SERIAL_CONSOLE) ${PWD}/make/image-container.sh $(IMAGE_SIZE) $(IMAGE)

compress-release:
	sudo pv $(IMAGE) | lbzip2 > $(IMAGE).bz2 && rm -f $(IMAGE)

image-release: image compress-release

run-release: run
qemu-release: qemu
virtualbox-release: virtualbox

qemu: $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) \
	  ${PWD}/make/qemu.sh $(IMAGE)

qemu-fg: $(IMAGE)
	FOREGROUND=1 VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  ${PWD}/make/qemu.sh $(IMAGE)

# Boot QEMU (foreground) from a PHYSICAL USB device instead of the built image.
# Does NOT build an image — point USB_DEV at the flashed stick, e.g.:
#   make qemu-usb USB_DEV=/dev/sda
# The device is opened read-only (snapshot): guest writes are discarded, so the
# real USB is never modified. The four data disks (disk0-3.img) are still used.
qemu-usb:
	@[ -n "$(USB_DEV)" ] || { echo 'error: set USB_DEV=/dev/sdX (the USB block device to boot)'; exit 1; }
	FOREGROUND=1 USB_DEV=$(USB_DEV) VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) ${PWD}/make/qemu.sh $(USB_DEV)

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

release: image-release
	RELEASE_VERSION=$(or $(RELEASE_VERSION),$(BUILD_DATE)-unstable) IMAGE=$(IMAGE) ${PWD}/make/release.sh
