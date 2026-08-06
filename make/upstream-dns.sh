#!/usr/bin/env bash
# Print the HOST's real upstream DNS servers, one per line (IPv4).
#
# WHY THIS EXISTS: every build path in this repo used to inherit whatever
# /etc/resolv.conf happened to say — and this repo deliberately REWRITES that
# file. `make qemu*` points the host's systemd-resolved at the dev VM
# (make/host-dns.sh, VM_DNS) so the workstation resolves through rolodex like a
# real client. That is the qemu tasks' whole job, and it stays. But it means a
# host that has ever launched the dev VM (or is running one now) hands its
# resolver — a NAT'd guest that may be down, mid-boot, or unprovisioned — to
# anything that reads resolv.conf, including an hours-long image build.
#
# So the build/release paths do NOT resolve through the host's configured
# resolver. They ask here for the servers the host actually got from the local
# network, and configure their own container/VM with those explicitly. The
# result: DNS is isolated per task. Only the qemu targets touch (or depend on)
# the host's resolver.
#
# Discovery is TIERED — a tier is consulted only if every tier above it came back
# empty after filtering, so a weaker source never dilutes a good one:
#   1. DHCP-provided values: NetworkManager's per-link IP4.DNS on the
#      default-route interface, systemd-networkd lease files, dhcpcd's
#      per-interface resolv.conf fragments. FIRST because these survive the
#      resolved override — NetworkManager keeps the per-link record even while
#      resolved is pointed at the guest, which is exactly this script's case.
#   2. /etc/resolv.conf itself (only non-loopback entries survive the filter, so
#      resolved's stub — and therefore the VM behind it — cannot come through)
#   3. the default gateway, a DNS forwarder on essentially every home/NAT
#      network. A heuristic, hence last.
#
# Rejected always: loopback, 0.0.0.0, and any address inside a subnet owned by a
# local virtual bridge (virbr*, podman*, docker*, br-*) — that is the dev VM and
# container-network space, and resolving a build through it is exactly the
# coupling this script exists to break.
#
# Usage: upstream-dns.sh [--fallback] [--exclude ADDR]... [--exclude-net CIDR]...
#   --fallback       append public resolvers after whatever was discovered, so a
#                    caller that must have *something* gets a working list
#   --exclude        drop this literal address (e.g. VM_IP)
#   --exclude-net    drop addresses in this CIDR
# Exits 0 with no output when nothing could be discovered and --fallback wasn't
# given; callers treat that as "leave DNS alone".
set -euo pipefail

FALLBACK=""
EXCL_ADDR=()
EXCL_NET=()

while [ $# -gt 0 ]; do
  case "$1" in
    --fallback)    FALLBACK=1; shift ;;
    --exclude)     EXCL_ADDR+=("${2:?--exclude needs an address}"); shift 2 ;;
    --exclude-net) EXCL_NET+=("${2:?--exclude-net needs a CIDR}"); shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "upstream-dns.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Public resolvers used only for --fallback, appended AFTER the discovered ones:
# on a network that filters outbound :53 (see the rolodex chain in CLAUDE.md)
# these time out and the discovered local resolver still answers first.
FALLBACK_DNS="1.1.1.1 9.9.9.9 8.8.8.8"

# Subnets owned by local virtual bridges. Excluded wholesale — this is the dev
# VM's libvirt network (virbr0, 192.168.122.0/24 by default) and podman/docker
# space. Collected here rather than hardcoded so a non-default VM_BRIDGE or a
# renumbered libvirt network is covered without anyone remembering to update it.
BRIDGE_NETS=$(ip -4 -o addr show 2>/dev/null \
  | awk '$2 ~ /^(virbr|podman|cni-podman|docker|br-)/ { print $4 }' || true)

# Interface carrying the default route — whose DHCP lease is the thing we want.
DEV=$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' | head -1 || true)

# The sources, in TIERS. A tier is used only when every tier above it came back
# empty AFTER filtering — they are not equals. DHCP-provided values are what we
# actually want; /etc/resolv.conf is a guess about a file this repo rewrites; the
# gateway is a heuristic (true on home/NAT networks, not everywhere). Ranking
# them equal would, for instance, add the router to libvirt's forwarder list on
# every host that has one, which is a behaviour change nobody asked for.
#
# Every `|| true`: a missing tool, an absent lease directory (the glob then stays
# literal), or a filter that removes everything must not kill the script under
# `set -euo pipefail`. An empty source is a normal outcome, not an error.
tier_dhcp() {
  [ -n "$DEV" ] && { nmcli -g IP4.DNS dev show "$DEV" 2>/dev/null | tr '|,' '\n\n' || true; }
  awk -F= '/^DNS=/ { print $2 }' /run/systemd/netif/leases/* 2>/dev/null | tr ' ' '\n' || true
  awk '/^[[:space:]]*nameserver/ { print $2 }' /run/dhcpcd/resolv.conf/* 2>/dev/null || true
}
tier_resolv() { awk '/^[[:space:]]*nameserver/ { print $2 }' /etc/resolv.conf 2>/dev/null || true; }
tier_gateway() { ip -4 route show default 2>/dev/null | awk '{ print $3 }' || true; }
tier_public() { printf '%s\n' $FALLBACK_DNS; }

# Filter + dedupe. CIDR membership is done with plain arithmetic (size =
# 2^(32-len); same block iff int(ip/size) matches) because POSIX awk has no bit
# operators.
filter() {
  tr ' ' '\n' \
  | awk -v nets="$(printf '%s\n' $BRIDGE_NETS ${EXCL_NET[@]+"${EXCL_NET[@]}"} | tr '\n' ' ')" \
        -v drop="$(printf '%s\n' ${EXCL_ADDR[@]+"${EXCL_ADDR[@]}"} | tr '\n' ' ')" '
      # i is declared local (extra param): the callers loop on i themselves, and
      # awk globals would let this clobber the caller mid-loop.
      function ip2int(ip,   p, n, i) {
        n = split(ip, p, ".")
        if (n != 4) return -1
        for (i = 1; i <= 4; i++) if (p[i] !~ /^[0-9]+$/ || p[i] + 0 > 255) return -1
        return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4]
      }
      BEGIN {
        nn = split(nets, N, " ")
        for (i = 1; i <= nn; i++) {
          if (split(N[i], c, "/") != 2) continue
          base = ip2int(c[1]); if (base < 0) continue
          size = 2 ^ (32 - c[2])
          NETBASE[++k] = int(base / size) * size; NETSIZE[k] = size
        }
        dn = split(drop, D, " ")
        for (i = 1; i <= dn; i++) DROP[D[i]] = 1
      }
      {
        gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 == "" || DROP[$0]) next
        v = ip2int($0); if (v < 0) next
        if ($0 ~ /^127\./ || $0 == "0.0.0.0") next
        for (i = 1; i <= k; i++) if (int(v / NETSIZE[i]) * NETSIZE[i] == NETBASE[i]) next
        if (!seen[$0]++) print
      }'
}

OUT="$(tier_dhcp | filter)"
[ -n "$OUT" ] || OUT="$(tier_resolv | filter)"
[ -n "$OUT" ] || OUT="$(tier_gateway | filter)"

# --fallback appends the public resolvers AFTER whatever was discovered (and
# re-filters, so an --exclude applies to them too). A caller that asks for it
# needs a usable list more than it needs a strictly-local one.
if [ -n "$FALLBACK" ]; then
  OUT="$(printf '%s\n' "$OUT" $FALLBACK_DNS | filter)"
fi

# Guard the empty case: `printf '%s\n' ""` would emit a blank line, which a
# caller splitting on newlines reads as a server named "".
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
