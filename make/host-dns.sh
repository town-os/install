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

DROPIN_DIR=/run/systemd/resolved.conf.d
# 'zz-' sorts after anything the host distro ships, so this list is applied last.
DROPIN="${DROPIN_DIR}/zz-town-os-vm.conf"
# Remember which link we stripped, so `unset` reverts THAT one even if the
# default route has since moved (WiFi roam, VPN, dock).
STATE=/run/town-os-host-dns.link

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
if [ "${MODE}" = "unset" ] && [ ! -f "${DROPIN}" ] && [ ! -f "${STATE}" ]; then
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

echo "Host DNS -> ${VM_DNS} (Town OS VM)${UPLINK:+, ${UPLINK} link resolver cleared}"
echo "  restore with: make vm-dns-revert   (also done by 'make stop')"
