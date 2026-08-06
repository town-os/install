#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: qemu.sh IMAGE}"
VM_DISK_SIZE="${VM_DISK_SIZE:?VM_DISK_SIZE is required}"
VM_MEMORY="${VM_MEMORY:?VM_MEMORY is required}"
# vCPU count. QEMU defaults to a single vCPU, which starves services that size
# their worker pools to the CPU count — notably rolodex, whose tokio runtime is
# left unpinned so it scales to the machine (1 vCPU -> 1 worker -> cold recursive
# lookups serialize and time out under load). Give the dev VM several cores so it
# behaves like real multi-core hardware; override with VM_CPUS=N. Defaults to every
# core the host has (this builds/runs on a workstation, not a laptop), falling back
# to 4 where nproc isn't available.
VM_CPUS="${VM_CPUS:-$(nproc 2>/dev/null || echo 4)}"
VM_BRIDGE="${VM_BRIDGE:?VM_BRIDGE is required}"
FOREGROUND="${FOREGROUND:-0}"

# Expose the NAT'd guest to the LAN (see make/vm-relay.sh) so other devices on
# the wireless network — a phone running the Town OS client — can reach it.
# On by default; set VM_LAN=0 to turn it off.
VM_LAN="${VM_LAN:-1}"

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

# Prime sudo ONCE, up front, on the real terminal.
#
# Everything below that touches host state needs root: libvirt networking,
# sysctl/ip-link on the bridge, an ACL on the raw USB device, and — on the
# headless path — QEMU itself. Those calls are scattered, and many run inside
# `$(sudo … 2>/dev/null)` command substitutions where sudo's password PROMPT is
# redirected to /dev/null. With a cold credential cache the first such call
# blocks the terminal waiting for a password nobody can see; confused retries and
# timeouts then feed pam_faillock until the account LOCKS OUT for every session
# and user. Validating (and caching) the timestamp here, before any redirected
# call, means every later `sudo` hits the warm cache and never re-prompts — one
# visible prompt instead of many invisible ones. Fail loudly rather than let the
# blind calls hammer faillock if we can't get root.
if ! sudo -v; then
  echo "error: this target needs sudo (libvirt networking, device access, QEMU)." >&2
  exit 1
fi

# From here on sudo must NEVER prompt again. We primed the credential cache just
# above; shadow `sudo` with a wrapper that forces every later call non-interactive
# (-n). If the cache somehow expires or auth breaks mid-run, sudo then fails
# INSTANTLY instead of blocking on an (often /dev/null-redirected, invisible)
# prompt and feeding pam_faillock. Under `set -e` that failure aborts the whole
# script — which is what we want: any sudo failure stops everything rather than
# half-configuring the host or launching a broken VM. `command sudo` avoids the
# function recursing into itself.
sudo() { command sudo -n "$@"; }

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
    # `|| true`: when the network has NO <forwarder> yet (first run on this host),
    # the grep matches nothing and exits 1, which under `set -euo pipefail` would
    # kill qemu.sh here — silently, before QEMU ever launches. An empty DNS_HAVE
    # is the correct "no forwarders configured" value, so tolerate the failure.
    DNS_HAVE=$(sudo virsh net-dumpxml --inactive default 2>/dev/null \
      | grep -oE "<forwarder addr='[0-9.]+'/>" \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | tr '\n' ' ') || true
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

