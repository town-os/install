#!/bin/bash
# swap-resolv.sh — switch /etc/resolv.conf between rolodex and systemd-resolved.
# Usage: swap-resolv.sh rolodex | resolved

set -euo pipefail

case "${1:-}" in
  rolodex)
    printf 'nameserver 127.0.0.2\n' > /etc/resolv.conf
    ;;
  resolved)
    printf 'nameserver 127.0.0.53\n' > /etc/resolv.conf
    ;;
  *)
    echo "Usage: $0 rolodex|resolved" >&2
    exit 1
    ;;
esac
