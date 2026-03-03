IMAGE       ?= image.raw
IMAGE_SIZE  ?= 10G
VM_DISK_SIZE ?= $(shell grep '^vm_disk_size:' town-os.yaml \
                  | awk '{ print $$2 }' | tr -d '"' | tr -d "'" \
                  || echo 50G)
VM_MEMORY   ?= 4G
VM_NAME     ?= town-os

.PHONY: build-image qemu virtualbox cleanup-loopback

build-image: $(IMAGE)

$(IMAGE):
	sudo ./install.sh $(IMAGE_SIZE) $(IMAGE)

qemu: $(IMAGE)
	@for i in 0 1 2 3; do \
	  if [ ! -f disk$$i.img ]; then \
	    truncate -s $(VM_DISK_SIZE) disk$$i.img; \
	    echo "Created sparse disk$$i.img ($(VM_DISK_SIZE))"; \
	  fi; \
	done
	qemu-system-x86_64 \
	  -enable-kvm \
	  -m $(VM_MEMORY) \
	  -device qemu-xhci \
	  -drive if=none,id=usbdisk,file=$(IMAGE),format=raw \
	  -device usb-storage,drive=usbdisk \
	  -device ahci,id=ahci0 \
	  -drive file=disk0.img,if=none,id=d0,format=raw \
	  -device ide-hd,drive=d0,bus=ahci0.0 \
	  -drive file=disk1.img,if=none,id=d1,format=raw \
	  -device ide-hd,drive=d1,bus=ahci0.1 \
	  -drive file=disk2.img,if=none,id=d2,format=raw \
	  -device ide-hd,drive=d2,bus=ahci0.2 \
	  -drive file=disk3.img,if=none,id=d3,format=raw \
	  -device ide-hd,drive=d3,bus=ahci0.3

virtualbox: $(IMAGE)
	@for i in 0 1 2 3; do \
	  if [ ! -f disk$$i.img ]; then \
	    truncate -s $(VM_DISK_SIZE) disk$$i.img; \
	    echo "Created sparse disk$$i.img ($(VM_DISK_SIZE))"; \
	  fi; \
	done
	-VBoxManage unregistervm $(VM_NAME) --delete 2>/dev/null
	VBoxManage createvm --name $(VM_NAME) --ostype Linux_64 --register
	VBoxManage modifyvm $(VM_NAME) --memory 4096 --cpus 2 --firmware efi
	VBoxManage storagectl $(VM_NAME) --name "IDE" --add ide
	VBoxManage convertfromraw $(IMAGE) $(VM_NAME)-boot.vdi --format VDI 2>/dev/null || true
	VBoxManage storageattach $(VM_NAME) --storagectl "IDE" --port 0 --device 0 \
	  --type hdd --medium $(VM_NAME)-boot.vdi
	VBoxManage storagectl $(VM_NAME) --name "AHCI" --add sata \
	  --controller IntelAhci --portcount 4
	@for i in 0 1 2 3; do \
	  VBoxManage convertfromraw disk$$i.img $(VM_NAME)-disk$$i.vdi --format VDI 2>/dev/null || true; \
	  VBoxManage storageattach $(VM_NAME) --storagectl "AHCI" --port $$i --device 0 \
	    --type hdd --medium $(VM_NAME)-disk$$i.vdi; \
	done
	VBoxManage startvm $(VM_NAME)

cleanup-loopback:
	mount | grep loop | awk '{ print $$3 }' | xargs -I{} sudo fuser -cfk {} || :
	mount | grep loop | awk '{ print $$3 }' | xargs -I{} sudo umount -Rf {} || :
	sudo losetup -D
