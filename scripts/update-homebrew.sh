#!/usr/bin/env bash

NEW_VERSION=$1

if [ -z "$NEW_VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# Paths relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA_PATH="$SCRIPT_DIR/../homebrew/Formula/runa.rb"
SHASUMS_URL="https://github.com/alexm-dev/runa/releases/download/v$NEW_VERSION/SHA256SUMS.txt"

echo "Downloading hashes from $SHASUMS_URL..."
SHASUMS_DATA=$(curl -sL "$SHASUMS_URL")

if [ $? -ne 0 ] || [ -z "$SHASUMS_DATA" ]; then
    echo "Error: Failed to download SHA256SUMS.txt. Is version v$NEW_VERSION live?"
    exit 1
fi

# Update the Version string
sed -i -E "s/(version \")[0-9.]+(\")/\1$NEW_VERSION\2/" "$FORMULA_PATH"

# Update Hashes for each architecture
ARCHS=("macos-x86_64" "macos-aarch64" "linux-x86_64-gnu" "linux-aarch64-gnu")

for ARCH in "${ARCHS[@]}"; do
    HASH=$(echo "$SHASUMS_DATA" | grep "runa-$ARCH.tar.gz" | awk '{print $1}')

    if [ -n "$HASH" ]; then
        echo "Updating $ARCH with hash: ${HASH:0:8}..."

        sed -i -E "/runa-$ARCH\.tar\.gz/ { n; s/sha256 \"[a-f0-9]{64}\"/sha256 \"$HASH\"/; }" "$FORMULA_PATH"
    else
        echo "Warning: No hash found for $ARCH"
    fi
done

echo "✅ Updated $FORMULA_PATH"
