#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: qemu.sh IMAGE}"
VM_DISK_SIZE="${VM_DISK_SIZE:?VM_DISK_SIZE is required}"
VM_MEMORY="${VM_MEMORY:?VM_MEMORY is required}"
VM_BRIDGE="${VM_BRIDGE:?VM_BRIDGE is required}"
FOREGROUND="${FOREGROUND:-0}"

sudo ip link set "${VM_BRIDGE}" allmulticast on 2>/dev/null || true

# Disable IGMP snooping so the bridge floods mDNS multicast to all ports
sudo ip link set "${VM_BRIDGE}" type bridge mcast_snooping 0 2>/dev/null || true

# Allow multicast (mDNS) through the bridge — br_netfilter drops it by default
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true

for i in 0 1 2 3; do
  if [ ! -f "disk${i}.img" ]; then
    truncate -s "${VM_DISK_SIZE}" "disk${i}.img"
    echo "Created sparse disk${i}.img (${VM_DISK_SIZE})"
  fi
done

# Native architecture only — NEVER cross-arch, NEVER emulate a foreign arch.
# We always run qemu-system-<host arch>, so the guest arch always equals the
# host arch (x86_64 host -> x86_64 guest, aarch64 host -> aarch64 guest).
ARCH=$(uname -m)
QEMU_BIN="qemu-system-${ARCH}"
if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
  echo "error: ${QEMU_BIN} not found — install QEMU for this architecture." >&2
  exit 1
fi

# Architecture-specific machine, firmware, and display.
MACHINE_ARGS=()
FIRMWARE_ARGS=()
GFX_ARGS=()
case "${ARCH}" in
  x86_64)
    # SeaBIOS is built into qemu-system-x86_64; no firmware/display args needed
    # (the headless serial path below drives the console).
    ;;
  aarch64)
    MACHINE_ARGS=(-machine virt,gic-version=max)
    # qemu-system-aarch64 'virt' has NO built-in firmware. Without UEFI (edk2)
    # via pflash it sits at a blank display forever — there is nothing to read
    # the image's /EFI/BOOT/BOOTAA64.EFI. Locate the installed edk2 code+vars
    # pair and give this VM a private writable copy of the vars store.
    # Prefer the SILENT/release edk2 build over the default DEBUG build: Fedora's
    # plain QEMU_EFI-pflash.raw is a DEBUG firmware that spews verbose symbol
    # output over serial and boots noticeably slower; the *-silent build is the
    # quiet release variant.
    EDK2_CODE=""
    EDK2_VARS_TEMPLATE=""
    for pair in \
      "/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw:/usr/share/edk2/aarch64/vars-template-pflash.raw" \
      "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw:/usr/share/edk2/aarch64/vars-template-pflash.raw" \
      "/usr/share/edk2/aarch64/QEMU_CODE.fd:/usr/share/edk2/aarch64/QEMU_VARS.fd" \
      "/usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd" \
      "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd:/usr/share/qemu-efi-aarch64/QEMU_VARS.fd"; do
      code="${pair%%:*}"
      vars="${pair##*:}"
      if [ -f "${code}" ] && [ -f "${vars}" ]; then
        EDK2_CODE="${code}"
        EDK2_VARS_TEMPLATE="${vars}"
        break
      fi
    done
    if [ -z "${EDK2_CODE}" ]; then
      echo "error: no aarch64 UEFI (edk2) firmware found. Install it:" >&2
      echo "  Fedora/Asahi:  sudo dnf install edk2-aarch64" >&2
      echo "  Arch:          sudo pacman -S edk2-aarch64" >&2
      echo "  Debian/Ubuntu: sudo apt install qemu-efi-aarch64" >&2
      exit 1
    fi
    EDK2_VARS="efivars-${VM_NAME:-town-os}.img"
    if [ ! -f "${EDK2_VARS}" ]; then
      cp "${EDK2_VARS_TEMPLATE}" "${EDK2_VARS}"
      echo "Created per-VM UEFI varstore ${EDK2_VARS} (from ${EDK2_VARS_TEMPLATE})"
    fi
    FIRMWARE_ARGS=(
      -drive "if=pflash,format=raw,readonly=on,file=${EDK2_CODE}"
      -drive "if=pflash,format=raw,file=${EDK2_VARS}"
    )
    # The default GRUB entry drives the VGA console (console=tty0), so give the
    # guest a virtio GPU and a window. 'virt' has NO built-in keyboard/mouse (unlike
    # a PC), so attach USB HID devices on the qemu-xhci controller — without these
    # the window receives no input and the ttyforce installer TUI is unusable. The
    # initrd's mkinitcpio `keyboard` hook provides the guest-side USB-HID drivers.
    # Serial is still exported on a socket below.
    GFX_ARGS=(-device virtio-gpu-pci -device usb-kbd -device usb-tablet -display gtk)
    ;;
  *)
    echo "error: unsupported host architecture '${ARCH}'." >&2
    exit 1
    ;;
esac

# CPU/acceleration. Use KVM + -cpu host whenever /dev/kvm is present — on BOTH
# x86_64 and aarch64 (incl. Apple Silicon / Asahi, where KVM does work). KVM is
# not just a speed-up here: under pure TCG emulation a full aarch64 UEFI boot
# (firmware -> GRUB -> kernel) is so slow that the guest takes many minutes to
# even initialize the framebuffer, so the display appears blank. With KVM the
# kernel is up and painting tty0 within seconds. Either path runs the HOST's own
# architecture — never cross-arch, never a foreign ISA under emulation.
ACCEL_ARGS=()
if [ -e /dev/kvm ]; then
  ACCEL_ARGS=(-enable-kvm -cpu host)
