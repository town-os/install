#!/usr/bin/env bash
# Point the HOST's name resolution at the Town OS VM (rolodex), so the
# workstation resolves through the box exactly as a real client on the network
# would — .home names included — instead of through its own DHCP resolver.
#
#   host-dns.sh set     -> host resolves through $VM_DNS (default: the VM's IP)
#   host-dns.sh unset   -> restore whatever the host had before
#
# This is a PORT OF ../town-os make/dns.sh (the `make dev` redirect), so the two
# repos switch the host's resolver by the same mechanism. Only the address
# differs: there rolodex runs on the host at 127.0.0.2, here it runs in the guest
# at $VM_DNS. Every behavioural decision below is that file's; the WHYs are kept
# verbatim in spirit because they are all failure modes someone already hit.
#
# BOTH HALVES ARE REWRITTEN, and neither alone is enough:
#
#  1. systemd-resolved's PER-LINK servers, on every link holding a default route
#     (v4 and v6). Rewriting resolv.conf alone is not enough on a resolved box:
#     anything resolving through nss-resolve or the D-Bus API (systemd units,
#     NetworkManager, some Chrome builds) never reads resolv.conf, so .home names
#     fail there while `dig` works — the exact split that makes dev DNS look
#     haunted. Per-link is also what OUTRANKS everything: a link with
#     DHCP-provided servers and a default route is a candidate for every name, so
#     a global setting alone changes nothing on a normal machine.
#
#     `~.` is what makes it stick: without a routing domain resolved is free to
#     prefer another link's servers for names it thinks they own, and a .home
#     query leaving for the LAN resolver is an NXDOMAIN.
#
#  2. /etc/resolv.conf, rewritten to a literal `nameserver $VM_DNS`. glibc does
#     not ask resolved anything, it reads this file. On a host where it is a real
#     file written by NetworkManager (`resolvectl status` says "resolv.conf mode:
#     foreign", the default on Arch/Manjaro with no dns= setting) it lists the
#     DHCP servers DIRECTLY, so every lookup goes straight past resolved and the
#     VM is never consulted — while `resolvectl status` cheerfully shows the VM,
#     because in foreign mode resolved is merely READING that same file.
#
# WHY the state lives in /run and not in a repo/tmp state dir (the one place this
# deliberately differs from ../town-os): it is dev-VM state, not a host
# configuration change, so it evaporates on reboot and a workstation can never be
# left permanently pointed at a VM that no longer exists. It is also a single
# fixed path rather than one keyed to the checkout, so ../town-os's
# adopt_orphan_dns_backup has no analogue to be needed here — any checkout's
# `make vm-dns-revert` finds the backup any other checkout took.
#
# WHY it waits for the VM's resolver first: switching a host onto a resolver that
# is not answering yet is how `make qemu-fg` used to leave the workstation with
# no DNS at all for the whole guest boot, and how `make qemu-usb` against a blank
# stick left it with none indefinitely — rolodex on an unprovisioned stick is
# never coming up. So `set` probes $VM_DNS:53 for up to $VM_DNS_WAIT seconds and
# does nothing at all if it never answers. qemu.sh runs this backgrounded, after
# it has launched the VM, for exactly this reason.
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

# These paths (and RESOLV_CONF below) are overridable purely so the set/unset
# cycle can be exercised against scratch files instead of the live host — nothing
# in the Makefile ever sets them. A test able to reach the real /etc/resolv.conf
# is a test that can take the machine running it off the network, which is the
# failure this code exists to repair.
RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
# One record per redirected link: "<link>|<dns>|<domains>", captured BEFORE the
# change so the restore puts back exactly what NetworkManager/networkd had
# pushed rather than guessing.
LINKS_STATE="${LINKS_STATE:-/run/town-os-host-dns.links}"
# What resolv.conf was before we touched it: "link:<target>" or "file" (with the
# original bytes in RESOLV_BAK). Restoring the TYPE matters — a host whose file
# we replaced must get a file back, not a dangling link.
RESOLV_STATE="${RESOLV_STATE:-/run/town-os-host-dns.resolv}"
RESOLV_BAK="${RESOLV_STATE}.bak"