# Reconcile the guest IPv6 block on libvirt's 'default' network with whether we
# actually WANT to give the guest v6 (VM_NET6_PREFIX non-empty after the
# reachability gate above). This must work in BOTH directions: add the block when
# we want v6 and it's absent, AND remove it when we don't want v6 but a previous
# run (on a v6-capable network) left the block behind. The removal half is not
# optional: without it, a guest booted on a v6-less network still gets a SLAAC
# address and a libvirt-advertised v6 DEFAULT ROUTE that goes nowhere (libvirt
# does not NAT IPv6), so happy-eyeballs / AAAA lookups in ttyforce's initrd reach
# for dead v6 and report "can't connect externally" even though IPv4 NAT works.
# Only touch the 'default' network when its bridge is the one we attach to. Writes
# only the PERSISTENT definition; the cold-start block below makes it live.
if command -v virsh >/dev/null 2>&1 \
   && [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ]; then
  HAS_V6_PERSIST=""
  sudo virsh net-dumpxml --inactive default 2>/dev/null | grep -q "family='ipv6'" && HAS_V6_PERSIST="x"
  if [ -n "${VM_NET6_PREFIX}" ]; then
    # Want v6. Guest's stable SLAAC address: EUI-64 interface id from the stable
    # MAC 52:54:00:o4:o5:o6 -> ::5054:ff:fe<o4>:<o5><o6> (U/L bit of 0x52 flipped
    # to 0x50, ff:fe inserted). VM_IP6 overrides the printed address if you
    # statically assign one in the guest instead.
    O4=$(echo "${MAC}" | cut -d: -f4); O5=$(echo "${MAC}" | cut -d: -f5); O6=$(echo "${MAC}" | cut -d: -f6)
    GUEST_IP6="${VM_IP6:-${VM_NET6_PREFIX}::5054:ff:fe${O4}:${O5}${O6}}"
    if [ -z "${HAS_V6_PERSIST}" ]; then
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
  elif [ -n "${HAS_V6_PERSIST}" ]; then
    # Don't want v6 but a stale block is present (we moved to a v6-less network):
    # strip every <ip family='ipv6'> block. awk drops a self-closing tag outright,
    # otherwise skips through the matching </ip>.
    IP6_NEW_XML=$(sudo virsh net-dumpxml --inactive default 2>/dev/null \
      | awk '
          /<ip family=.ipv6./ { if ($0 ~ /\/>/) next; skip=1; next }
          skip && /<\/ip>/     { skip=0; next }
          skip                 { next }
          { print }')
    IP6_TMPXML=$(mktemp)
    printf '%s\n' "${IP6_NEW_XML}" > "${IP6_TMPXML}"
    if sudo virsh net-define "${IP6_TMPXML}" >/dev/null 2>&1; then
      echo "Removed stale guest IPv6 from libvirt 'default' (host has no working v6 route);"
      echo "  the dead v6 default route was breaking the guest's external-connectivity check."
    fi
    rm -f "${IP6_TMPXML}"
  fi
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

# Make the persistent-only edits above (the IPv6 block AND the DNS forwarders)
# actually LIVE for the guest about to boot. net-define only updates the
# PERSISTENT config, so a network that was already running keeps its OLD v6 state
# and OLD forwarders until a cold start. Both directions of drift break the guest:
# a stale v6 block gives it a dead v6 default route, and stale forwarders point
# its DNS at a previous network's servers (e.g. 50.0.1.1 after a WiFi change) so
# resolution and ttyforce's external check fail. Cold-start when the LIVE network
# disagrees with the PERSISTENT definition we just wrote — but ONLY when no other
# VM is attached to the bridge, since net-destroy would cut co-running VMs (the
# bridge's own ${VM_BRIDGE}-nic stub doesn't count). With other VMs present we
# leave it and print how to apply later.
if command -v virsh >/dev/null 2>&1 \
   && [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Bridge:/{print $2}')" = "${VM_BRIDGE}" ]; then
  LIVE_XML=$(sudo virsh net-dumpxml default 2>/dev/null)
  PERSIST_XML=$(sudo virsh net-dumpxml --inactive default 2>/dev/null)
  _v6_state() { printf '%s\n' "$1" | grep -q "family='ipv6'" && echo v6 || echo no6; }
  _fwd_state() { printf '%s\n' "$1" | grep -oE "<forwarder addr='[0-9.]+'/>" | sort | tr '\n' ' '; }
  if [ "$(_v6_state "${LIVE_XML}")" != "$(_v6_state "${PERSIST_XML}")" ] \
     || [ "$(_fwd_state "${LIVE_XML}")" != "$(_fwd_state "${PERSIST_XML}")" ]; then
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
        echo "Cold-started libvirt 'default' to apply pending IPv6/DNS-forwarder changes (no other VMs were attached)."
      fi
    else
      echo "NOTE: libvirt 'default' has pending IPv6/DNS-forwarder changes and other VMs are on ${VM_BRIDGE};"
      echo "      this guest won't pick them up until: sudo virsh net-destroy default && sudo virsh net-start default"
    fi
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

# Guest architecture. Defaults to the host arch (the native, KVM-accelerated
# path — x86_64 host -> x86_64 guest, aarch64 host -> aarch64 guest). QEMU_ARCH
# overrides it to boot a USB image of a DIFFERENT architecture (set by the
# `make qemu-usb TARGET=aarch64` path so an aarch64 stick can be tested on an
# x86_64 host). A foreign QEMU_ARCH runs qemu-system-<arch> under full-system
# TCG emulation (a whole emulated MACHINE — NOT binfmt/qemu-user, NOT
# cross-anything; the guest kernel runs as native code inside the emulated box),
# with KVM disabled (the ACCEL block below gates KVM on arch == host arch). This
# is the same scoped, opt-in exception the emulated aarch64 image *build* uses:
# native same-arch boots keep the KVM fast path; only an explicit foreign arch
# emulates, and it is slow.
HOST_ARCH=$(uname -m)
ARCH="${QEMU_ARCH:-${HOST_ARCH}}"
QEMU_BIN="qemu-system-${ARCH}"
if ! command -v "${QEMU_BIN}" >/dev/null 2>&1; then
  echo "error: ${QEMU_BIN} not found — install QEMU for this architecture." >&2
  exit 1
fi

# RPI=1 (set by `make qemu-usb TARGET=rpi`) boots a Raspberry Pi image. A Pi
# image has NO UEFI bootloader — the build stages kernel8.img/initramfs/config.txt
# on the FAT partition and real Pi GPU firmware loads the kernel directly. QEMU's
# 'virt' machine can't run that firmware flow, so booting a Pi image through edk2
# just drops to the UEFI shell ("no bootable device"). Instead we DIRECT-KERNEL-
# BOOT: extract the kernel + initramfs from the stick's FAT partition and hand
# them to QEMU with -kernel/-initrd, no UEFI. Pi-only, aarch64-only.
RPI="${RPI:-}"
if [ -n "${RPI}" ] && [ "${ARCH}" != "aarch64" ]; then
  echo "error: RPI is aarch64-only; use 'make qemu-usb TARGET=rpi' (got arch '${ARCH}')." >&2
  exit 1
fi

# RG35XX=1 (set by `make qemu-usb TARGET=rg35xxpro`) boots an Anbernic RG35XX
# card. Same problem as the Pi, one step further: that image's bootloader is
# U-Boot living in the card's RAW SECTORS, which only an Allwinner BootROM ever
# reads — QEMU 'virt' has no such BootROM, and edk2 finds no EFI binary because
# the image has none. So take the same escape hatch: DIRECT-KERNEL-BOOT the
# Image + initramfs staged on the FAT partition.
#
# What this DOES test: the initrd, ttyforce, the squashfs/overlay root, and the
# whole Town OS stack on aarch64 — the kernel is the same generic linux-aarch64
# the TARGET=aarch64 image uses. What it CANNOT test: U-Boot, the DTB, and every
# H700-specific driver, since 'virt' is not an H700. Real-hardware boot is still
# the only proof of those.
RG35XX="${RG35XX:-}"
if [ -n "${RG35XX}" ] && [ "${ARCH}" != "aarch64" ]; then
  echo "error: RG35XX is aarch64-only; use 'make qemu-usb TARGET=rg35xxpro' (got arch '${ARCH}')." >&2
  exit 1
fi
if [ -n "${RPI}" ] && [ -n "${RG35XX}" ]; then
  echo "error: RPI and RG35XX are different boards — set only one." >&2
  exit 1
fi

# Architecture-specific machine, firmware, and display.
MACHINE_ARGS=()
FIRMWARE_ARGS=()
KERNEL_ARGS=()
GFX_ARGS=()
case "${ARCH}" in
  x86_64)
    # SeaBIOS is built into qemu-system-x86_64; no firmware args needed. Give the
    # guest a graphical console window, same as the aarch64 path. The PC machine
    # already has a default VGA adapter, so no virtio-gpu is needed here.
    #
    # A usb-tablet IS needed, even though the PC machine has a built-in PS/2
    # mouse. WHY: the PS/2 mouse is a RELATIVE pointing device, and a relative
    # pointer forces QEMU's GTK display to grab and confine the host cursor to
    # sync it with the guest's. On Wayland/Hyprland that grab is taken and
    # released inconsistently, and when it drops the host pointer can land
    # outside the QEMU window — which, under focus-follows-mouse (Hyprland's
    # default, input:follow_mouse=1), moves KEYBOARD focus off the VM instantly
    # and with no visible cue. Keystrokes then go to whatever sits under the
    # cursor and the VM looks frozen mid-typing, which is indistinguishable from
    # a guest lockup (the guest is fine; it simply stops being sent input). It
    # bites hardest on long entries like the installer's GitHub-username field,
    # where there is time for the pointer to drift. usb-tablet reports ABSOLUTE
    # coordinates, so QEMU never needs a pointer grab at all and focus stays put.
    # usb-kbd comes along for parity with the aarch64 path and to keep fast
    # typing off the legacy PS/2 queue; the PS/2 keyboard remains as a fallback.
    # Both ride the -device qemu-xhci controller added below, and the guest-side
    # drivers are already in the initrd (xhci_pci/xhci_hcd in configure.sh's
    # WANT_MODULES, plus the mkinitcpio `keyboard` hook for usbhid), so they work
    # in the ttyforce installer too — not just after switch_root.
    GFX_ARGS=(-device usb-kbd -device usb-tablet -display gtk)
    ;;
  aarch64)
    MACHINE_ARGS=(-machine virt,gic-version=max)
    if [ -n "${RPI}" ] || [ -n "${RG35XX}" ]; then
      # Native-boot image (Pi or RG35XX): DIRECT-KERNEL-BOOT, no firmware stage.
      # Neither image has a UEFI binary — the Pi is loaded by the GPU bootloader
      # from config.txt, the RG35XX by U-Boot from the card's raw sectors — and
      # QEMU 'virt' can run neither flow, so booting either through edk2 just
      # drops to the UEFI shell. Instead extract the kernel + initramfs (+ the
      # kernel command line) that the build staged on the FAT partition and hand
      # them to QEMU with -kernel/-initrd. The disk itself is still attached
      # below, so the initrd finds the ext4 data/root.sfs via root=UUID=; direct
      # boot only replaces the firmware/bootloader stage.
      if [ -n "${RPI}" ]; then
        DB_BOARD="Pi"; DB_KERNEL="kernel8.img"
      else
        DB_BOARD="RG35XX"; DB_KERNEL="Image"
      fi
      #
      # Locate the FAT partition (part 2 of the GPT — part 1 is the unused
      # BIOS-boot slot). For a physical block device, lsblk lists the disk then
      # its partitions in order, so line 3 is part 2. For an image file attach a
      # partscan loop just to read it (the guest still boots from the file
      # itself, so detach the loop right after extraction).
      DB_LOOP=""
      if [ -b "${BOOT_SRC}" ]; then
        _p2=$(lsblk -rno NAME "${BOOT_SRC}" 2>/dev/null | sed -n '3p')
        # Not `[ -n ] && assign`: as the last statement of this branch an empty
        # _p2 would make the whole branch return 1 and `set -e` would kill the
        # script silently, before the explanatory error below can be printed.
        if [ -n "${_p2}" ]; then BOOTFS_PART="/dev/${_p2}"; fi
      else
        DB_LOOP=$(sudo losetup -Pf --show "${BOOT_SRC}")
        BOOTFS_PART="${DB_LOOP}p2"
      fi
      if [ -z "${BOOTFS_PART:-}" ] || [ ! -b "${BOOTFS_PART}" ]; then
        echo "error: could not find the FAT (part 2) partition on ${BOOT_SRC}." >&2
        [ -n "${DB_LOOP}" ] && sudo losetup -d "${DB_LOOP}" 2>/dev/null || true
        exit 1
      fi
      DB_MNT=$(mktemp -d)
      DB_KDIR=$(mktemp -d "${TMPDIR:-/tmp}/town-directboot.XXXXXX")
      if ! sudo mount -o ro "${BOOTFS_PART}" "${DB_MNT}"; then
        echo "error: could not mount ${BOOTFS_PART} (the FAT boot partition)." >&2
        [ -n "${DB_LOOP}" ] && sudo losetup -d "${DB_LOOP}" 2>/dev/null || true
        exit 1
      fi
      # The kernel command line lives in cmdline.txt on the Pi (firmware format)
      # and in the APPEND of extlinux.conf's first LABEL on the RG35XX (U-Boot
      # syslinux format) — that first label is `townos`, the default entry.
      if [ -n "${RPI}" ]; then
        DB_CMDLINE=$(sudo cat "${DB_MNT}/cmdline.txt" 2>/dev/null) || DB_CMDLINE=""
      else
        DB_CMDLINE=$(sudo awk '/^[[:space:]]*APPEND /{sub(/^[[:space:]]*APPEND /,""); print; exit}' \
          "${DB_MNT}/extlinux/extlinux.conf" 2>/dev/null) || DB_CMDLINE=""
      fi
      if ! sudo cp "${DB_MNT}/${DB_KERNEL}" "${DB_MNT}/initramfs-linux.img" "${DB_KDIR}/" 2>/dev/null \
         || [ -z "${DB_CMDLINE}" ]; then
        echo "error: ${BOOTFS_PART} is missing ${DB_KERNEL}/initramfs-linux.img or its kernel cmdline." >&2
        echo "       Is this actually a ${DB_BOARD} image?" >&2
        sudo umount "${DB_MNT}"; rmdir "${DB_MNT}"
        [ -n "${DB_LOOP}" ] && sudo losetup -d "${DB_LOOP}" 2>/dev/null || true
        exit 1
      fi
      sudo umount "${DB_MNT}"; rmdir "${DB_MNT}"
      [ -n "${DB_LOOP}" ] && sudo losetup -d "${DB_LOOP}" 2>/dev/null || true
      sudo chown "$(id -u):$(id -g)" "${DB_KDIR}/${DB_KERNEL}" "${DB_KDIR}/initramfs-linux.img"
      # Rewrite the kernel command line for QEMU 'virt'. The console name is the
      # board's, and 'virt' has only a PL011 at ttyAMA0:
      #
      # 1. Pi: the firmware rewrites the `serial0` alias to the board's real
      #    UART; there is no such alias here, so serial0 -> ttyAMA0.
      #    RG35XX: the H700's UART0 is a DesignWare 8250 (ttyS0), which 'virt'
      #    does not have either — ttyS0 -> ttyAMA0.
      #    root=UUID=/rootfstype/rootwait/rw are kept verbatim so the squashfs
      #    initrd finds the data partition.
      #
      # 2. DROP console=tty1 (Pi only; the RG35XX cmdline has no tty0/tty1 at
      #    all — mainline has no display driver for that board).
      #    WHY: the linux-rpi kernel is built purely for real Pi display hardware
      #    (vc4/v3d/pl111/DSI panels) and has NO driver for any display QEMU's
      #    'virt' machine can emulate — no virtio_gpu, no bochs, no VGA, no
      #    simpledrm. So tty1 can NEVER get a framebuffer here; it is a permanently
      #    dead console. The town-installer initrd hook points ttyforce at the
      #    *last* console (`--tty /dev/$last_console`), so with tty1 present-and-last
      #    ttyforce launches on the dead framebuffer and exits 1, wedging the boot
      #    with no root provisioned. Removing tty1 runs the installer on ttyAMA0,
      #    which is wired to the foreground terminal below (headless serial). This
      #    is a launch-time -append edit only; the real image on the card keeps its
      #    own console= (HDMI-primary on a real Pi, serial on a real RG35XX).
      DB_APPEND=$(printf '%s' "${DB_CMDLINE}" \
        | sed -e 's/console=serial0/console=ttyAMA0/g' -e 's/console=ttyS0/console=ttyAMA0/g' \
        | sed -E 's/[[:space:]]*console=tty1//g')
      KERNEL_ARGS=(
        -kernel "${DB_KDIR}/${DB_KERNEL}"
        -initrd "${DB_KDIR}/initramfs-linux.img"
        -append "${DB_APPEND}"
      )
      echo "${DB_BOARD} image: direct-kernel-boot (${DB_KERNEL} + initramfs from ${BOOTFS_PART}, no UEFI/U-Boot)"
      echo "  cmdline: ${DB_APPEND}"
      # Display. The two boards differ here, because their consoles do:
      #
      #   RG35XX: the image has NO serial console — `console=tty0` is the only
      #     entry, the installer runs on the panel, and the patched kernel has
      #     virtio_gpu — so the guest paints the GTK window exactly as the real
      #     device paints its LCD. That makes this the one emulation path that
      #     shows what a user actually sees. usb-kbd stands in for the handheld's
      #     buttons (which our device tree maps to the same keyboard codes).
      #   Pi: linux-rpi can drive no QEMU 'virt' display device at all (see
      #     above), so its serial console goes INSIDE the window as a GTK `vc`
      #     tab (-serial vc via SERIAL_VC, with show-tabs=on to expose the tab
      #     bar) — switch to the "serial0" tab to drive the installer there.
      if [ -n "${RG35XX}" ]; then
        GFX_ARGS=(-device virtio-gpu-pci -device usb-kbd -device usb-tablet -display gtk)
      else
        GFX_ARGS=(-device virtio-gpu-pci -device usb-kbd -device usb-tablet -display gtk,show-tabs=on)
        SERIAL_VC=1
      fi
    else
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
    fi
    ;;
  *)
    echo "error: unsupported host architecture '${ARCH}'." >&2
    exit 1
    ;;
