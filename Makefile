BUILD_DATE       := $(shell date +%Y-%m-%d)
IMAGE            ?= town-os-$(BUILD_DATE).img
IMAGE_SIZE       ?= 12G
CONTROLLER_IMAGE ?= quay.io/town/town:rc.latest
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

.PHONY: run run-release stop image image-release qemu qemu-fg \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip serial clean clean-images \
        cleanup-loopback deps deps-debian release flash

rebuild-qemu: stop clean image qemu

run: stop $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

image:
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) ROLODEX_IMAGE=$(ROLODEX_IMAGE) UI_IMAGE=$(UI_IMAGE) LOCAL_DNS=$(LOCAL_DNS) TTYFORCE_DEV=$(TTYFORCE_DEV) TTYFORCE_LATEST=$(TTYFORCE_LATEST) IMAGE_HOSTNAME=$(IMAGE_HOSTNAME) ${PWD}/make/image.sh $(IMAGE_SIZE) $(IMAGE)

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
