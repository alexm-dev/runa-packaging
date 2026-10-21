#!/usr/bin/env bash
set -euo pipefail

NEW_VERSION=${1:-}

if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: $0 <version>   (e.g. 0.12.3)"
    exit 1
fi

# Paths relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA_PATH="$SCRIPT_DIR/../homebrew/Formula/runa.rb"
SHASUMS_URL="https://github.com/alexm-dev/runa/releases/download/v$NEW_VERSION/SHA256SUMS.txt"

echo "Downloading hashes from $SHASUMS_URL..."
# -f makes a missing release an error instead of downloading GitHub's 404 page
if ! SHASUMS_DATA=$(curl -fsSL "$SHASUMS_URL"); then
    echo "Error: Failed to download SHA256SUMS.txt. Is version v$NEW_VERSION live?"
    exit 1
fi

# Collect every hash before touching the formula, so a missing one changes nothing
ARCHS=("macos-x86_64" "macos-aarch64" "linux-x86_64-gnu" "linux-aarch64-gnu")
declare -A HASHES

for ARCH in "${ARCHS[@]}"; do
    HASH=$(echo "$SHASUMS_DATA" | tr -d '\r' | awk -v f="runa-$ARCH.tar.gz" '$2 == f || $2 == "*" f { print $1 }')

    if [[ ! "$HASH" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: No valid hash found for $ARCH, formula left unchanged"
        exit 1
    fi
    HASHES[$ARCH]=$HASH
done

# Update the Version string
sed -i -E "s/(version \")[0-9.]+(\")/\1$NEW_VERSION\2/" "$FORMULA_PATH"

# Update Hashes for each architecture
for ARCH in "${ARCHS[@]}"; do
    HASH=${HASHES[$ARCH]}
    echo "Updating $ARCH with hash: ${HASH:0:8}..."

    sed -i -E "/runa-$ARCH\.tar\.gz/ { n; s/sha256 \"[a-f0-9]{64}\"/sha256 \"$HASH\"/; }" "$FORMULA_PATH"

    if ! grep -qF "sha256 \"$HASH\"" "$FORMULA_PATH"; then
        echo "Error: Hash for $ARCH was not written to $FORMULA_PATH"
        exit 1
    fi
done

echo "✅ Updated $FORMULA_PATH"
