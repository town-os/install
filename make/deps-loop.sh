#!/usr/bin/env bash
# Sourced by make/deps.sh and make/deps-debian.sh — not meant to run standalone.
#
# The image build loop-mounts a partitioned raw disk image. `losetup --partscan`
# only creates the partition device nodes (/dev/loopNp1..pN) when the loop module
# is loaded with max_part>0 — many distros default to 0, which makes mkfs on the
# partitions fail. Persist the setting via modprobe.d, then apply it now by
# reloading the module if nothing is using it.
ensure_loop_partitions() {
  local want=15
  # 99- prefix so this file is read last and wins over any other loop options.
  local conf=/etc/modprobe.d/99-town-os-loop.conf
  sudo rm -f /etc/modprobe.d/town-os-loop.conf  # drop the old unprefixed name
  if [ ! -f "$conf" ] || ! grep -q "max_part=${want}" "$conf"; then
    printf 'options loop max_part=%s\n' "$want" | sudo tee "$conf" >/dev/null
    echo "Wrote $conf (loop max_part=${want})."
  fi
  local cur
  cur=$(cat /sys/module/loop/parameters/max_part 2>/dev/null || echo 0)
  if [ "${cur:-0}" -lt "$want" ]; then
    # `modprobe loop` (no args) picks up max_part from the modprobe.d file above.
    if sudo modprobe -r loop 2>/dev/null && sudo modprobe loop; then
      echo "Reloaded loop module: max_part now $(cat /sys/module/loop/parameters/max_part)."
    else
      echo "NOTE: the loop module is in use and could not be reloaded now;" >&2
      echo "      loop max_part=${want} will take effect after the next reboot." >&2
    fi
  fi
}
