#!/usr/bin/env bash
set -e

NEW_VER=$1
REL=${2:-1}

if [ -z "$NEW_VER" ]; then
    echo "Usage: $0 <new_version> [pkgrel]"
    exit 1
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

echo "Done!"
