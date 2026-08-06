#!/bin/bash
# install-pacman.sh - Set up the Claude Desktop pacman repository
#
# Usage: curl -fsSL https://kjanat.github.io/claude-desktop-extra/install-pacman.sh | sudo bash

set -euo pipefail

PAGES_URL="https://kjanat.github.io/claude-desktop-extra"
SERVER_URL="https://github.com/kjanat/claude-desktop-extra/releases/latest/download"
PACMAN_CONF="/etc/pacman.conf"
BACKUP_PATH="/etc/pacman.conf.claude-desktop.bak"
MARKER="# Added by install-pacman.sh - Claude Desktop repository"

# Check root
if [ "$(id -u)" -ne 0 ]; then
	echo "Error: This script must be run as root (use sudo)."
	exit 1
fi

# Require pacman itself before touching anything
for cmd in pacman pacman-key; do
	if ! command -v "$cmd" &>/dev/null; then
		echo "Error: $cmd not found - this script only works on Arch-based systems."
		echo "       On Debian/Ubuntu use install.sh, on Fedora/RHEL use install-rpm.sh."
		exit 1
	fi
done
if ! command -v gpg &>/dev/null; then
	echo "Error: gpg not found - install the gnupg package first (pacman -S gnupg)."
	exit 1
fi

# Detect and validate architecture, and map it to the repository name
ARCH="$(uname -m)"
case "$ARCH" in
	x86_64) REPO_NAME="claude-desktop-extra" ;;
	aarch64) REPO_NAME="claude-desktop-extra-aarch64" ;;
	*)
		echo "Error: Unsupported architecture: $ARCH (supported: x86_64, aarch64)"
		exit 1
		;;
esac
echo "  Detected architecture: $ARCH (repository: $REPO_NAME)"

echo "Setting up Claude Desktop pacman repository..."

KEY_TMP="$(mktemp)"
CONF_TMP="$(mktemp)"
trap 'rm -f "$KEY_TMP" "$CONF_TMP"' EXIT

# Download and install the GPG key.
# Download to a temp file and validate it parses as a GPG key BEFORE handing it
# to pacman-key, so a truncated/corrupt download can't leave a broken key in the
# pacman keyring.
curl -fsSL "$PAGES_URL/gpg-key.asc" -o "$KEY_TMP"
if ! gpg --show-keys --with-colons "$KEY_TMP" >/dev/null 2>&1; then
	echo "Error: downloaded GPG key failed to parse (corrupt or incomplete download)."
	exit 1
fi
KEY_ID="$(gpg --show-keys --with-colons "$KEY_TMP" | awk -F: '/^pub:/ { print $5; exit }')"
if [ -z "$KEY_ID" ]; then
	echo "Error: could not read a key id from $PAGES_URL/gpg-key.asc."
	exit 1
fi

# --lsign-key needs the keyring's own local signing key ("Pacman Keyring Master
# Key"). A normal Arch install already has one, but containers, chroots and
# wiped keyrings do not, and there the failure is a cryptic "There is no secret
# key available to sign with". --init is idempotent (it only creates what is
# missing and never drops existing keys), so run it unconditionally first.
pacman-key --init

# Both steps are required: --add imports the key into the pacman keyring,
# --lsign-key signs it with the machine's local key so pacman actually trusts it.
# Without the local signature every package from this repo is rejected.
pacman-key --add "$KEY_TMP"
pacman-key --lsign-key "$KEY_ID"
echo "  GPG key $KEY_ID imported and locally signed"

# Add the repository to /etc/pacman.conf. pacman has no conf.d drop-in
# directory, so the file has to be edited in place. Back it up once, then strip
# any stanza we previously wrote (either arch) and append a fresh one - a
# duplicated section makes pacman warn and can shadow the newer definition.
# Appending is also the only safe position: repo sections must come after
# [options], and the end of the file is always past it.
if [ ! -f "$BACKUP_PATH" ]; then
	cp -a "$PACMAN_CONF" "$BACKUP_PATH"
	echo "  Backed up $PACMAN_CONF to $BACKUP_PATH"
fi

# Drop our marker comment and any section we ever wrote - both the current
# [claude-desktop-extra] names and the pre-rename [claude-desktop-bin] names
# (a section runs until the next [header]) - then trim trailing blank lines so
# repeated runs don't grow the file and old installs migrate cleanly.
awk -v marker="$MARKER" '
    $0 == marker { next }
    /^[[:space:]]*\[/ {
        ours = ($0 ~ /^[[:space:]]*\[claude-desktop-(extra|bin)(-aarch64)?\][[:space:]]*$/)
    }
    ours { next }
    { lines[++n] = $0; if ($0 ~ /[^[:space:]]/) last = n }
    END { for (i = 1; i <= last; i++) print lines[i] }
' "$PACMAN_CONF" >"$CONF_TMP"

{
	echo ""
	echo "$MARKER"
	echo "[$REPO_NAME]"
	echo "SigLevel = Required DatabaseRequired"
	echo "Server = $SERVER_URL"
} >>"$CONF_TMP"

# Write the content back into the existing file to keep its inode, owner and mode.
cat "$CONF_TMP" >"$PACMAN_CONF"
echo "  Repository [$REPO_NAME] added to $PACMAN_CONF"

# Refresh package databases so our new repo has one. pacman has no per-repo
# refresh flag, so this refreshes every configured repo's database - metadata
# only, nothing is installed or upgraded. We deliberately never run -Syu, which
# would upgrade the user's whole system unprompted. Installing on top of a bare
# -Sy would be a partial upgrade, which Arch does not support - hence the
# closing instruction below tells the user to install with -Syu.
pacman -Sy

echo ""
echo "Done! Install Claude Desktop with:"
echo ""
echo "  sudo pacman -Syu claude-desktop-extra"
echo ""
echo "The -Syu is intentional: Arch does not support partial upgrades, so a"
echo "package must always be installed together with a full system upgrade."
echo ""
echo "Future updates via: sudo pacman -Syu (or yay -Syu)"
