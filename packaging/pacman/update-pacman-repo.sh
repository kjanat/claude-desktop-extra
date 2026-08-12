#!/bin/bash
# update-pacman-repo.sh - Sign a pacman package and build repository metadata
#
# Usage: update-pacman-repo.sh <package.pkg.tar.zst> <out_dir> <gpg_key_id>
#
# IMPORTANT: This script must run inside an archlinux/base-devel container (or
# host) where repo-add, gpg and bsdtar are native packages. Do NOT run on Ubuntu.
#
# The repository is published as FLAT GitHub release assets
# (Server = https://github.com/.../releases/latest/download), which imposes two
# constraints the local-directory case does not have:
#   - release assets cannot be symlinks, so every file must be a real file
#   - pacman fetches "<repo>.db", never "<repo>.db.tar.gz"
# Hence the dereference step below, and the assertion that the bare .db is
# byte-identical to the .tar.gz its detached signature was made from.
#
# 1. Auto-detects arch from the package filename (x86_64 or aarch64) and maps it
#    to the repo name (claude-desktop-extra / claude-desktop-extra-aarch64)
# 2. Copies the package into out_dir
# 3. GPG-signs the package (detached, BINARY - pacman rejects armored .sig)
# 4. Runs repo-add --include-sigs to build <repo>.db.tar.gz + <repo>.files.tar.gz
#    with the package signature embedded as %PGPSIG%
# 5. Signs the databases with an explicit gpg call rather than `repo-add --sign`:
#    signing by hand keeps the exact bytes we sign, and later verify, under our
#    own control instead of depending on repo-add's symlink/sig bookkeeping
# 6. Dereferences repo-add's symlinks into real <repo>.db / <repo>.files files
# 7. Verifies every signature, asserts the db lists the package, asserts the
#    bare databases match the .tar.gz files, and prints a file summary

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
	echo "Usage: $(basename "$0") <package.pkg.tar.zst> <out_dir> <gpg_key_id>"
	exit 1
fi

PKG_FILE="$1"
OUT_DIR="$2"
GPG_KEY_ID="$3"

if [[ ! -f "${PKG_FILE}" ]]; then
	echo "ERROR: package file not found: ${PKG_FILE}"
	exit 1
fi

# Auto-detect architecture from the package filename (e.g. -x86_64.pkg.tar.zst).
# Unlike the apt/rpm scripts there is no sane default to fall back to: the arch
# picks the repo name, so a wrong guess would publish a db under the wrong name.
PKG_BASENAME=$(basename "${PKG_FILE}")
if [[ "${PKG_BASENAME}" =~ -(x86_64|aarch64)\.pkg\.tar\.zst$ ]]; then
	PKG_ARCH="${BASH_REMATCH[1]}"
else
	echo "ERROR: Could not detect a supported arch from filename: ${PKG_BASENAME}"
	echo "       Expected *-x86_64.pkg.tar.zst or *-aarch64.pkg.tar.zst"
	exit 1
fi

case "${PKG_ARCH}" in
	x86_64) REPO_NAME="claude-desktop-extra" ;;
	aarch64) REPO_NAME="claude-desktop-extra-aarch64" ;;
	*)
		echo "ERROR: Unsupported architecture: ${PKG_ARCH}"
		exit 1
		;;
esac

# LEGACY_DB_ALIAS: the repo was renamed from claude-desktop-bin. Existing
# pacman.conf sections request <section>.db by name, so the old db names must
# keep resolving during the transition. The alias files are byte-for-byte
# copies, so the detached signatures stay valid. Drop this whole block (and the
# alias copies + verification below) when the transition window ends.
case "${PKG_ARCH}" in
	x86_64) LEGACY_REPO_NAME="claude-desktop-bin" ;;
	aarch64) LEGACY_REPO_NAME="claude-desktop-bin-aarch64" ;;
	*)
		echo "ERROR: Unsupported architecture: ${PKG_ARCH}"
		exit 1
		;;
esac

echo "=== Updating pacman repository ==="
echo "  Package:    ${PKG_FILE}"
echo "  Arch:       ${PKG_ARCH}"
echo "  Repo name:  ${REPO_NAME}"
echo "  Out dir:    ${OUT_DIR}"
echo "  GPG key:    ${GPG_KEY_ID}"

# Detached, NON-armored signature. pacman only accepts binary .sig files -
# an armored signature is rejected as invalid, so never pass --armor here.
sign_file() {
	gpg --batch --yes --default-key "${GPG_KEY_ID}" --detach-sign --no-armor \
		-o "$1.sig" "$1"
}

mkdir -p "${OUT_DIR}"
cd "${OUT_DIR}"

# Copy the package in, then sign it BEFORE repo-add runs: repo-add embeds the
# detached signature as %PGPSIG% in the db entry when a .sig sits next to the
# package, which is what lets pacman verify the package from the db alone.
cp "${PKG_FILE}" "${PKG_BASENAME}"
echo "Copied ${PKG_BASENAME} to ${OUT_DIR}/"
sign_file "${PKG_BASENAME}"
echo "Signed ${PKG_BASENAME}"

