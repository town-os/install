#!/bin/sh
# Town OS network diagnostics — capture host network state to a log, but only
# when it CHANGES.
#
# This is a passive post-mortem aid: when the network breaks you want the state
# from the moment it broke, not an identical dump every few seconds burying it.
# So each interval we build a normalized "change key" and compare it to the last
# one; only when it differs do we append a full raw dump. In steady state (no
# errors, nothing changing) this writes nothing at all.
#
# It runs as a single long-lived service rather than a timer-driven oneshot on
# purpose: a oneshot every N seconds emits a Starting/Deactivated/Finished triple
# to the journal on every fire, forever. A long-lived service emits one line at
# boot and is then silent — which is the whole point.
#
# All commands here are read-only; nothing modifies host state.

LOG="${NETWORK_DIAG_LOG:-/town-os/network-diag.log}"
INTERVAL="${NETWORK_DIAG_INTERVAL:-10}"

# The full, unmodified dump written to the log when something changes — the same
# state the old oneshot captured, kept verbatim so it stays maximally useful.
raw_dump() {
  printf -- '--- ip addr ---\n%s\n' "$addr"
  printf -- '--- ip route ---\n%s\n' "$route"
  printf -- '--- nft list ruleset ---\n%s\n' "$ruleset"
  printf -- '--- iptables-save ---\n%s\n' "$ipt"
  printf -- '--- lsmod nf ---\n%s\n' "$mods"
}

# The change key: the same state with the parts that churn on their own stripped
# out, so "changed" means the network actually changed — not that a byte counter
# ticked or a DHCP lease timer counted down. Without this the key differs every
# interval and the change-only behavior degrades back into spam. Specifically:
#   - ip addr:       valid_lft/preferred_lft count down every second on a lease
#   - nft ruleset:   `counter packets N bytes N` moves with every packet
#   - iptables-save: the `# Generated ... on <date>` header is new every run
#   - lsmod:         the refcount column moves as modules are used; keep names
change_key() {
  printf '%s\n' "$addr" | sed 's/valid_lft [0-9a-z]* preferred_lft [0-9a-z]*//'
  printf '%s\n' "$route"
  printf '%s\n' "$ruleset" | sed 's/counter packets [0-9]* bytes [0-9]*/counter/g'
  printf '%s\n' "$ipt" | grep -v '^#'
  printf '%s\n' "$mods" | awk '{ print $1 }'
}

prev=""
label="initial"

while :; do
  # Capture once; the key and the dump are derived from the same snapshot so a
  # change we log is exactly the change we detected. 2>&1 folds tool errors (a
  # missing command, a transient nft lock) into the captured text, so an error
  # state is itself a change worth recording rather than a silent gap.
  addr="$(ip addr 2>&1)"
  route="$(ip route 2>&1)"
  ruleset="$(nft list ruleset 2>&1)"
  ipt="$(iptables-save 2>&1)"
  mods="$(lsmod 2>&1 | grep nf)"

  key="$(change_key)"
  if [ "$key" != "$prev" ]; then
    {
      printf '=== %s (%s) ===\n' "$(date -Iseconds)" "$label"
      raw_dump
      printf '\n'
    } >> "$LOG"
    prev="$key"
    label="changed"
  fi

  sleep "$INTERVAL"
done
