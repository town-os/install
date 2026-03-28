#!/bin/bash
# Configure sshd based on whether ttyforce provisioned SSH keys.
# Runs at boot before sshd starts.
#
# ttyforce writes per-user keys to /town-os/ssh/authorized_keys/<username>

KEYS_DIR=/town-os/ssh/authorized_keys

has_keys=0
for f in "$KEYS_DIR"/*; do
    [ -s "$f" ] && has_keys=1 && break
done

if [ "$has_keys" = "1" ]; then
    # Keys exist: point sshd at them, disable password for users with keys
    cat >/etc/ssh/sshd_config.d/town-os.conf <<EOF
AuthorizedKeysFile $KEYS_DIR/%u .ssh/authorized_keys
Match exec "test -s $KEYS_DIR/%u"
    PasswordAuthentication no
EOF
else
    # No keys: ensure password auth works, remove any stale config
    rm -f /etc/ssh/sshd_config.d/town-os.conf
fi
