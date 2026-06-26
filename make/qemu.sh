#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: qemu.sh IMAGE}"
VM_DISK_SIZE="${VM_DISK_SIZE:?VM_DISK_SIZE is required}"
VM_MEMORY="${VM_MEMORY:?VM_MEMORY is required}"
VM_BRIDGE="${VM_BRIDGE:?VM_BRIDGE is required}"
FOREGROUND="${FOREGROUND:-0}"

# Boot source. By default QEMU boots the built image file ($IMAGE). Set USB_DEV
# to a physical USB block device (e.g. /dev/sda) to boot that instead — used by
# the `qemu-usb` target to test an actual flashed USB stick in a VM. A device
# boot is ALWAYS opened read-only (snapshot=on, see below) so the physical USB is
# never modified; guest writes go to a throwaway overlay and are discarded.
USB_DEV="${USB_DEV:-}"
BOOT_SRC="${IMAGE}"
if [ -n "${USB_DEV}" ]; then
  if [ ! -b "${USB_DEV}" ]; then
    echo "error: USB_DEV='${USB_DEV}' is not a block device." >&2
    exit 1
  fi
  BOOT_SRC="${USB_DEV}"
fi

# Generate a stable random MAC in the QEMU OUI range (52:54:00:xx:xx:xx) seeded
# from the VM name so the same VM always gets the same MAC — and, via the DHCP
# reservation and SLAAC below, the same IPv4 and IPv6 address every boot.
MAC=$(echo "${VM_NAME:-town-os}" | md5sum | sed 's/^\(..\)\(..\)\(..\).*/52:54:00:\1:\2:\3/')