esac

# CPU/acceleration. Use KVM + -cpu host whenever the guest arch equals the HOST
# arch and /dev/kvm is present — on BOTH x86_64 and aarch64 (incl. Apple Silicon
# / Asahi, where KVM does work). KVM is not just a speed-up here: under pure TCG
# emulation a full aarch64 UEFI boot (firmware -> GRUB -> kernel) is so slow that
# the guest takes many minutes to even initialize the framebuffer, so the display
# appears blank. With KVM the kernel is up and painting tty0 within seconds.
# A FOREIGN guest arch (QEMU_ARCH != host, e.g. an aarch64 USB stick on x86_64)
# cannot use KVM at all — the host CPU can't virtualize a different ISA — so it
# falls through to TCG regardless of /dev/kvm. Expect it to be very slow.
ACCEL_ARGS=()
if [ "${ARCH}" = "${HOST_ARCH}" ] && [ -e /dev/kvm ]; then
  ACCEL_ARGS=(-enable-kvm -cpu host)
else
  ACCEL_ARGS=(-cpu max)
  if [ "${ARCH}" != "${HOST_ARCH}" ]; then
    echo "note: emulating ${ARCH} on a ${HOST_ARCH} host under full-system TCG (no KVM for a" >&2
    echo "      foreign arch). This is SLOW — an aarch64 UEFI boot can take minutes to paint." >&2
  else
    echo "note: /dev/kvm absent — running native ${ARCH} under TCG. An aarch64 UEFI" >&2
    echo "      boot under TCG is extremely slow; the display may stay blank for minutes." >&2
  fi
