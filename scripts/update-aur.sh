#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH_DIR="$(dirname "$SCRIPT_DIR")/arch"
PKGBUILD_PATH="$ARCH_DIR/PKGBUILD"

if [[ ! -f "$PKGBUILD_PATH" ]]; then
    echo "Error: Could not find PKGBUILD at $PKGBUILD_PATH"
    echo "Ensure your repo structure is: root/arch/PKGBUILD and root/scripts/$(basename "$0")"
    exit 1
fi

NEW_VER=$1
REL=${2:-1}

usage() {
    echo "Usage: $0 <new_version> [pkgrel]"
    echo "  <new_version>  : must be a valid version (e.g., 0.3.4)"
    echo "  [pkgrel]       : optional pkgrel (integer), defaults to 1"
    exit 1
}

if [ -z "$NEW_VER" ]; then
    usage
fi

cd "$ARCH_DIR"

if [[ ! "$NEW_VER" =~ ^[0-9]+(\.[0-9]+)*([a-zA-Z0-9]+)?$ ]]; then
    echo "Error: Invalid version '$NEW_VER'. Must be digits and dots only (optional letters/numbers)."
    usage
fi

if [[ ! "$REL" =~ ^[0-9]+$ ]]; then
    echo "Error: pkgrel must be a positive integer."
    usage
fi

echo "Updating PKGBUILD to $NEW_VER with pkgrel=$REL..."

if grep -q '^pkgver=' PKGBUILD; then
    sed -i "s/^pkgver=.*/pkgver=$NEW_VER/" PKGBUILD
else
    echo "pkgver=$NEW_VER" >>PKGBUILD
fi

if grep -q '^pkgrel=' PKGBUILD; then
    sed -i "s/^pkgrel=.*/pkgrel=$REL/" PKGBUILD
else
    awk -v rel="$REL" '/^pkgver=/{print;print "pkgrel=" rel;next}1' PKGBUILD >PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD
fi

echo "Updating PKGBUILD sha sums..."
updpkgsums

echo "Generating .SRCINFO..."
makepkg --printsrcinfo >.SRCINFO

# Cleanup of tarballs
for f in *.tar.gz *.tar.xz *.tar.bz2; do
    [ -f "$f" ] && echo "Removing tarball: $f" && rm "$f"
done
for d in pkg src; do
    [ -d "$d" ] && echo "Removing build directory: $d/" && rm -r "$d"
done

echo "PKGBUILD and .SRCINFO updated, cleanup complete!"
