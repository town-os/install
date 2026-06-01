BUILD_DATE       := $(shell date +%Y-%m-%d)
IMAGE            ?= town-os-$(BUILD_DATE).img
IMAGE_SIZE       ?= 12G
CONTROLLER_BASE  ?= quay.io/town/town
CONTROLLER_TAG   ?= rc.latest
CONTROLLER_IMAGE ?= $(CONTROLLER_BASE):$(CONTROLLER_TAG)
ROLODEX_IMAGE    ?= quay.io/town/rolodex:$(lastword $(subst :, ,$(CONTROLLER_IMAGE)))
UI_IMAGE         ?= quay.io/town/ui:rc.latest
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
VM_BRIDGE   ?= virbr0
VM_NAME     ?= town-os
FOREGROUND  ?=
LOCAL_DNS   ?=

.PHONY: help run run-release stop image image-release qemu qemu-fg \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial clean clean-images \
        cleanup-loopback deps deps-debian release flash rebuild-qemu

help:
	@echo 'Town OS Install — Makefile targets'
	@echo
	@echo 'Build:'
	@echo '  image            Build the disk image only (requires root, Arch host)'
	@echo '  image-release    Build the image and compress it to .bz2'
	@echo '  release          Build, compress, and publish a release'
	@echo
	@echo 'Run (QEMU):'
	@echo '  qemu             Build if stale, launch QEMU in the background'
	@echo '  qemu-fg          Build if stale, launch QEMU in the foreground (serial attached)'
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
	@echo '  deps             Install host dependencies on Arch Linux'
	@echo '  deps-debian      Install host dependencies on Debian/Ubuntu'
	@echo
	@echo 'Common variables (override with VAR=value):'
	@echo '  IMAGE=$(IMAGE)'
	@echo '  IMAGE_SIZE=$(IMAGE_SIZE)        VM_DISK_SIZE=$(VM_DISK_SIZE)   VM_MEMORY=$(VM_MEMORY)'
	@echo '  CONTROLLER_IMAGE=$(CONTROLLER_IMAGE)'
	@echo '  IMAGE_HOSTNAME, LOCAL_DNS, TTYFORCE_DEV, TTYFORCE_LATEST, KEEP_MOUNT'

rebuild-qemu: stop clean image qemu

run: stop $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

IMAGE_SOURCES := $(wildcard make/install.sh scripts/*.sh systemd/*.service systemd/*.timer \
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
	  'IMAGE_SIZE=$(IMAGE_SIZE)' | cmp -s - $@ || \
	printf '%s\n' \
	  'CONTROLLER_IMAGE=$(CONTROLLER_IMAGE)' \
	  'ROLODEX_IMAGE=$(ROLODEX_IMAGE)' \
	  'UI_IMAGE=$(UI_IMAGE)' \
	  'TTYFORCE_DEV=$(TTYFORCE_DEV)' \
	  'TTYFORCE_LATEST=$(TTYFORCE_LATEST)' \
	  'IMAGE_HOSTNAME=$(IMAGE_HOSTNAME)' \
	  'LOCAL_DNS=$(LOCAL_DNS)' \
	  'IMAGE_SIZE=$(IMAGE_SIZE)' > $@

$(IMAGE): $(IMAGE_SOURCES) .build-config
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) ${PWD}/make/image.sh $(IMAGE_SIZE) $(IMAGE)

image: $(IMAGE)

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