fi

# HMP monitor on a unix socket, exported on every path that has a window or runs
# in the background. WHY: when the guest looks "locked up" there is otherwise no
# way to tell a wedged kernel from a console that simply isn't receiving
# keystrokes. The monitor answers both — `screendump` captures the guest
# framebuffer regardless of whether the window ever mapped or which workspace it
# landed on, and `sendkey` injects input straight into the guest, bypassing the
# compositor entirely. It costs nothing when unused.
#   socat - UNIX-CONNECT:/tmp/town-os-monitor.sock
MONITOR_SOCK="/tmp/town-os-monitor.sock"

DAEMON_ARGS=()
SERIAL_ARGS=()
MONITOR_ARGS=()
if [ "${FOREGROUND}" != "1" ]; then
  DAEMON_ARGS=(-daemonize -pidfile qemu.pid)
  SERIAL_ARGS=(-serial "unix:/tmp/town-os-serial.sock,server=on,wait=off")
  MONITOR_ARGS=(-monitor "unix:${MONITOR_SOCK},server=on,wait=off")
elif [ "${#GFX_ARGS[@]}" -gt 0 ]; then
  # Graphical foreground (aarch64). Normally the console is the GTK VGA window and
  # the serial port is exported on a socket for `make serial`. The emulated
  # native-boot images (SERIAL_VC: Pi, RG35XX) have no usable VGA, so their
  # serial console goes to a GTK
  # `vc` instead — it shows up as the "serial0" tab IN the window and is the
  # interactive console there (no socket, no `make serial`).
  DAEMON_ARGS=(-pidfile qemu.pid)
  if [ -n "${SERIAL_VC:-}" ]; then
    SERIAL_ARGS=(-serial vc)
  else
    SERIAL_ARGS=(-serial "unix:/tmp/town-os-serial.sock,server=on,wait=off")
  fi
  MONITOR_ARGS=(-monitor "unix:${MONITOR_SOCK},server=on,wait=off")
