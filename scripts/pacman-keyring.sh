#!/bin/sh
# Make pacman's keyring usable for an UNATTENDED build.
#
# Runs both inside the image chroot (make/install.sh, before the RG35XX in-chroot
# kernel/U-Boot builds `pacman -S` their deps) and inside the emulated build VM
# (make/image-aarch64-guest.sh, before it provisions its toolchain). Both are
# places where a package whose signing key isn't trusted stops the build with
# nobody there to answer.
#
# WHY THIS IS NEEDED AT ALL: `pacstrap -K` runs `pacman-key --init` and NOTHING
# else (see /usr/bin/pacstrap) — it creates an EMPTY keyring. The distro keys
# arrive only via the keyring package's own install scriptlet, and
# archlinuxarm-keyring's scriptlet is a no-op unless /usr/bin/pacman-key already
# exists when it runs. So a chroot can finish pacstrap with Arch's x86 master
# keys imported and the Arch Linux ARM builder key — the SINGLE key that signs
# every ALARM package — absent. pacman then tries to fetch it from a keyserver
# mid-build and blocks there.
#
# THE CHECK IS PER-KEY, NOT "IS ANYTHING TRUSTED". That distinction is the whole
# point: a keyring holding a hundred trusted Arch keys is still useless for
# installing ALARM packages. Every fingerprint the distro lists in
# /usr/share/pacman/keyrings/*-trusted must be present AND carry full validity,
# which is what `pacman-key --populate` establishes by locally signing each one.
#
# Everything here is OFFLINE: --populate imports from the keyring package already
# on disk. No keyserver, no network, nothing to time out or prompt.
#
# Usage: pacman-keyring.sh [verify|ensure] [required-keyring ...]
#
# A required-keyring name (e.g. `archlinuxarm`) asserts that the distro keyring
# is INSTALLED, not merely that whatever is installed checks out. Without that
# the check passes vacuously in the exact case worth catching: a chroot holding
# only Arch's x86 keyring, every key in it perfectly trusted, and the Arch Linux
# ARM keyring — the one whose key signs the packages about to be installed —
# absent, so no amount of populating can produce it.
set -e

mode="${1:-verify}"
[ $# -eq 0 ] || shift
required_keyrings="$*"

gpgdir="$(pacman-conf gpgdir 2>/dev/null || true)"
[ -n "$gpgdir" ] || gpgdir=/etc/pacman.d/gnupg
keyrings=/usr/share/pacman/keyrings

for name in $required_keyrings; do
	if [ ! -f "$keyrings/$name-trusted" ]; then
		echo "pacman keyring: $keyrings/$name-trusted is missing — the" >&2
		echo "$name-keyring package is not installed, so its signing keys cannot" >&2
		echo "be trusted no matter how often the keyring is populated." >&2
		exit 1
	fi
done

# Print the fingerprints that are missing or not fully valid; print nothing when
# the keyring is good. gpg reports validity in field 2 of a --with-colons `pub`
# record: `f` full (a populated distro key) or `u` ultimate (the local master
# key); `-` is unknown and an absent key prints nothing at all — both fail here.
#
# Ask gpg directly rather than via `pacman-key --list-keys`: pacman-key's option
# parser rejects anything that isn't one of its own flags ("invalid option
# '--with-colons'", exit 1, no output), which would make every keyring look
# broken. This is the invocation pacman-key builds internally.
untrusted_keys() {
	for t in "$keyrings"/*-trusted; do
		[ -f "$t" ] || continue
		while IFS=: read -r fpr _rest; do
			case "$fpr" in '' | '#'*) continue ;; esac
			validity="$(gpg --homedir "$gpgdir" --no-permission-warning --batch \
				--list-keys --with-colons "$fpr" 2>/dev/null |
				awk -F: '$1 == "pub" { print $2; exit }')"
			case "$validity" in
			f | u) ;;
			*) printf '%s ' "$fpr" ;;
			esac
		done <"$t"
	done
}

case "$mode" in
verify) ;;
ensure)
	# Populate only when something is actually missing: --populate is not free
	# under TCG emulation, and this runs on every build.
	if [ -n "$(untrusted_keys)" ]; then
		echo "pacman keyring: distro signing keys are not trusted — populating"
		# No keyring name, so every keyring shipped in $keyrings is used. On
		# ALARM that is archlinuxarm AND archlinux; naming one leaves the
		# other's keys untrusted, which is exactly the failure above.
		pacman-key --populate || true
	fi
	# Populating can import the keys and still leave them untrusted when the
	# keyring has no master key to sign them WITH — `pacstrap -K` creates the
	# keyring by running --init, but a keyring copied or restored from elsewhere
	# may carry public keys and no secret master. --init is idempotent, so
	# re-running it costs nothing when the master is already there.
	if [ -n "$(untrusted_keys)" ]; then
		echo "pacman keyring: still untrusted after populate — reinitializing"
		pacman-key --init
		pacman-key --populate
	fi
	;;
*)
	echo "usage: ${0##*/} [verify|ensure]" >&2
	exit 2
	;;
esac

missing="$(untrusted_keys)"
if [ -n "$missing" ]; then
	echo "pacman keyring in $gpgdir does not trust: $missing" >&2
	echo "Packages signed by those keys will fail as 'unknown trust', or pacman" >&2
	echo "will stall trying to fetch them from a keyserver." >&2
	exit 1
fi
