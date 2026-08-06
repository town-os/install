#!/usr/bin/env bash
# Point the HOST's systemd-resolved at the Town OS VM (rolodex), so the
# workstation resolves through the box exactly as a real client on the network
# would — .home names included — instead of through its own DHCP resolver.
#
#   host-dns.sh set     -> global DNS = $VM_DNS   (default: the VM's pinned IP)
#   host-dns.sh unset   -> restore whatever the host had before
#
# WHY a drop-in and not `resolvectl dns`: resolvectl only takes a LINK, and
# systemd-resolved exposes no D-Bus method for setting the GLOBAL server list at
# runtime. Global DNS is configuration-only, so this writes a drop-in and
# reloads resolved — the same mechanism scripts/bootstrap-dns.sh uses inside the
# image, including the leading empty `DNS=` reset line (resolved CONCATENATES
# DNS= across drop-ins, so without the reset the host's baked list would survive
# alongside the VM and resolved could latch onto the wrong one).
#
# WHY /run and not /etc: this is dev-VM state, not a host configuration change.
# It evaporates on reboot, so a workstation can never be left permanently
# pointed at a VM that no longer exists.
#
# WHY the uplink's DNS is cleared too: PER-LINK DNS OUTRANKS GLOBAL. A link that
# has DHCP-provided servers and a default route is a candidate for every name,
# so writing the global list alone would change nothing on a normal machine.
# `resolvectl dns <link> ""` drops those for the session; `resolvectl revert`
# puts them back, which is what `unset` does.
#
# Loop safety: the guest's own bootstrap resolver queries 192.168.122.1 (libvirt's
# dnsmasq, running on the HOST), which would normally forward to the host's
# resolv.conf -> resolved -> back to the guest. qemu.sh already breaks that by
# pinning the network's <dns><forwarder> to the host's real upstream servers, so
# the guest's fallback path never re-enters resolved. rolodex itself recurses
# from the roots and forwards nowhere by default.
set -euo pipefail

MODE="${1:-}"
case "${MODE}" in
  set|unset) ;;
  *) echo "usage: $0 set|unset" >&2; exit 2 ;;
esac

# These paths (and RESOLV_CONF/STUB below) are overridable purely so the
# set/unset cycle can be exercised against scratch files instead of the live
# host — nothing in the Makefile ever sets them.
DROPIN_DIR="${DROPIN_DIR:-/run/systemd/resolved.conf.d}"
# 'zz-' sorts after anything the host distro ships, so this list is applied last.
DROPIN="${DROPIN_DIR}/zz-town-os-vm.conf"
# Remember which link we stripped, so `unset` reverts THAT one even if the
# default route has since moved (WiFi roam, VPN, dock).
STATE="${STATE:-/run/town-os-host-dns.link}"

# resolv.conf handling (same testing seam as above).
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
STUB="${STUB:-/run/systemd/resolve/stub-resolv.conf}"
# What resolv.conf was before we touched it: "link:<target>" or "file" (with the
# original bytes alongside). Restoring the TYPE matters — a host whose file we
# replaced with a symlink must get its file back, not a dangling link.
RESOLV_STATE="${RESOLV_STATE:-/run/town-os-host-dns.resolv}"
RESOLV_BAK="${RESOLV_STATE}.bak"

# systemd-resolved is not universal (a host on plain resolv.conf, or NM's own
# dnsmasq). Don't fail a VM launch over it — say so and move on.
if ! command -v resolvectl >/dev/null 2>&1; then
  [ "${MODE}" = "set" ] && echo "note: no resolvectl on this host; skipping VM DNS" >&2
  exit 0
fi

# VM_DNS=0 (or empty) is the opt-out. In `set` that's a no-op; in `unset` we
# still run, so flipping the switch off after a launch actually cleans up.
VM_DNS="${VM_DNS:-}"
if [ "${MODE}" = "set" ] && { [ -z "${VM_DNS}" ] || [ "${VM_DNS}" = "0" ]; }; then
  exit 0