# Written by the pre-port implementation (a global resolved drop-in and a
# single-link state file). Never created any more, only cleaned up, so a host
# that launched a VM before this change can still be put back by `unset`.
LEGACY_DROPIN="${LEGACY_DROPIN:-/run/systemd/resolved.conf.d/zz-town-os-vm.conf}"
LEGACY_LINK_STATE="${LEGACY_LINK_STATE:-/run/town-os-host-dns.link}"

# How long `set` waits for $VM_DNS:53 to answer before giving up and leaving the
# host's resolver alone. 30s matches ../town-os, where rolodex is already running
# by the time the redirect is called; qemu.sh raises it, because there the guest
# still has to boot.
VM_DNS_WAIT="${VM_DNS_WAIT:-30}"

# systemd-resolved is not universal (a host on plain resolv.conf, or NM's own
# dnsmasq), and resolv.conf alone still works there. Only the per-link half needs
# resolvectl, so its absence is a substep, not a failure — see resolved_running.
resolved_running() {
  command -v resolvectl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet systemd-resolved 2>/dev/null
}

# VM_DNS=0 (or empty) is the opt-out. In `set` that's a no-op; in `unset` we
# still run, so flipping the switch off after a launch actually cleans up.
VM_DNS="${VM_DNS:-}"
if [ "${MODE}" = "set" ] && { [ -z "${VM_DNS}" ] || [ "${VM_DNS}" = "0" ]; }; then
  exit 0
fi

# Nothing to undo -> return before touching sudo. This matters: stop.sh calls
# `unset` unconditionally, so without this early exit every `make stop` would
# prompt for a password just to discover there was no switch to reverse. Every
# path lives in /run and is world-readable, so the test needs no privilege.
if [ "${MODE}" = "unset" ] && [ ! -f "${LINKS_STATE}" ] && [ ! -f "${RESOLV_STATE}" ] \
   && [ ! -f "${LEGACY_DROPIN}" ] && [ ! -f "${LEGACY_LINK_STATE}" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# unset
# ---------------------------------------------------------------------------

if [ "${MODE}" = "unset" ]; then
  if ! sudo -v; then
    echo "error: root is required to restore the host's DNS" >&2
    exit 1
  fi

  # Put every recorded link back the way it was. EXPLICIT restore rather than
  # `resolvectl revert`: revert drops the settings NetworkManager pushed at
  # connection time and NM does not re-push them until the connection is
  # reactivated, so a reverted link is left with NO DNS AT ALL. Revert is only
  # the fallback for a link that genuinely had nothing set.
  if [ -f "${LINKS_STATE}" ] && resolved_running; then
    while IFS='|' read -r link dns domains; do
      [ -n "${link}" ] || continue
      if [ -n "${dns}" ] || [ -n "${domains}" ]; then
        # Unquoted on purpose: both fields are space-separated lists.
        # shellcheck disable=SC2086
        sudo resolvectl dns "${link}" ${dns} >/dev/null 2>&1 \
          || sudo resolvectl revert "${link}" >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        sudo resolvectl domain "${link}" ${domains} >/dev/null 2>&1 || true
      else
        sudo resolvectl revert "${link}" >/dev/null 2>&1 || true
      fi
      echo "  restored systemd-resolved DNS on ${link}"
    done < "${LINKS_STATE}"
    sudo resolvectl flush-caches >/dev/null 2>&1 || true
  fi
  sudo rm -f "${LINKS_STATE}"

  # Legacy cleanup: the single-link state file and the global drop-in the
  # previous implementation left behind.
  if [ -f "${LEGACY_LINK_STATE}" ]; then
    LEGACY_LINK=$(sudo cat "${LEGACY_LINK_STATE}")
    [ -n "${LEGACY_LINK}" ] && sudo resolvectl revert "${LEGACY_LINK}" >/dev/null 2>&1 || true
    sudo rm -f "${LEGACY_LINK_STATE}"
  fi
  if [ -f "${LEGACY_DROPIN}" ]; then
    sudo rm -f "${LEGACY_DROPIN}"
    # D-Bus, not the systemctl CLI (see CLAUDE.md).
    sudo busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
      org.freedesktop.systemd1.Manager ReloadUnit ss \
      "systemd-resolved.service" "replace" >/dev/null 2>&1 || true
  fi

  if [ -f "${RESOLV_STATE}" ]; then
    saved=$(sudo cat "${RESOLV_STATE}")
    case "${saved}" in
      link:*)
        sudo ln -sfn "${saved#link:}" "${RESOLV_CONF}"
        ;;
      file)
        # Restore via a temp file + `mv -fT`, NOT a plain cp onto the path. `set`
        # replaces a symlink with a plain file so this is normally cp-safe, but a
        # NetworkManager that re-created the symlink underneath us mid-session
        # would make cp write the backup THROUGH the link into whatever it points
        # at (usually resolved's generated stub) and leave resolv.conf a symlink
        # forever. mv -T replaces either shape atomically, so there is also no
        # instant where the host has no resolv.conf at all.
        sudo cp --no-preserve=timestamps "${RESOLV_BAK}" "${RESOLV_CONF}.town-tmp"
        sudo mv -fT "${RESOLV_CONF}.town-tmp" "${RESOLV_CONF}"
        ;;
      none)
        # There was no resolv.conf before us; take ours back out again.
        sudo rm -f "${RESOLV_CONF}"
        ;;
    esac
    sudo rm -f "${RESOLV_STATE}" "${RESOLV_BAK}"
    echo "  restored ${RESOLV_CONF}"
  fi

  echo "Host DNS restored"
  exit 0