else
  # Headless foreground (x86_64, and the emulated Pi boot whose linux-rpi kernel
  # can drive no QEMU display): multiplex the serial console onto stdio. The
  # monitor is already reachable there via the stdio mux (Ctrl-a c), so no
  # separate socket is exported.
  DAEMON_ARGS=(-pidfile qemu.pid)
  SERIAL_ARGS=(-nographic -serial mon:stdio)
fi

# Pin a stable DHCP lease for this VM via a MAC-keyed reservation on libvirt's
# default network. WHY: the guest presents a fresh DHCP client-id (a dhcpcd
# DUID) on every boot — its root is read-only squashfs, so the DUID isn't
# persisted — and dnsmasq keys leases on the client-id ahead of the MAC. Without
# a reservation the VM therefore gets a NEW address every boot (.9 -> .10 -> ..),
# which silently breaks `make vm-ip` and the guest's mDNS record, and moves the
# target of any host->guest port relay. A MAC reservation forces a fixed IP
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

# Pass a physical phone through to the guest (USB_PHONE).
#
# This is USB *passthrough* of a live device — unrelated to USB_DEV above, which
# is a block device the VM BOOTS from. The guest sees the phone as if it were
# plugged into it, which is what makes USB tethering work: enable tethering on
# the phone and the box gets a network interface with the phone on the other end,
# giving the two direct IP reachability without touching libvirt's NAT.
#
# USB_PHONE accepts:
#   auto        - find the single attached Android device (see the vendor list)
#   vid:pid     - e.g. 18d1:4ee1
#   bus.port    - e.g. 1.1 (already a physical port, used as-is)
#
# We resolve everything to **hostbus/hostport**, never vendorid/productid, and
# that choice is load-bearing: a phone's product ID CHANGES when its USB mode
# changes. A Pixel is 18d1:4ee1 in MTP mode and a different product ID once USB
# debugging is on. Pinning vid:pid would therefore drop the device out of the
# guest the moment you enable adb — exactly when you need it. The physical port
# does not move, so hostport survives mode switches and re-plugs.
USB_PHONE="${USB_PHONE:-}"
USB_PHONE_ARGS=()