else
  ACCEL_ARGS=(-cpu max)
  echo "note: /dev/kvm absent — running native ${ARCH} under TCG. An aarch64 UEFI" >&2
  echo "      boot under TCG is extremely slow; the display may stay blank for minutes." >&2
fi

DAEMON_ARGS=()
SERIAL_ARGS=()
if [ "${FOREGROUND}" != "1" ]; then
  DAEMON_ARGS=(-daemonize -pidfile qemu.pid)
  SERIAL_ARGS=(-serial "unix:/tmp/town-os-serial.sock,server=on,wait=off")
elif [ "${#GFX_ARGS[@]}" -gt 0 ]; then
  # Graphical foreground (aarch64): the console is the GTK window; still export
  # the serial port on a socket so `make serial` can attach.
  DAEMON_ARGS=(-pidfile qemu.pid)
  SERIAL_ARGS=(-serial "unix:/tmp/town-os-serial.sock,server=on,wait=off")
else
  # Headless foreground (x86_64): multiplex the serial console onto stdio.
  DAEMON_ARGS=(-pidfile qemu.pid)
  SERIAL_ARGS=(-nographic -serial mon:stdio)
fi

# Generate a stable random MAC in the QEMU OUI range (52:54:00:xx:xx:xx)
# seeded from the VM name so the same VM always gets the same MAC/IP
MAC=$(echo "${VM_NAME:-town-os}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')

# The boot image (town-os-*.img) comes from the root image build and is
# root-owned, mode 0644 (world-READABLE, not writable by the user). The
# graphical path runs QEMU as the invoking user (see below), so open the USB
# image with snapshot=on: QEMU opens the base READ-ONLY (our read permission is
# enough) and diverts guest writes to a throwaway overlay, leaving the installed
# image pristine. The headless root path opens it read/write as before.
USBDISK_DRIVE="if=none,id=usbdisk,file=${IMAGE},format=raw"
if [ "${#GFX_ARGS[@]}" -gt 0 ]; then
  USBDISK_DRIVE="${USBDISK_DRIVE},snapshot=on"
fi

# Assemble the full QEMU command line as an array.
QEMU_CMD=(
  "${QEMU_BIN}"
  "${ACCEL_ARGS[@]}"
  "${MACHINE_ARGS[@]}"
  "${FIRMWARE_ARGS[@]}"
  -m "${VM_MEMORY}"
  -netdev "bridge,id=net0,br=${VM_BRIDGE}"
  -device "virtio-net-pci,netdev=net0,mac=${MAC}"
  -device qemu-xhci
  -drive "${USBDISK_DRIVE}"
  -device usb-storage,drive=usbdisk,bootindex=0
  -device ahci,id=ahci0
  -drive file=disk0.img,if=none,id=d0,format=raw
  -device ide-hd,drive=d0,bus=ahci0.0
  -drive file=disk1.img,if=none,id=d1,format=raw
  -device ide-hd,drive=d1,bus=ahci0.1
  -drive file=disk2.img,if=none,id=d2,format=raw
  -device ide-hd,drive=d2,bus=ahci0.2
  -drive file=disk3.img,if=none,id=d3,format=raw
  -device ide-hd,drive=d3,bus=ahci0.3
  "${GFX_ARGS[@]}"
  "${SERIAL_ARGS[@]}"
  "${DAEMON_ARGS[@]}"
)

# A prior root run may have left a root-owned serial socket; clear it either way.
rm -f /tmp/town-os-serial.sock 2>/dev/null || sudo rm -f /tmp/town-os-serial.sock 2>/dev/null || true

# Privilege model:
#  - Graphical guest (aarch64): run QEMU as the INVOKING USER. GTK then maps its
#    window in the user's OWN Wayland/X session, which just works. Running QEMU
#    as root does NOT display: a root GTK client can connect to the user's
#    Wayland socket (CAP_DAC_OVERRIDE) and even create surfaces, but GNOME/Mutter
#    will not map a window owned by a different user — so nothing appears. Root
#    is unnecessary anyway: the bridge attaches via the setuid qemu-bridge-helper
#    (see `allow` in /etc/qemu/bridge.conf) and aarch64 uses no KVM. The USB
#    image is opened read-only via snapshot=on (above) so the user can read it.
#  - Headless x86 (-nographic, KVM + bridge): keep sudo/root.
if [ "${#GFX_ARGS[@]}" -gt 0 ]; then
  "${QEMU_CMD[@]}"
else
  sudo "${QEMU_CMD[@]}"
fi

if [ "${FOREGROUND}" != "1" ]; then
  PID=$(sudo cat qemu.pid)
  echo "QEMU running in background (PID ${PID})"
  echo "Serial console: socat - UNIX-CONNECT:/tmp/town-os-serial.sock"

  echo "Waiting for VM network (up to 120s)..."
  DEADLINE=$((SECONDS + 120))
  DELAY=1
  IP=""
  while [ "${SECONDS}" -lt "${DEADLINE}" ]; do
    sleep "${DELAY}"
    IP=$(VM_NAME="${VM_NAME:-town-os}" IMAGE="${IMAGE}" "$(dirname "$0")/vm-ip.sh" 2>/dev/null) || true
    if [ -n "${IP}" ]; then
      echo "${IP}"
      exit 0
    fi
    # Exponential backoff: 1 → 2 → 4 → 5 (cap)
    DELAY=$(( DELAY * 2 > 5 ? 5 : DELAY * 2 ))
  done
  echo "Timed out waiting for VM network after ${TIMEOUT}s"
  echo "Use 'make vm-ip' to check later"
fi