fi

# ---------------------------------------------------------------------------
# set
# ---------------------------------------------------------------------------

# Wait for rolodex to answer on the VM before touching anything. rolodex binds
# both udp and tcp on every global address (scripts/rolodex-config.sh), so a TCP
# connect is a valid liveness probe.
#
# The sudo keepalive is why this can wait minutes without a second password
# prompt: qemu.sh primes the credential visibly before it launches, and `sudo -n
# -v` refreshes that ticket without ever prompting. It is deliberately silent and
# best-effort — if there is no ticket to refresh (the backgrounded, setsid'd case
# under `make qemu`, where sudo's tty_tickets key the cache to a terminal this
# process no longer has) it simply fails and the real `sudo -v` below asks, the
# same way make/vm-relay.sh does on that path.
echo "Waiting up to ${VM_DNS_WAIT}s for rolodex DNS on ${VM_DNS}:53"
waited=0
while [ "${waited}" -lt "${VM_DNS_WAIT}" ]; do
  if (echo >"/dev/tcp/${VM_DNS}/53") 2>/dev/null; then
    break
  fi
  sudo -n -v >/dev/null 2>&1 || true
  sleep 1
  waited=$((waited + 1))
done
if [ "${waited}" -ge "${VM_DNS_WAIT}" ]; then
  echo "note: rolodex did not answer on ${VM_DNS}:53 within ${VM_DNS_WAIT}s — host DNS left alone" >&2
  exit 0
fi
echo "Rolodex is listening on ${VM_DNS}:53"

# Every call below is privileged. Prime the credential ONCE, visibly, before any
# call whose output is redirected — a cold cache behind a swallowed prompt is
# what feeds pam_faillock and locks the account out (see qemu.sh).
if ! sudo -v; then
  echo "error: root is required to change the host's DNS" >&2
  exit 1
fi

# --- half 1: systemd-resolved's per-link servers -----------------------------

# The interfaces actually carrying traffic: whatever holds a default route, v4 or
# v6. Those are the links resolved consults, so those are the ones that have to
# point at the VM. The VM's own bridge is excluded — pointing virbr0's resolver
# at a guest behind virbr0 is at best pointless.
dns_links() {
  {
    ip -4 route show default 2>/dev/null
    ip -6 route show default 2>/dev/null
  } | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' \
    | grep -vx "${VM_BRIDGE:-virbr0}" | sort -u
}

# The current value of a link's setting, with resolvectl's "Link 2 (eth0): "
# prefix stripped. Empty when the link has none set.
link_setting() {  # $1 = dns|domain, $2 = link
  resolvectl "$1" "$2" 2>/dev/null | sed -n '1s/^[^:]*: *//p'
}