# Rebuild the databases from scratch so a stale entry or signature can never
# survive into the published assets. --include-sigs embeds the package's
# detached signature as %PGPSIG% in the db entry (pacman 7 made this opt-in),
# which lets pacman verify the package from the database alone.
rm -f "${REPO_NAME}".db* "${REPO_NAME}".files* "${LEGACY_REPO_NAME}".db* "${LEGACY_REPO_NAME}".files*
repo-add --include-sigs "${REPO_NAME}.db.tar.gz" "${PKG_BASENAME}"

# repo-add leaves <repo>.db and <repo>.files as symlinks to the .tar.gz files.
# Flat release assets cannot be symlinks, so drop them and write real copies of
# the exact bytes we signed.
rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"
sign_file "${REPO_NAME}.db.tar.gz"
sign_file "${REPO_NAME}.files.tar.gz"
for ext in db files; do
	cp "${REPO_NAME}.${ext}.tar.gz" "${REPO_NAME}.${ext}"
	cp "${REPO_NAME}.${ext}.tar.gz.sig" "${REPO_NAME}.${ext}.sig"
done
echo "Built and signed ${REPO_NAME}.db / ${REPO_NAME}.files"

# LEGACY_DB_ALIAS: publish the same databases under the pre-rename repo name so
# existing [claude-desktop-bin] pacman.conf sections keep resolving. pacman only
# fetches <section>.db / <section>.files, so the .tar.gz variants need no alias.
# Byte-for-byte copies keep the detached signatures valid.
for ext in db files; do
	cp "${REPO_NAME}.${ext}" "${LEGACY_REPO_NAME}.${ext}"
	cp "${REPO_NAME}.${ext}.sig" "${LEGACY_REPO_NAME}.${ext}.sig"
done
echo "Aliased databases to legacy name ${LEGACY_REPO_NAME}.db / ${LEGACY_REPO_NAME}.files"

# --- Positive verification: never report success on an unchecked premise ---
echo "=== Verifying repository ==="

SIGNED_FILES=(
	"${PKG_BASENAME}"
	"${REPO_NAME}.db.tar.gz"
	"${REPO_NAME}.files.tar.gz"
	"${REPO_NAME}.db"
	"${REPO_NAME}.files"
	# LEGACY_DB_ALIAS entries
	"${LEGACY_REPO_NAME}.db"
	"${LEGACY_REPO_NAME}.files"
)

for f in "${SIGNED_FILES[@]}"; do
	if gpg --batch --verify "${f}.sig" "${f}" >/dev/null 2>&1; then
		echo "  [OK]   signature valid: ${f}.sig"
	else
		echo "  [FAIL] signature verification failed: ${f}.sig"
		gpg --batch --verify "${f}.sig" "${f}" || true
		exit 1
	fi
done

# The db entry directory is <pkgname>-<pkgver>-<pkgrel>, i.e. the package
# filename minus the arch suffix.
DB_ENTRY="${PKG_BASENAME%-"${PKG_ARCH}".pkg.tar.zst}"
if bsdtar -tf "${REPO_NAME}.db.tar.gz" | grep -q "^${DB_ENTRY}/"; then
	echo "  [OK]   database lists ${DB_ENTRY}"
else
	echo "  [FAIL] database has no entry for ${DB_ENTRY}"
	bsdtar -tf "${REPO_NAME}.db.tar.gz"
	exit 1
fi

# %PGPSIG% proves the package signature was in place when repo-add ran, so
# pacman can verify the package straight from the database.
if bsdtar -xOqf "${REPO_NAME}.db.tar.gz" "${DB_ENTRY}/desc" | grep -q '^%PGPSIG%$'; then
	echo "  [OK]   database entry carries %PGPSIG%"
else
	echo "  [FAIL] database entry for ${DB_ENTRY} has no %PGPSIG% field"
	exit 1
fi

for ext in db files; do
	if cmp -s "${REPO_NAME}.${ext}" "${REPO_NAME}.${ext}.tar.gz"; then
		echo "  [OK]   ${REPO_NAME}.${ext} is byte-identical to ${REPO_NAME}.${ext}.tar.gz"
	else
		echo "  [FAIL] ${REPO_NAME}.${ext} differs from the .tar.gz it was signed from"
		exit 1
	fi
	# LEGACY_DB_ALIAS: the legacy-named copy must be the exact same bytes,
	# otherwise its (copied) signature would be a lie.
	if cmp -s "${LEGACY_REPO_NAME}.${ext}" "${REPO_NAME}.${ext}"; then
		echo "  [OK]   ${LEGACY_REPO_NAME}.${ext} is byte-identical to ${REPO_NAME}.${ext}"
	else
		echo "  [FAIL] ${LEGACY_REPO_NAME}.${ext} differs from ${REPO_NAME}.${ext}"
		exit 1
	fi
done

echo "=== Files produced in ${OUT_DIR} ==="
for f in "${SIGNED_FILES[@]}"; do
	file_size=$(stat -c%s "${f}")
	signature_size=$(stat -c%s "${f}.sig")
	printf '  %12s bytes  %s\n' "${file_size}" "${f}"
	printf '  %12s bytes  %s\n' "${signature_size}" "${f}.sig"
done

echo "=== pacman repository updated ==="