fi

# Nothing to undo -> return before touching sudo. This matters: stop.sh calls
# `unset` unconditionally, so without this early exit every `make stop` would
# prompt for a password just to discover there was no switch to reverse. Both
# paths live in /run and are world-readable, so the test needs no privilege.
if [ "${MODE}" = "unset" ] && [ ! -f "${DROPIN}" ] && [ ! -f "${STATE}" ] \
   && [ ! -f "${RESOLV_STATE}" ]; then
  exit 0
fi

# Every call below is privileged. Prime the credential ONCE, visibly, before any
# call whose output is redirected — a cold cache behind a swallowed prompt is
# what feeds pam_faillock and locks the account out (see qemu.sh).
if ! sudo -v; then
  echo "error: root is required to change the host's DNS" >&2
  exit 1
fi

reload_resolved() {
  # D-Bus, not the systemctl CLI (see CLAUDE.md).
  sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager ReloadUnit ss \
    "systemd-resolved.service" "replace" >/dev/null 2>&1 || true
}

if [ "${MODE}" = "unset" ]; then
  changed=0
  # Put resolv.conf back FIRST — restoring the host's own resolver path before
  # tearing down the servers it points at keeps the gap from being a window with
  # no working DNS at all.
  if [ -f "${RESOLV_STATE}" ]; then
    saved=$(sudo cat "${RESOLV_STATE}")
    case "${saved}" in
      link:*)
        sudo ln -sfn "${saved#link:}" "${RESOLV_CONF}"
        ;;
      file)
        # Restore via a temp file + `mv -fT`, NOT a plain cp onto the path: at
        # this point resolv.conf IS our symlink to the stub, and cp follows it —
        # it would write the backup THROUGH the link into the stub file itself,
        # corrupting resolved's stub and leaving resolv.conf a symlink forever.
        # mv -T replaces the link atomically, so there is also no instant where
        # the host has no resolv.conf at all.
        sudo cp --no-preserve=timestamps "${RESOLV_BAK}" "${RESOLV_CONF}.town-tmp"
        sudo mv -fT "${RESOLV_CONF}.town-tmp" "${RESOLV_CONF}"
        ;;
    esac
    sudo rm -f "${RESOLV_STATE}" "${RESOLV_BAK}"
    changed=1
  fi
  if [ -f "${DROPIN}" ]; then
    sudo rm -f "${DROPIN}"
    changed=1
  fi
  if [ -f "${STATE}" ]; then
    LINK=$(sudo cat "${STATE}")
    # revert restores the link to what networkd/NetworkManager last pushed
    # (i.e. the DHCP-provided servers and domains).
    [ -n "${LINK}" ] && sudo resolvectl revert "${LINK}" >/dev/null 2>&1 || true
    sudo rm -f "${STATE}"
    changed=1
  fi
  if [ "${changed}" -eq 1 ]; then
    reload_resolved
    echo "Host DNS restored"
  fi
  exit 0
fi

# --- set ---------------------------------------------------------------------

UPLINK=$(ip -o -4 route show default 2>/dev/null | awk '{ print $5; exit }')

new_content="# Written by make/host-dns.sh for the Town OS dev VM — do not edit.
# Removed by 'make vm-dns-revert' / 'make stop-qemu'.
[Resolve]
DNS=
DNS=${VM_DNS}
# ~. makes this the route of last resort for EVERY name, so split-horizon zones
# the VM hosts (.home) resolve here rather than falling through to a link.
Domains=~."

old_content=""
[ -f "${DROPIN}" ] && old_content=$(sudo cat "${DROPIN}")

if [ "${old_content}" != "${new_content}" ]; then
  sudo mkdir -p "${DROPIN_DIR}"
  printf '%s\n' "${new_content}" | sudo tee "${DROPIN}" >/dev/null
  reload_resolved
fi