if resolved_running; then
  LINKS=$(dns_links)
  if [ -z "${LINKS}" ]; then
    echo "  warning: no default-route interface found — skipping systemd-resolved" >&2
  else
    : | sudo tee "${LINKS_STATE}" >/dev/null
    for link in ${LINKS}; do
      dns=$(link_setting dns "${link}")
      domains=$(link_setting domain "${link}")
      printf '%s|%s|%s\n' "${link}" "${dns}" "${domains}" \
        | sudo tee -a "${LINKS_STATE}" >/dev/null
      if sudo resolvectl dns "${link}" "${VM_DNS}" >/dev/null 2>&1 \
        && sudo resolvectl domain "${link}" '~.' >/dev/null 2>&1; then
        echo "  systemd-resolved: ${link} -> ${VM_DNS} (~.)"
      else
        echo "  warning: could not set systemd-resolved DNS on ${link}" >&2
      fi
    done
    sudo resolvectl flush-caches >/dev/null 2>&1 || true
  fi
else
  echo "  systemd-resolved not running — resolv.conf only"
fi

# --- half 2: /etc/resolv.conf ------------------------------------------------

# Record the ORIGINAL only once: a second launch must not overwrite the saved
# state with our own file and lose the way back.
if [ ! -f "${RESOLV_STATE}" ]; then
  if [ -L "${RESOLV_CONF}" ]; then
    TARGET=$(readlink "${RESOLV_CONF}")
    printf 'link:%s\n' "${TARGET}" | sudo tee "${RESOLV_STATE}" >/dev/null
    # Drop the symlink instead of writing THROUGH it. It usually points at
    # resolved's generated stub-resolv.conf, and clobbering that file leaves the
    # host pointed at a dead VM long after this has exited — the restore puts the
    # symlink back, but not the file's contents.
    sudo rm -f "${RESOLV_CONF}"
    echo "  ${RESOLV_CONF} was a symlink to ${TARGET} (restored on revert)"
  elif [ -e "${RESOLV_CONF}" ]; then
    sudo cp --no-preserve=timestamps "${RESOLV_CONF}" "${RESOLV_BAK}"
    printf 'file\n' | sudo tee "${RESOLV_STATE}" >/dev/null
  else
    # No resolv.conf at all (rare, but a host resolving purely through
    # nss-resolve is a legitimate configuration). Record that so the revert
    # REMOVES the file we are about to create instead of leaving the host with a
    # stray nameserver line pointing at a VM that is gone.
    printf 'none\n' | sudo tee "${RESOLV_STATE}" >/dev/null
  fi
fi

printf 'nameserver %s\n' "${VM_DNS}" | sudo tee "${RESOLV_CONF}" >/dev/null

# NetworkManager in its default dns=default mode OWNS resolv.conf and will
# rewrite it on the next connectivity change, silently taking resolution back
# mid-session. Nothing here can prevent that without making a permanent change to
# the host's configuration, which is not this script's business — so say so once
# and name the one-line fix rather than papering over it.
if ! (NetworkManager --print-config 2>/dev/null || cat /etc/NetworkManager/NetworkManager.conf 2>/dev/null) \
     | grep -qE '^\s*dns\s*=\s*(systemd-resolved|none)'; then
  if pgrep -x NetworkManager >/dev/null 2>&1; then
    echo "  note: NetworkManager may rewrite ${RESOLV_CONF} on the next network change." >&2
    echo "        To make this stick, set dns=systemd-resolved in NetworkManager.conf." >&2
  fi
fi

yellow=$'\033[33m'; reset=$'\033[0m'
printf "${yellow}%s${reset}\n" \
  "╔══════════════════════════════════════════════════════════════╗" \
  "║  WARNING: host DNS now goes through the Town OS VM's rolodex ║" \
  "║  Both /etc/resolv.conf and the systemd-resolved servers on   ║" \
  "║  your default-route interfaces were rewritten.               ║" \
  "║                                                              ║" \
  "║  Both are restored when this VM stops, and by                ║" \
  "║  'make stop' / 'make stop-qemu' / 'make vm-dns-revert'.      ║" \
  "╚══════════════════════════════════════════════════════════════╝"
echo "Host DNS -> ${VM_DNS} (Town OS VM)"