if [ -n "${USB_PHONE}" ]; then
  phone_syspath=""

  case "${USB_PHONE}" in
    auto)
      # Known Android vendor IDs: Google, Samsung, OnePlus, Xiaomi, Motorola,
      # Sony, LG, HTC, Huawei, Fairphone(=Google), Nothing(=Qualcomm bootloader).
      for dev in /sys/bus/usb/devices/*/; do
        vid="$(cat "${dev}/idVendor" 2>/dev/null || true)"
        case "${vid}" in
          18d1|04e8|2a70|2717|22b8|0fce|1004|0bb4|12d1|05c6)
            if [ -n "${phone_syspath}" ]; then
              echo "error: more than one Android device attached; set USB_PHONE=vid:pid or bus.port" >&2
              exit 1
            fi
            phone_syspath="${dev}"
            ;;
        esac
      done
      if [ -z "${phone_syspath}" ]; then
        echo "error: USB_PHONE=auto found no Android device. Is it plugged in and enumerated?" >&2
        echo "       Check with: lsusb" >&2
        exit 1
      fi
      ;;
    *:*)
      want_vid="${USB_PHONE%%:*}"
      want_pid="${USB_PHONE##*:}"
      for dev in /sys/bus/usb/devices/*/; do
        vid="$(cat "${dev}/idVendor" 2>/dev/null || true)"
        pid="$(cat "${dev}/idProduct" 2>/dev/null || true)"
        if [ "${vid}" = "${want_vid}" ] && [ "${pid}" = "${want_pid}" ]; then
          phone_syspath="${dev}"
          break
        fi
      done
      if [ -z "${phone_syspath}" ]; then
        echo "error: no USB device matching ${USB_PHONE}. Check: lsusb" >&2
        exit 1
      fi
      ;;
    *.*)
      # Already a bus.port — use it verbatim.
      USB_PHONE_ARGS=(-device "usb-host,hostbus=${USB_PHONE%%.*},hostport=${USB_PHONE##*.}")
      ;;
    *)
      echo "error: USB_PHONE must be 'auto', 'vid:pid', or 'bus.port' (got '${USB_PHONE}')" >&2
      exit 1
      ;;
  esac

  if [ -n "${phone_syspath}" ]; then
    phone_bus="$(cat "${phone_syspath}/busnum")"
    phone_dev="$(cat "${phone_syspath}/devnum")"
    # devpath is the physical port chain ("1", or "2.3" behind a hub) — exactly
    # what QEMU's hostport wants.
    phone_port="$(cat "${phone_syspath}/devpath")"
    phone_name="$(cat "${phone_syspath}/product" 2>/dev/null || echo 'USB device')"

    echo "Passing through ${phone_name} (bus ${phone_bus}, port ${phone_port}) to the guest."
    USB_PHONE_ARGS=(-device "usb-host,hostbus=${phone_bus},hostport=${phone_port}")

    # The graphical path runs QEMU as the invoking user (see the privilege model
    # below), and /dev/bus/usb nodes are root-owned. QEMU must open the device
    # read-WRITE to drive it, so grant an ACL for this run — same approach as the
    # USB_DEV block below, rather than adding the user to a group permanently.
    usb_node="/dev/bus/usb/$(printf '%03d' "${phone_bus}")/$(printf '%03d' "${phone_dev}")"
    if [ "${#GFX_ARGS[@]}" -gt 0 ] && [ ! -w "${usb_node}" ]; then
      echo "Granting $(id -un) access to ${usb_node} for this run..."
      sudo setfacl -m "u:$(id -un):rw" "${usb_node}" 2>/dev/null \
        || sudo chmod o+rw "${usb_node}"
    fi

    # Passthrough DETACHES the phone from the host: adb, MTP and everything else
    # on this machine stop seeing it until the VM releases it. Say so, because
    # otherwise it looks like the cable failed again.
    echo "Note: the host loses the phone while the VM holds it (adb included)."
  fi