# Point libvirt's NAT resolver at the HOST's real upstream DNS so the guest
# inherits the same servers the host got from the local network's DHCP.
#
# By default the 'default' network's dnsmasq (the guest's DHCP/DNS server at
# 192.168.122.1) resolves via the HOST's /etc/resolv.conf -> systemd-resolved.
# When the host itself points resolved at this guest (i.e. uses Town OS as its
# resolver), that path LOOPS: guest rolodex -> 192.168.122.1 -> host resolved
# -> guest -> ... and DNS collapses under load. Pinning the network's <dns>
# <forwarder> to the host's actual DHCP-provided servers breaks the loop and
# hands the guest the host's upstream directly: rolodex keeps forwarding to
# 192.168.122.1, but 192.168.122.1 now answers from the real upstream instead of
# bouncing back through the host. dnsmasq runs ON the host, so it reaches those
# servers exactly as the host does -- the NAT'd guest frequently cannot query
# them directly. Best-effort, only for the libvirt 'default' NAT network we
# manage; the new forwarders take effect on the network's next (re)start, which
# the bridge-ensure block below performs. Like the DHCP reservation, this cycles
# the shared 'default' network when it changes, so co-running VMs on it blip.
if command -v virsh >/dev/null 2>&1 \
   && [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ]; then
  DNS_DEV=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | head -1)
  DNS_NET_PREFIX=$(sudo virsh net-dumpxml default 2>/dev/null \
    | grep -oE "ip address='[0-9.]+'" | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
  # Host upstream DNS: prefer NetworkManager's per-link record (it preserves the
  # DHCP values even when systemd-resolved is manually overridden to point at the
  # guest); fall back to networkd lease files. Drop loopback (the resolved stub),
  # the guest subnet, and this VM's IP -- forwarding to any of those rebuilds the
  # loop. grep -oE extracts the address regardless of nmcli's ' | ' separators.
  HOST_DNS=$(
    { nmcli -g IP4.DNS dev show "${DNS_DEV}" 2>/dev/null | tr '|,' '\n\n'
      awk -F= '/^DNS=/{print $2}' /run/systemd/netif/leases/* 2>/dev/null | tr ' ' '\n'; } \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -vE '^127\.' \
      | { if [ -n "${DNS_NET_PREFIX}" ]; then grep -vE "^${DNS_NET_PREFIX//./\\.}\."; else cat; fi; } \
      | { if [ -n "${VM_IP:-}" ]; then grep -vxF "${VM_IP}"; else cat; fi; } \
      | awk 'NF && !seen[$0]++'
  ) || true   # tolerate pipefail: literal glob when no networkd leases, or greps that filter everything out
  if [ -n "${HOST_DNS}" ]; then
    DNS_WANT=$(printf '%s\n' ${HOST_DNS} | sort | tr '\n' ' ')
    DNS_HAVE=$(sudo virsh net-dumpxml --inactive default 2>/dev/null \
      | grep -oE "<forwarder addr='[0-9.]+'/>" \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | tr '\n' ' ')
    if [ "${DNS_WANT}" != "${DNS_HAVE}" ]; then
      DNS_BLOCK=$(printf '  <dns>\n'
        printf '%s\n' ${HOST_DNS} \
          | while IFS= read -r s; do printf "    <forwarder addr='%s'/>\n" "${s}"; done
        printf '  </dns>')
      DNS_NEW_XML=$(sudo virsh net-dumpxml --inactive default 2>/dev/null \
        | awk -v ins="${DNS_BLOCK}" '
            /<dns[ >\/]/ { if ($0 ~ /<\/dns>/ || $0 ~ /\/>/) next; indns=1; next }
            indns        { if ($0 ~ /<\/dns>/) indns=0; next }
            /<ip / && !done { print ins; done=1 }
            { print }')
      DNS_TMPXML=$(mktemp)
      printf '%s\n' "${DNS_NEW_XML}" > "${DNS_TMPXML}"
      # Only updates the PERSISTENT definition -- this never disturbs a running
      # network, so it is safe to do mid-launch. The new forwarders take effect
      # the next time the network is cold-started: by the bridge-ensure block
      # below when the bridge is absent (the common case on Fedora, where the
      # socket-activated network does not survive a host reboot), or on the next
      # `virsh net-start`. We deliberately do NOT net-destroy a live network here
      # -- tearing down virbr0 mid-launch is fragile and would cut co-running VMs.
      if sudo virsh net-define "${DNS_TMPXML}" >/dev/null 2>&1; then
        if ip link show "${VM_BRIDGE}" >/dev/null 2>&1; then
          echo "Updated libvirt 'default' DNS forwarders -> $(echo ${HOST_DNS}) (host upstream);"
          echo "  applies on the network's next restart: sudo virsh net-destroy default && sudo virsh net-start default"
        else
          echo "Set libvirt 'default' DNS forwarders -> $(echo ${HOST_DNS}) (host upstream)"
        fi
      fi
      rm -f "${DNS_TMPXML}"
    fi
  fi
fi

# Give the guest an IPv6 address alongside its NAT'd IPv4 so rolodex and Town OS
# can be set up over IPv6 too. We add a ULA /64 to the libvirt 'default' network
# and rely on SLAAC (a router-advertised prefix, NO DHCPv6) rather than a v6 DHCP
# reservation. WHY SLAAC: DHCPv6 keys leases on the client DUID, which the guest
# regenerates every boot (read-only squashfs root, nothing persisted — the same
# churn the IPv4 reservation above works around), and libvirt cannot pin a v6
# lease by MAC the way it can for IPv4. SLAAC instead derives a STABLE EUI-64
# address from the guest's stable MAC, so the address is deterministic — computed
# and printed below, no reservation needed. Set VM_NET6_PREFIX= (empty) to skip.
# Like the DNS-forwarder edit, this only rewrites the PERSISTENT network
# definition; it takes effect on the network's next cold start (the bridge-ensure
# block below when virbr0 is absent, or a manual net-destroy + net-start).
VM_NET6_PREFIX="${VM_NET6_PREFIX:-fd00:c0a8:7a}"   # ULA /64; ::1 is the gateway

# Only offer the guest an IPv6 address (the ULA below, advertised via SLAAC)
# when the HOST can actually reach the IPv6 internet. Merely having a
# global-unicast address on the uplink is NOT enough: a network can advertise a
# v6 prefix and default route yet silently drop v6 traffic (common on managed
# WiFi), and libvirt's default network does not NAT IPv6 anyway — so a guest v6
# address would be dead weight. We verify reachability directly by pinging a
# couple of public v6 anycast resolvers (two, so one filtered target doesn't
# produce a false negative); the host's default v6 route picks the uplink. No
# route / no global source makes ping fail fast; a half-broken network costs the
# -W timeout. Blanking VM_NET6_PREFIX makes the two IPv6 blocks below skip; set
# VM_NET6_FORCE=1 to offer v6 regardless.
if [ -n "${VM_NET6_PREFIX}" ] && [ -z "${VM_NET6_FORCE:-}" ]; then
  HOST_V6_OK=""
  for _v6t in 2606:4700:4700::1111 2001:4860:4860::8888; do
    if ping -6 -c1 -W2 "${_v6t}" >/dev/null 2>&1; then HOST_V6_OK="x"; break; fi
  done
  if [ -z "${HOST_V6_OK}" ]; then
    echo "Skipping guest IPv6: host has no working route to the IPv6 internet"
    echo "  (probed public v6 anycasts; libvirt's NAT doesn't carry IPv6 anyway). Set VM_NET6_FORCE=1 to override."
    VM_NET6_PREFIX=""
  fi
fi

if [ -n "${VM_NET6_PREFIX}" ] && command -v virsh >/dev/null 2>&1 \
   && [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ]; then
  # Guest's stable SLAAC address: EUI-64 interface id from the stable MAC
  # 52:54:00:o4:o5:o6 -> ::5054:ff:fe<o4>:<o5><o6> (U/L bit of 0x52 flipped to
  # 0x50, ff:fe inserted). VM_IP6 overrides the printed address if you statically
  # assign one in the guest instead.
  O4=$(echo "${MAC}" | cut -d: -f4); O5=$(echo "${MAC}" | cut -d: -f5); O6=$(echo "${MAC}" | cut -d: -f6)
  GUEST_IP6="${VM_IP6:-${VM_NET6_PREFIX}::5054:ff:fe${O4}:${O5}${O6}}"
  if ! sudo virsh net-dumpxml --inactive default 2>/dev/null | grep -q "family='ipv6'"; then
    IP6_BLOCK="  <ip family='ipv6' address='${VM_NET6_PREFIX}::1' prefix='64'/>"
    IP6_NEW_XML=$(sudo virsh net-dumpxml --inactive default 2>/dev/null \
      | awk -v ins="${IP6_BLOCK}" '/<\/network>/ && !done { print ins; done=1 } { print }')
    IP6_TMPXML=$(mktemp)
    printf '%s\n' "${IP6_NEW_XML}" > "${IP6_TMPXML}"
    if sudo virsh net-define "${IP6_TMPXML}" >/dev/null 2>&1; then
      if ip link show "${VM_BRIDGE}" >/dev/null 2>&1; then
        echo "Added IPv6 ${VM_NET6_PREFIX}::/64 to libvirt 'default' (gateway ${VM_NET6_PREFIX}::1);"
        echo "  applies on the network's next restart: sudo virsh net-destroy default && sudo virsh net-start default"
      else
        echo "Added IPv6 ${VM_NET6_PREFIX}::/64 to libvirt 'default' (gateway ${VM_NET6_PREFIX}::1)"
      fi
    fi
    rm -f "${IP6_TMPXML}"
  fi
  echo "Guest IPv6 (SLAAC, stable): ${GUEST_IP6}"
fi

# The VM attaches to the libvirt 'default' NAT bridge via qemu-bridge-helper.
# On Fedora libvirt runs as modular SOCKET-ACTIVATED daemons (virtnetworkd):
# nothing starts them at boot, so the autostart 'default' network — and virbr0
# with it — does not exist until libvirt is first poked. Without the bridge,
# qemu-bridge-helper fails and the ip/sysctl tweaks below silently no-op.
if ! ip link show "${VM_BRIDGE}" >/dev/null 2>&1; then
  # Any virsh call activates the daemons, which brings up autostart networks;
  # net-start covers a defined-but-stopped network. If net-start says the
  # network is already active while its bridge is missing, the state is stale
  # (e.g. the bridge was deleted out from under libvirt) — cycle the network.
  sudo virsh net-start default >/dev/null 2>&1 \
    || { sudo virsh net-destroy default >/dev/null 2>&1 \
           && sudo virsh net-start default >/dev/null 2>&1; } \
    || true
  for _ in $(seq 1 10); do
    ip link show "${VM_BRIDGE}" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! ip link show "${VM_BRIDGE}" >/dev/null 2>&1; then
    echo "error: bridge ${VM_BRIDGE} does not exist and could not be started." >&2
    echo "       Run 'make deps' to define/autostart libvirt's default network," >&2
    echo "       or create the bridge manually if VM_BRIDGE is custom." >&2
    exit 1
  fi
fi

# Make the IPv6 block (and any other persistent-only edits above, e.g. the DNS
# forwarders) actually LIVE for the guest about to boot. net-define only updates
# the PERSISTENT config, so a network that was already running still lacks IPv6
# until a cold start — the guest's dhcpcd would then see no RA/DHCPv6 and get no
# v6 address. If the running 'default' network is missing the IPv6 we want, cold-
# start it now — but ONLY when no other VM is attached to the bridge, since
# net-destroy would cut co-running VMs (the bridge's own ${VM_BRIDGE}-nic stub
# doesn't count). With other VMs present we leave it and print how to apply later.
if [ -n "${VM_NET6_PREFIX}" ] && command -v virsh >/dev/null 2>&1 \
   && [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ] \
   && ! sudo virsh net-dumpxml default 2>/dev/null | grep -q "family='ipv6'"; then
  # Any bridge member other than the network's own ${VM_BRIDGE}-nic stub means a
  # VM tap is attached. Glob the brif dir directly (never parse `ls` — it may be
  # aliased); the [ -e ] guard handles an unexpanded glob under `set -u`.
  OTHER_TAPS=""
  for _m in "/sys/class/net/${VM_BRIDGE}/brif/"*; do
    [ -e "${_m}" ] || continue
    [ "${_m##*/}" = "${VM_BRIDGE}-nic" ] && continue
    OTHER_TAPS="x"; break
  done
  if [ -z "${OTHER_TAPS}" ]; then
    if sudo virsh net-destroy default >/dev/null 2>&1 && sudo virsh net-start default >/dev/null 2>&1; then
      for _ in $(seq 1 10); do ip link show "${VM_BRIDGE}" >/dev/null 2>&1 && break; sleep 0.5; done
      echo "Cold-started libvirt 'default' so this guest gets IPv6 (no other VMs were attached)."
    fi
  else
    echo "NOTE: libvirt 'default' is running WITHOUT IPv6 and other VMs are on ${VM_BRIDGE};"
    echo "      this guest won't get IPv6 until: sudo virsh net-destroy default && sudo virsh net-start default"
  fi
fi

# Re-assert mDNS on the bridge: resolvectl's per-link setting is runtime-only
# and is lost whenever the bridge is recreated (e.g. every reboot), breaking
# guest .local resolution (vm-ip.sh). Idempotent, so do it every launch.
sudo resolvectl mdns "${VM_BRIDGE}" yes 2>/dev/null || true

# firewalld hosts (Fedora): guest mDNS (UDP 5353) must be allowed in the zone
# holding the bridge or it's rejected before resolved sees it. deps.sh adds it
# permanently; re-assert at runtime in case deps hasn't been re-run.
if command -v firewall-cmd >/dev/null 2>&1; then
  sudo firewall-cmd --zone=libvirt --add-service=mdns >/dev/null 2>&1 || true
fi

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

# Pin a stable DHCP lease for this VM via a MAC-keyed reservation on libvirt's
# default network. WHY: the guest presents a fresh DHCP client-id (a dhcpcd
# DUID) on every boot — its root is read-only squashfs, so the DUID isn't
# persisted — and dnsmasq keys leases on the client-id ahead of the MAC. Without
# a reservation the VM therefore gets a NEW address every boot (.9 -> .10 -> ..),
# which silently breaks `make vm-ip`, `make lan-proxy` (it bakes the guest IP in
# at startup), and the guest's mDNS record. A MAC reservation forces a fixed IP
# regardless of the churning client-id. Only meaningful for the libvirt 'default'
# NAT network; skip custom bridges (we don't run dnsmasq for those). Best-effort
# — never block the VM launch on it. (Takes effect on the guest's next DHCP, i.e.
# next boot; the proper guest-side fix is a stable, MAC-based client identifier.)
if [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ]; then
  NET_PREFIX=$(sudo virsh net-dumpxml default 2>/dev/null \
    | grep -oE "ip address='[0-9.]+'" | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
  if [ -n "${NET_PREFIX}" ]; then
    if [ -n "${VM_IP:-}" ]; then
      # Explicit pin. Must be in the default network's subnet or libvirt rejects
      # the reservation — warn and fall back to the derived IP if it isn't.
      if [ "${VM_IP%.*}" = "${NET_PREFIX}" ]; then
        RESERVED_IP="${VM_IP}"
      else
        echo "warning: VM_IP=${VM_IP} is not in the ${NET_PREFIX}.0/24 subnet; ignoring it" >&2
        VM_IP=""
      fi
    fi
    if [ -z "${VM_IP:-}" ]; then
      # Deterministic per-VM host octet from the same name seed, in .200-.249 (high
      # end of the pool, away from dnsmasq's low-end dynamic picks).
      OCTET=$(( 16#$(echo "${VM_NAME:-town-os}" | md5sum | cut -c7-8) % 50 + 200 ))
      RESERVED_IP="${NET_PREFIX}.${OCTET}"
    fi
    # Idempotent: drop any prior entry for this MAC, then (re)add the reservation.
    sudo virsh net-update default delete ip-dhcp-host \
      "<host mac='${MAC}'/>" --live --config >/dev/null 2>&1 || true
    if sudo virsh net-update default add ip-dhcp-host \
         "<host mac='${MAC}' ip='${RESERVED_IP}'/>" --live --config >/dev/null 2>&1; then
      echo "Reserved ${RESERVED_IP} for '${VM_NAME:-town-os}' (MAC ${MAC}) on the default network"
    fi
  fi
fi

# The boot image (town-os-*.img) comes from the root image build and is
# root-owned, mode 0644 (world-READABLE, not writable by the user). The
# graphical path runs QEMU as the invoking user (see below), so open the USB
# image with snapshot=on: QEMU opens the base READ-ONLY (our read permission is
# enough) and diverts guest writes to a throwaway overlay, leaving the installed
# image pristine. The headless root path opens it read/write as before.
USBDISK_DRIVE="if=none,id=usbdisk,file=${BOOT_SRC},format=raw"
# Open read-only (snapshot=on) when the graphical path runs QEMU as the user (it
# only has read permission on the root-owned image) OR when booting a physical
# USB device (never mutate the user's real stick — writes hit a throwaway overlay).
if [ "${#GFX_ARGS[@]}" -gt 0 ] || [ -n "${USB_DEV}" ]; then
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

# qemu-usb on the graphical path runs QEMU as the INVOKING USER (below) — a root
# GTK client fails to authorize to the user's Wayland/X session ("authorization
# failed"), the same reason the image path runs as the user. The user therefore
# needs READ access to the raw device. Grant it just for this run via sudo (an
# ACL, falling back to chmod o+r) rather than permanent 'disk' group membership
# or running all of QEMU as root. snapshot=on (above) keeps the open read-only,
# so read access is all that's required and the physical stick is never written.
if [ -n "${USB_DEV}" ] && [ "${#GFX_ARGS[@]}" -gt 0 ] && [ ! -r "${USB_DEV}" ]; then
  echo "Granting $(id -un) read access to ${USB_DEV} for this read-only boot..."
  sudo setfacl -m "u:$(id -un):r" "${USB_DEV}" 2>/dev/null \
    || sudo chmod o+r "${USB_DEV}"
fi

# Privilege model:
#  - Graphical guest (aarch64), IMAGE or USB device: run QEMU as the INVOKING
#    USER. GTK then maps its window in the user's OWN Wayland/X session. Running
#    QEMU as root does NOT display: a root GTK client connects to the user's
#    Wayland socket but the compositor refuses to authorize a cross-UID window
#    ("authorization failed"), so nothing appears. Root is unnecessary anyway —
#    the bridge attaches via the setuid qemu-bridge-helper, the image is opened
#    read-only via snapshot=on, and for a USB device boot the user was granted
#    read access just above (so QEMU-as-user can still read the raw device).
#  - Headless x86 (-nographic, KVM + bridge): keep sudo/root (no display to map).
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
