IMAGE            ?= image.raw
IMAGE_SIZE       ?= 12G
CONTROLLER_IMAGE ?= quay.io/town/town:rc.latest
UI_IMAGE         ?= quay.io/town/ui:rc.latest
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
VM_BRIDGE   ?= virbr0
VM_NAME     ?= town-os
FOREGROUND  ?=

.PHONY: run run-release stop image image-release qemu qemu-fg \
        qemu-release virtualbox virtualbox-fg virtualbox-release \
        stop-qemu stop-virtualbox vm-ip clean cleanup-loopback deps

run: deps $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) FOREGROUND=$(FOREGROUND) \
	  ${PWD}/make/run.sh $(IMAGE)

image:
	CONTROLLER_IMAGE=$(CONTROLLER_IMAGE) UI_IMAGE=$(UI_IMAGE) ${PWD}/make/image.sh $(IMAGE_SIZE) $(IMAGE)

image-release:
	$(MAKE) image CONTROLLER_IMAGE=quay.io/town/town:latest UI_IMAGE=quay.io/town/ui:latest

run-release:
	$(MAKE) run CONTROLLER_IMAGE=quay.io/town/town:latest UI_IMAGE=quay.io/town/ui:latest

qemu-release:
	$(MAKE) qemu CONTROLLER_IMAGE=quay.io/town/town:latest UI_IMAGE=quay.io/town/ui:latest

virtualbox-release:
	$(MAKE) virtualbox CONTROLLER_IMAGE=quay.io/town/town:latest UI_IMAGE=quay.io/town/ui:latest

qemu: deps $(IMAGE)
	VM_DISK_SIZE=$(VM_DISK_SIZE) VM_MEMORY=$(VM_MEMORY) VM_BRIDGE=$(VM_BRIDGE) \
	  VM_NAME=$(VM_NAME) IMAGE=$(IMAGE) \
	  ${PWD}/make/qemu.sh $(IMAGE)

qemu-fg: deps $(IMAGE)
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

clean: stop
	IMAGE=$(IMAGE) VM_NAME=$(VM_NAME) ${PWD}/make/clean.sh

deps:
	${PWD}/make/deps.sh

cleanup-loopback:
	${PWD}/make/cleanup-loopback.sh
