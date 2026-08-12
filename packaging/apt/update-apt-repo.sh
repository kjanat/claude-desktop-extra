#!/bin/bash
# update-apt-repo.sh — Build APT repository metadata from .deb files
#
# Usage: update-apt-repo.sh <deb_file> <repo_dir> <gpg_key_id>
#
# Multi-arch support: the architecture is auto-detected from the .deb filename.
# The script places packages in deb/<arch>/ subdirectories and generates
# a combined Packages index covering all architectures.
#
# 1. Auto-detects arch from .deb filename (amd64 or arm64)
# 2. Copies new .deb into repo_dir/deb/<arch>/
# 3. Prunes old versions per arch (keeps latest 1)
# 4. Generates Packages, Packages.gz, Release (covering all arches)
# 5. GPG-signs Release (Release.gpg + InRelease)

set -euo pipefail

DEB_FILE="$1"
REPO_DIR="$2"
GPG_KEY_ID="$3"

if [[ ! -f "${DEB_FILE}" ]]; then
	echo "ERROR: .deb file not found: ${DEB_FILE}"
	exit 1
fi

# Auto-detect architecture from .deb filename (e.g., _amd64.deb or _arm64.deb)
DEB_BASENAME=$(basename "${DEB_FILE}")
if [[ "${DEB_BASENAME}" =~ _([a-z0-9]+)\.deb$ ]]; then
	DEB_ARCH="${BASH_REMATCH[1]}"
else
	echo "WARNING: Could not detect arch from filename, defaulting to amd64"
	DEB_ARCH="amd64"
fi

echo "=== Updating APT repository ==="
echo "  .deb file:  ${DEB_FILE}"
echo "  Arch:       ${DEB_ARCH}"
echo "  Repo dir:   ${REPO_DIR}"
echo "  GPG key:    ${GPG_KEY_ID}"

# Create directory structure for this architecture
mkdir -p "${REPO_DIR}/deb/${DEB_ARCH}"

# Copy new .deb
cp "${DEB_FILE}" "${REPO_DIR}/deb/${DEB_ARCH}/"
echo "Copied ${DEB_BASENAME} to deb/${DEB_ARCH}/"

# Prune old versions within this arch - keep only the latest 1 PER PACKAGE NAME
# (the repo carries claude-desktop-extra plus the transitional claude-desktop-bin,
# so pruning must group by the package-name part before the first underscore).
cd "${REPO_DIR}/deb/${DEB_ARCH}"
declare -A PACKAGE_NAMES=()
shopt -s nullglob
deb_packages=(./*.deb)
for deb_path in "${deb_packages[@]}"; do
	deb_name="${deb_path#./}"
	PACKAGE_NAMES["${deb_name%%_*}"]=1
done

for pkg_name in "${!PACKAGE_NAMES[@]}"; do
	newest_package=""
	newest_mtime=0
	for package_path in ./"${pkg_name}"_*.deb; do
		package_mtime=$(stat -c %Y "${package_path}")
		if [[ -z "${newest_package}" || "${package_mtime}" -gt "${newest_mtime}" ]]; then
			[[ -z "${newest_package}" ]] || rm -f -- "${newest_package}"
			newest_package="${package_path}"
			newest_mtime="${package_mtime}"
		else
			rm -f -- "${package_path}"
		fi
	done
done
kept_packages=(./*.deb)
KEPT=${#kept_packages[@]}
echo "Kept ${KEPT} .deb file(s) in ${DEB_ARCH} after pruning"

# Generate combined Packages index covering all architectures
cd "${REPO_DIR}/deb"

# Build Packages from all arch subdirectories
: >Packages
ARCHES=""
for arch_dir in */; do
	arch_dir="${arch_dir%/}"
	# Only process directories that contain .deb files
	arch_packages=("${arch_dir}"/*.deb)
	if ((${#arch_packages[@]} > 0)); then
		dpkg-scanpackages --multiversion --arch "${arch_dir}" "${arch_dir}/" >>Packages
		ARCHES+="${arch_dir} "
	fi
done

gzip -9c Packages >Packages.gz
PACKAGE_LINES=$(wc -l <Packages)
echo "Generated Packages index (${PACKAGE_LINES} lines, arches: ${ARCHES})"

# Generate Release file
apt-ftparchive release . >Release
echo "Generated Release file"

# GPG sign
rm -f Release.gpg InRelease
gpg --batch --yes --default-key "${GPG_KEY_ID}" --detach-sign --armor -o Release.gpg Release
gpg --batch --yes --default-key "${GPG_KEY_ID}" --clearsign -o InRelease Release
echo "Signed Release (Release.gpg + InRelease)"

echo "=== APT repository updated ==="
