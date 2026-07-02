#!/bin/sh
# rolodex ExecStartPost helper: the instant rolodex is actually listening, make
# it systemd-resolved's SOLE resolver (DNS=127.0.0.2 ::1), dropping the bootstrap
# DHCP resolver so split-horizon .home names can never leak to it.
#
# rolodex runs as `podman run` under Type=exec, so systemd considers the service
# "started" as soon as podman is exec'd — well before rolodex binds its sockets.
# Wait (bounded) for 127.0.0.2:53 to appear, then hand off to bootstrap-dns.sh,
# which flips to the up-state on seeing that socket. If rolodex never comes up
# within the window, bootstrap-dns.sh still runs and correctly leaves the
# bootstrap resolver in place (rolodex isn't serving, so it must not be primary).
set -eu

i=0
while [ "$i" -lt 60 ]; do
  if ss -H -t -u -l -n 2>/dev/null | grep -q '127\.0\.0\.2:53'; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done

exec /bin/sh /usr/lib/town-os/scripts/bootstrap-dns.sh