# Re-assert the link strip on EVERY launch, not just when the drop-in changed:
# it is runtime-only state that NetworkManager/networkd re-push on any lease
# renewal, roam or reconnect, which would silently take resolution back.
if [ -n "${UPLINK}" ] && [ "${UPLINK}" != "${VM_BRIDGE:-virbr0}" ]; then
  printf '%s\n' "${UPLINK}" | sudo tee "${STATE}" >/dev/null
  sudo resolvectl dns "${UPLINK}" "" >/dev/null 2>&1 || true
  sudo resolvectl domain "${UPLINK}" "" >/dev/null 2>&1 || true
fi

# Put resolved IN THE RESOLUTION PATH, without which everything above is inert.
#
# All of the above configures systemd-resolved — but glibc does not ask resolved
# anything, it reads /etc/resolv.conf. On a host where that file is a real file
# written by NetworkManager (`resolvectl status` says "resolv.conf mode:
# foreign", the default on Arch/Manjaro with no dns= setting), it lists the DHCP
# servers DIRECTLY, so every lookup goes straight past resolved to the ISP's
# resolver and the VM is never consulted. Worse, it looks like it worked:
# `resolvectl status` cheerfully shows the VM as the global server, because in
# foreign mode resolved is merely READING that same file.
#
# So point resolv.conf at resolved's stub for the duration, recording exactly
# what was there (symlink target, or the file's bytes) to put back on revert.
# The stub is preferred over writing `nameserver <VM_DNS>` straight into
# resolv.conf: it keeps resolved as the broker, so mDNS/LLMNR still resolve the
# guest's own .local name (which qemu.sh sets up on the bridge) instead of being
# bypassed along with everything else.
if [ -e "${STUB}" ]; then
  # Already pointing into resolved (stub mode, or a previous run) -> leave it.
  CURRENT_TARGET=""
  [ -L "${RESOLV_CONF}" ] && CURRENT_TARGET=$(readlink "${RESOLV_CONF}")
  if [ "${CURRENT_TARGET}" != "${STUB}" ]; then
    # Record the ORIGINAL only once: a second launch must not overwrite the
    # saved state with our own symlink and lose the way back.
    if [ ! -f "${RESOLV_STATE}" ]; then
      if [ -n "${CURRENT_TARGET}" ]; then
        printf 'link:%s\n' "${CURRENT_TARGET}" | sudo tee "${RESOLV_STATE}" >/dev/null
      elif [ -e "${RESOLV_CONF}" ]; then
        sudo cp --no-preserve=timestamps "${RESOLV_CONF}" "${RESOLV_BAK}"
        printf 'file\n' | sudo tee "${RESOLV_STATE}" >/dev/null
      fi
    fi
    sudo ln -sfn "${STUB}" "${RESOLV_CONF}"
    echo "  ${RESOLV_CONF} -> ${STUB} (was: ${CURRENT_TARGET:-a static file}; restored on revert)"
  fi

  # NetworkManager in its default dns=default mode OWNS resolv.conf and will
  # rewrite it on the next connectivity change, silently taking resolution back
  # mid-session. Nothing here can prevent that without making a permanent change
  # to the host's configuration, which is not this script's business — so say so
  # once and name the one-line fix rather than papering over it.
  if ! (NetworkManager --print-config 2>/dev/null || cat /etc/NetworkManager/NetworkManager.conf 2>/dev/null) \
       | grep -qE '^\s*dns\s*=\s*(systemd-resolved|none)'; then
    if pgrep -x NetworkManager >/dev/null 2>&1; then
      echo "  note: NetworkManager may rewrite ${RESOLV_CONF} on the next network change." >&2
      echo "        To make this stick, set dns=systemd-resolved in NetworkManager.conf." >&2
    fi
  fi
else
  echo "  warning: ${STUB} missing — is systemd-resolved running? DNS not switched." >&2
fi

echo "Host DNS -> ${VM_DNS} (Town OS VM)${UPLINK:+, ${UPLINK} link resolver cleared}"
echo "  restore with: make vm-dns-revert   (also done by 'make stop')"