fi

# --- Game controller passthrough -------------------------------------------
#
# The RG35XX installer is driven ENTIRELY by a gamepad: ttyforce reads the pad
# through gilrs/evdev, and its on-screen keyboard — the only way to type a WiFi
# password on a device with no keyboard — is raised by Start and typed on with
# the face buttons. Emulating that image without a pad therefore exercises the
# boot but not the part most likely to be wrong, so hand the guest a REAL
# controller from the host.
#
# virtio-input-host passes the host evdev node straight through, capability
# bitmaps and all, so the guest sees BTN_SOUTH/BTN_DPAD_* exactly as the handheld
# presents them and gilrs classifies it as a gamepad. That is why this is not
# `-device usb-kbd`-style emulation: QEMU has no synthetic gamepad, and a fake
# keyboard would test the wrong input path entirely. It also works for Bluetooth
# pads, which USB passthrough cannot do.
#
# GAMEPAD:
#   unset / auto  auto-detect, but only for an RG35XX guest (the one whose
#                 installer has no other input device). Nothing is grabbed on
#                 other targets unless asked for by path.
#   /dev/input/eventN   use exactly this device, on any target
#   0 | off | none      never
#
# The HOST LOSES THE CONTROLLER while the VM holds it (virtio-input-host issues
# an EVIOCGRAB), the same trade as USB_PHONE.
GAMEPAD="${GAMEPAD:-auto}"
PAD_ARGS=()
PAD_DEV=""
_detect_gamepad() {
  for _e in /dev/input/event*; do
    [ -e "${_e}" ] || continue
    # ID_INPUT_JOYSTICK is udev's own classification, which is what every other
    # gamepad-aware program keys off — more reliable than guessing from names.
    if udevadm info --query=property --name="${_e}" 2>/dev/null \
       | grep -q '^ID_INPUT_JOYSTICK=1'; then
      echo "${_e}"
      return 0
    fi
  done
  return 1
}
case "${GAMEPAD}" in
  0|off|no|none|"") ;;
  auto)
    if [ -n "${RG35XX}" ]; then
      PAD_DEV=$(_detect_gamepad || true)
      if [ -z "${PAD_DEV}" ]; then
        echo "note: no game controller found on the host (udev ID_INPUT_JOYSTICK)."
        echo "      The RG35XX installer is gamepad-driven — its on-screen keyboard"
        echo "      cannot be raised without one. Plug a controller in, or drive the"
        echo "      guest with the emulated USB keyboard instead."
      fi
    fi
    ;;
  /dev/input/event*)
    if [ ! -e "${GAMEPAD}" ]; then
      echo "error: GAMEPAD='${GAMEPAD}' does not exist." >&2
      exit 1
    fi
    PAD_DEV="${GAMEPAD}"
    ;;
  *)
    echo "error: GAMEPAD must be auto, 0, or a /dev/input/eventN path (got '${GAMEPAD}')." >&2
    exit 1
    ;;
esac
if [ -n "${PAD_DEV}" ]; then
  # Read-WRITE, unlike the boot device: virtio-input-host opens the evdev node
  # O_RDWR to grab it (and to drive force feedback).
  if [ ! -w "${PAD_DEV}" ]; then
    echo "Granting $(id -un) access to ${PAD_DEV} for this run..."
    sudo setfacl -m "u:$(id -un):rw" "${PAD_DEV}" 2>/dev/null \
      || sudo chmod o+rw "${PAD_DEV}"
  fi
  PAD_ARGS=(-device "virtio-input-host-pci,evdev=${PAD_DEV}")
  echo "Game controller: ${PAD_DEV} -> guest (the host cannot use it until the VM exits)"
fi

# Assemble the full QEMU command line as an array.
QEMU_CMD=(
  "${QEMU_BIN}"
  "${ACCEL_ARGS[@]}"
  "${MACHINE_ARGS[@]}"
  "${FIRMWARE_ARGS[@]}"
  "${KERNEL_ARGS[@]}"
  -m "${VM_MEMORY}"
  -smp "${VM_CPUS}"
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
  "${USB_PHONE_ARGS[@]}"
  "${PAD_ARGS[@]}"
  "${GFX_ARGS[@]}"
  "${SERIAL_ARGS[@]}"
  "${MONITOR_ARGS[@]}"
  "${DAEMON_ARGS[@]}"
)

# A prior root run may have left a root-owned serial socket; clear it either way.
rm -f /tmp/town-os-serial.sock 2>/dev/null || sudo rm -f /tmp/town-os-serial.sock 2>/dev/null || true
rm -f "${MONITOR_SOCK}" 2>/dev/null || sudo rm -f "${MONITOR_SOCK}" 2>/dev/null || true

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
#  - Headless (-nographic): keep sudo/root — there is no display to map, so the
#    cross-UID Wayland problem doesn't apply. Covers the x86 image path (KVM +
#    bridge) and the emulated Pi boot (TARGET=rpi), whose linux-rpi kernel can
#    drive no QEMU display so it runs serial-on-stdio. The Pi boot's /dev/sda is
#    opened snapshot=on (read-only) and root reads the raw device directly, so no
#    per-user ACL is needed on that path.
# Start the LAN relay before QEMU so it is already listening when the guest
# finishes booting. socat happily listens against a guest that isn't up yet —
# connections just fail until it is. It is detached with setsid so it survives
# this script exiting in the background (-daemonize) case; stop-qemu.sh reaps it
# via vm-relay.pid. In the foreground case the trap below tears it down with the
# VM, and vm-relay.sh's own trap removes its socats and firewall openings.
RELAY_PID=""

# Everything torn down when THIS script owns the VM's lifetime (FOREGROUND).
# One function and one EXIT trap: a second `trap ... EXIT` would silently
# replace the first, so the relay and the host-DNS switch have to share it.
fg_cleanup() {
  if [ -n "${RELAY_PID:-}" ]; then
    kill "${RELAY_PID}" 2>/dev/null || true
    rm -f vm-relay.pid
  fi
  # Give the host its resolver back — `make qemu-fg`/`qemu-usb` pointed it at a
  # VM that is gone the moment this returns. Idempotent, and a no-op when the
  # launch never switched it (VM_DNS=0, or no resolvectl on this host).
  "$(dirname "$0")/host-dns.sh" unset || true
}
# Registered up front, not inside the relay block below: the DNS switch needs
# undoing even when VM_LAN=0 or no reserved IP kept the relay from starting.
if [ "${FOREGROUND}" = "1" ]; then
  trap fg_cleanup EXIT
fi

if [ "${VM_LAN}" != "0" ]; then
  if [ -z "${RESERVED_IP:-}" ]; then
    echo "warning: no reserved guest IP (custom bridge?); skipping LAN access" >&2
  else
    # Launch the relay. In the FOREGROUND case keep it in this script's session
    # and controlling terminal (a plain background job — NO setsid) so its own
    # sudo calls reuse the credential we primed above: sudo's tty_tickets key the
    # cache to the terminal, so a setsid'd relay (new session, no controlling tty)
    # would miss that ticket and re-authenticate through an askpass helper — the
    # second, separate password prompt. The EXIT trap below reaps it. Only the
    # BACKGROUND (-daemonize) case needs setsid, because there qemu.sh exits while
    # the VM lives on so the relay must outlive it (and it authenticates on its
    # own tty-less session there; stop-qemu.sh reaps it via vm-relay.pid).
    if [ "${FOREGROUND}" = "1" ]; then
      GUEST_IP="${RESERVED_IP}" VM_BRIDGE="${VM_BRIDGE}" \
        "$(dirname "$0")/vm-relay.sh" &
    else
      GUEST_IP="${RESERVED_IP}" VM_BRIDGE="${VM_BRIDGE}" \
        setsid "$(dirname "$0")/vm-relay.sh" &
    fi
    RELAY_PID=$!
    echo "${RELAY_PID}" > vm-relay.pid
    # In the FOREGROUND case fg_cleanup (trapped above) reaps it. In the
    # background case qemu.sh exits while the VM keeps running, so the relay must
    # outlive it — stop-qemu.sh kills it instead.
  fi
fi

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
