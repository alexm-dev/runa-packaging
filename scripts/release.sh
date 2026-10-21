#!/usr/bin/env bash
#
# Updates the runa packages for the AUR, Homebrew and Scoop to a release.
#
# Usage: scripts/release.sh <version>
#
# Run it in a clean clone on main. With the version that is already packaged,
# it only verifies the packages and changes nothing.

set -euo pipefail

REPO="alexm-dev/runa"
WORKFLOW="$REPO/.github/workflows/releases.yml"
AUR_URL="https://aur.archlinux.org/runa.git"
AUR_PUSH_URL="ssh://aur@aur.archlinux.org/runa.git"

PKGBUILD="arch/PKGBUILD"
SRCINFO="arch/.SRCINFO"
FORMULA="homebrew/Formula/runa.rb"
MANIFEST="scoop/bucket/runa.json"

WIN_X64="runa-windows-x86_64.zip"
WIN_ARM64="runa-windows-aarch64.zip"
BREW_FILES=(
    runa-macos-x86_64.tar.gz
    runa-macos-aarch64.tar.gz
    runa-linux-x86_64-gnu.tar.gz
    runa-linux-aarch64-gnu.tar.gz
)
PACKAGE_FILES=("${BREW_FILES[@]}" "$WIN_X64" "$WIN_ARM64")
ASSETS=(SHA256SUMS.txt "${PACKAGE_FILES[@]}")

VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
SUMS_RE='^([0-9a-f]{64}) [ *](runa-[a-z0-9_.-]+)$'
BREW_VERSION_RE='^(  version ")[0-9.]+"$'
BREW_URL_RE='^ +url "https://github\.com/alexm-dev/runa/releases/download/'
BREW_URL_RE+='v#\{version\}/(runa-[a-z0-9_-]+\.tar\.gz)"$'
BREW_SHA_RE='^( +sha256 ")([0-9a-f]{64})"$'

VERSION=""
TAG=""
TMP=""
COMMIT=""
ARCHIVE_SUM=""
HINT=""
declare -A SUM

fail() {
    printf '\nError: %b\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$*"
}

hash_of() {
    local line
    line=$(sha256sum -- "$1")
    echo "${line%% *}"
}

changed_files() {
    git -C "$1" diff --name-only --ignore-submodules=all | tr '\n' ' '
}

# Removes the temporary directory and prints the hint for a failed commit or push.
on_exit() {
    local status=$?
    rm -rf -- "$TMP"
    if [[ $status -ne 0 && -n $HINT ]]; then
        printf '\n%s\n' "$HINT" >&2
    fi
}

# Checks that the tools are the system ones and that nothing redirects git or gh.
check_environment() {
    # shellcheck disable=SC2046
    unset $(compgen -e -X '!GIT_*') GH_HOST GH_REPO
    export LC_ALL=C GH_PROMPT_DISABLED=1

    [[ $EUID -ne 0 ]] || fail "do not run this as root"

    local tool path
    for tool in git gh jq sha256sum gzip cmp ssh updpkgsums makepkg; do
        path=$(command -v "$tool") || fail "$tool not found"
        [[ $(realpath -- "$path") == /usr/bin/* ]] || fail "$tool is $path, not a system binary"
    done
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in, run: gh auth login"
}

# Checks that a repository is checked out, belongs to alexm-dev and equals origin/main.
check_repo() {
    local dir=$1 name=$2
    local url_re="^(https://github\.com/|git@github\.com:)alexm-dev/$name(\.git)?$"

    local top=$PWD
    [[ $dir == . ]] || top=$PWD/$dir
    [[ $(git -C "$dir" rev-parse --show-toplevel) == "$top" ]] ||
        fail "$dir is not checked out, run: git submodule update --init"

    local fetch_url push_url
    fetch_url=$(git -C "$dir" remote get-url origin)
    push_url=$(git -C "$dir" remote get-url --push origin)
    [[ $fetch_url =~ $url_re ]] || fail "$dir fetches from $fetch_url"
    [[ $push_url =~ $url_re ]] || fail "$dir pushes to $push_url"

    git -C "$dir" fetch -q origin
    [[ -z $(git -C "$dir" status --porcelain) ]] || fail "$dir has uncommitted changes"
    [[ $(git -C "$dir" branch --show-current) == main ]] || fail "$dir is not on main"
    [[ $(git -C "$dir" rev-parse HEAD) == "$(git -C "$dir" rev-parse origin/main)" ]] ||
        fail "$dir is not equal to origin/main"
}

# Checks line endings, the version order and the PKGBUILD source.
check_package_files() {
    local file
    for file in "$PKGBUILD" "$SRCINFO" "$FORMULA" "$MANIFEST"; do
        ! grep -q $'\r' -- "$file" || fail "$file has CRLF line endings"
    done

    local current newest
    current=$(sed -n 's/^pkgver=//p' "$PKGBUILD")
    newest=$(printf '%s\n' "$current" "$VERSION" | sort -V | tail -n 1)
    [[ $newest == "$VERSION" ]] || fail "$VERSION is older than the packaged $current"

    # updpkgsums runs the PKGBUILD, so it must still download runa's tag archive
    local line
    # shellcheck disable=SC2016
    for line in \
        'pkgname=runa' \
        'url="https://github.com/alexm-dev/runa"' \
        'source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")'; do
        grep -qFx -- "$line" "$PKGBUILD" || fail "PKGBUILD is missing the line: $line"
    done

    local key
    for key in pkgver pkgrel sha256sums; do
        [[ $(grep -c "^$key=" "$PKGBUILD") -eq 1 ]] || fail "PKGBUILD needs exactly one $key= line"
    done
}

# Clones the AUR package and checks that it equals arch/.
check_aur() {
    local aur=$TMP/aur
    git clone -q --no-tags -- "$AUR_URL" "$aur"
    git -C "$aur" remote set-url --push origin "$AUR_PUSH_URL"

    [[ $(git -C "$aur" branch --show-current) == master ]] || fail "the AUR is not on master"
    [[ $(git -C "$aur" ls-files | tr '\n' ' ') == ".SRCINFO PKGBUILD " ]] ||
        fail "the AUR has unexpected files"

    local file
    for file in PKGBUILD .SRCINFO; do
        cmp -s -- "$aur/$file" "arch/$file" || fail "the AUR $file differs from arch/$file"
    done
    echo "The AUR equals arch/"
}

# Checks that the release is published and that its tag is a commit on main.
check_release() {
    local state
    state=$(gh release view "$TAG" -R "$REPO" --json tagName,isDraft,isPrerelease \
        --jq '"\(.tagName) \(.isDraft) \(.isPrerelease)"') || fail "release $TAG not found"
    [[ $state == "$TAG false false" ]] || fail "release $TAG is a draft or a prerelease"

    COMMIT=$(gh api "repos/$REPO/commits/refs/tags/$TAG" --jq .sha)
    [[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve $TAG to a commit"

    local relation
    relation=$(gh api "repos/$REPO/compare/$COMMIT...main" --jq .status)
    [[ $relation == ahead || $relation == identical ]] || fail "$TAG is not on runa's main"
    echo "$TAG is commit $COMMIT on main"
}

# Downloads the assets, verifies their attestations and reads SHA256SUMS.txt.
verify_assets() {
    local dir=$TMP/assets asset
    mkdir -- "$dir"

    for asset in "${ASSETS[@]}"; do
        gh release download "$TAG" -R "$REPO" -D "$dir" -p "$asset"
        [[ -f $dir/$asset ]] || fail "$asset is missing from release $TAG"
        gh attestation verify "$dir/$asset" -R "$REPO" \
            --signer-workflow "$WORKFLOW" \
            --source-ref "refs/tags/$TAG" \
            --source-digest "$COMMIT" \
            --deny-self-hosted-runners >/dev/null || fail "attestation failed for $asset"
    done

    local line name
    while IFS= read -r line; do
        [[ $line =~ $SUMS_RE ]] || fail "unexpected line in SHA256SUMS.txt: $line"
        name=${BASH_REMATCH[2]}
        [[ -z ${SUM[$name]:-} ]] || fail "SHA256SUMS.txt lists $name twice"
        SUM[$name]=${BASH_REMATCH[1]}
    done <"$dir/SHA256SUMS.txt"

    for asset in "${PACKAGE_FILES[@]}"; do
        [[ -n ${SUM[$asset]:-} ]] || fail "$asset is not in SHA256SUMS.txt"
        [[ $(hash_of "$dir/$asset") == "${SUM[$asset]}" ]] ||
            fail "$asset does not match SHA256SUMS.txt"
    done
    echo "All ${#ASSETS[@]} assets are attested and match SHA256SUMS.txt"
}

# Updates the PKGBUILD with the official tools and checks the downloaded archive.
update_aur() {
    sed -i -e "s/^pkgver=.*/pkgver=$VERSION/" -e "s/^pkgrel=.*/pkgrel=1/" "$PKGBUILD"

    mkdir -- "$TMP/src"
    (
        cd arch
        SRCDEST=$TMP/src updpkgsums
        makepkg --printsrcinfo >.SRCINFO
    )

    # GitHub writes the commit into the archive header
    local archive=$TMP/src/runa-$VERSION.tar.gz
    [[ -f $archive ]] || fail "updpkgsums did not download $archive"
    gzip -dc -- "$archive" >"$TMP/source.tar"
    [[ $(git get-tar-commit-id <"$TMP/source.tar") == "$COMMIT" ]] ||
        fail "the source archive is not commit $COMMIT"
    ARCHIVE_SUM=$(hash_of "$archive")
}

# Writes the version and the hashes. Each sha256 line belongs to the url line above it.
update_homebrew() {
    local line file=""
    while IFS= read -r line; do
        if [[ $line =~ $BREW_VERSION_RE ]]; then
            line="${BASH_REMATCH[1]}$VERSION\""
        elif [[ $line =~ $BREW_URL_RE ]]; then
            file=${BASH_REMATCH[1]}
        elif [[ -n $file && $line =~ $BREW_SHA_RE ]]; then
            line="${BASH_REMATCH[1]}${SUM[$file]}\""
            file=""
        fi
        printf '%s\n' "$line"
    done <"$FORMULA" >"$TMP/runa.rb"
    cat -- "$TMP/runa.rb" >"$FORMULA"
}

# Writes the version, the urls and the hashes.
update_scoop() {
    jq --indent 4 \
        --arg version "$VERSION" \
        --arg base "https://github.com/$REPO/releases/download/$TAG" \
        --arg x64 "${SUM[$WIN_X64]}" \
        --arg arm64 "${SUM[$WIN_ARM64]}" \
        '.version = $version
        | .architecture."64bit".url = "\($base)/runa-windows-x86_64.zip"
        | .architecture."64bit".hash = $x64
        | .architecture.arm64.url = "\($base)/runa-windows-aarch64.zip"
        | .architecture.arm64.hash = $arm64' \
        "$MANIFEST" >"$TMP/runa.json"
    cat -- "$TMP/runa.json" >"$MANIFEST"
}

verify_aur() {
    local line
    for line in "pkgver=$VERSION" "pkgrel=1" "sha256sums=('$ARCHIVE_SUM')"; do
        grep -qFx -- "$line" "$PKGBUILD" || fail "PKGBUILD is missing the line: $line"
    done
    for line in \
        "pkgver = $VERSION" \
        "pkgrel = 1" \
        "sha256sums = $ARCHIVE_SUM" \
        "source = runa-$VERSION.tar.gz::https://github.com/$REPO/archive/$TAG.tar.gz"; do
        grep -qFx -- $'\t'"$line" "$SRCINFO" || fail ".SRCINFO is missing the line: $line"
    done
    echo "PKGBUILD and .SRCINFO match the source archive"
}

verify_homebrew() {
    grep -qFx -- "  version \"$VERSION\"" "$FORMULA" || fail "runa.rb is not at version $VERSION"

    local -A seen
    local line file="" hash
    while IFS= read -r line; do
        if [[ $line =~ $BREW_URL_RE ]]; then
            file=${BASH_REMATCH[1]}
        elif [[ $line =~ $BREW_SHA_RE ]]; then
            hash=${BASH_REMATCH[2]}
            [[ -n $file ]] || fail "runa.rb has a sha256 line without a url line above it"
            [[ -z ${seen[$file]:-} ]] || fail "runa.rb lists $file twice"
            [[ $hash == "${SUM[$file]:-}" ]] || fail "runa.rb has the wrong hash for $file"
            seen[$file]=1
            file=""
        fi
    done <"$FORMULA"

    for file in "${BREW_FILES[@]}"; do
        [[ -n ${seen[$file]:-} ]] || fail "runa.rb has no hash for $file"
    done
    [[ ${#seen[@]} -eq ${#BREW_FILES[@]} ]] || fail "runa.rb has unexpected downloads"
    echo "The version and all ${#BREW_FILES[@]} hashes match the release"
}

verify_scoop() {
    local base="https://github.com/$REPO/releases/download/$TAG"
    local expected actual
    expected=$(printf '%s\n' \
        "$VERSION" \
        "$base/$WIN_X64" "${SUM[$WIN_X64]}" "runa-windows-x86_64" \
        "$base/$WIN_ARM64" "${SUM[$WIN_ARM64]}" "runa-windows-aarch64")
    actual=$(jq -r '.version, (.architecture."64bit", .architecture.arm64
        | .url, .hash, .extract_dir)' "$MANIFEST")
    [[ $actual == "$expected" ]] || fail "runa.json does not match the release:\n$actual"
    echo "The version, both urls and both hashes match the release"
}

# Fails unless the line changes in a file all match a pattern.
check_lines() {
    local dir=$1 file=$2 allowed=$3
    local bad
    bad=$(git -C "$dir" diff -U0 -- "$file" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' |
        grep -vE "$allowed" || true)
    [[ -z $bad ]] || fail "unexpected line changes in $file:\n$bad"
}

# Checks that only the version, url and hash lines of the five package files changed.
check_changes() {
    local dir
    for dir in . homebrew scoop; do
        [[ -z $(git -C "$dir" ls-files --others --exclude-standard) ]] ||
            fail "untracked files in $dir"
    done

    [[ $(changed_files .) == "arch/.SRCINFO arch/PKGBUILD " ]] ||
        fail "unexpected changes in runa-packaging: $(changed_files .)"
    [[ $(changed_files homebrew) == "Formula/runa.rb " ]] ||
        fail "unexpected changes in homebrew: $(changed_files homebrew)"
    [[ $(changed_files scoop) == "bucket/runa.json " ]] ||
        fail "unexpected changes in scoop: $(changed_files scoop)"

    check_lines . "$PKGBUILD" '^[+-](pkgver|pkgrel|sha256sums)='
    check_lines . "$SRCINFO" $'^[+-]\t(pkgver|pkgrel|source|sha256sums) = '
    check_lines homebrew Formula/runa.rb '^[+-] +(version|sha256) "'
    check_lines scoop bucket/runa.json '^[+-] +"(version|url|hash)": '
    echo "Only version, url and hash lines changed"
}

# Commits files in a repository and checks that the commit carries a signature.
commit() {
    local dir=$1 message=$2
    shift 2
    git -C "$dir" add -- "$@"
    git -C "$dir" commit -q -m "$message" -- "$@"
    [[ $(git -C "$dir" cat-file commit HEAD) == *$'\ngpgsig '* ]] ||
        fail "the commit in $dir is not signed"
    git -C "$dir" --no-pager log --oneline -1
}

commit_all() {
    commit homebrew "runa: Update to version $VERSION" Formula/runa.rb
    commit scoop "runa: Update to version $VERSION" bucket/runa.json
    commit . "chore: update runa aur package to $VERSION" "$PKGBUILD" "$SRCINFO"
    commit . "chore: update runa homebrew package to $VERSION" homebrew
    commit . "chore: update runa scoop bucket to $VERSION" scoop

    cp -- "$PKGBUILD" "$SRCINFO" "$TMP/aur/"
    commit "$TMP/aur" "Update to $TAG" PKGBUILD .SRCINFO
}

push() {
    local dir=$1 branch=$2 ssh=$3
    git -C "$dir" -c core.sshCommand="$ssh" push -q origin "$branch"

    local remote
    remote=$(git -C "$dir" ls-remote origin "refs/heads/$branch")
    [[ ${remote%%[[:space:]]*} == "$(git -C "$dir" rev-parse HEAD)" ]] ||
        fail "the remote $branch of $dir is not the pushed commit"
    echo "Pushed $dir"
}

push_all() {
    local github_ssh aur_ssh
    github_ssh="$(git config core.sshCommand || echo ssh) -o StrictHostKeyChecking=yes"
    aur_ssh="ssh -o StrictHostKeyChecking=yes"

    push "$TMP/aur" master "$aur_ssh"
    HINT="The AUR is published. Push the rest by hand, in this order:
    git -C homebrew push origin main
    git -C scoop push origin main
    git push origin main"
    push homebrew main "$github_ssh"
    push scoop main "$github_ssh"
    push . main "$github_ssh"
    HINT=""
}

confirm() {
    local answer
    read -rp "$1" answer
    [[ $answer == "$2" ]]
}

main() {
    [[ $# -eq 1 && $1 =~ $VERSION_RE ]] || fail "usage: $0 <version>, for example 0.12.4"
    VERSION=$1
    TAG="v$VERSION"

    cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
    TMP=$(mktemp -d)
    trap on_exit EXIT

    step "Checking the environment"
    check_environment

    step "Checking the repositories"
    check_repo . runa-packaging
    check_repo homebrew homebrew-tap
    check_repo scoop scoop-bucket
    check_package_files

    step "Checking the AUR"
    check_aur

    step "Checking release $TAG"
    check_release

    step "Verifying the release assets"
    verify_assets

    step "Updating the packages"
    update_aur
    update_homebrew
    update_scoop

    step "Verifying the packages"
    verify_aur
    verify_homebrew
    verify_scoop

    if [[ -z "$(changed_files .)$(changed_files homebrew)$(changed_files scoop)" ]]; then
        step "All packages are at $VERSION and verified, nothing to do"
        return
    fi
    check_changes

    step "Changes"
    git --no-pager diff --ignore-submodules=all
    git -C homebrew --no-pager diff
    git -C scoop --no-pager diff

    local discard="git restore arch && git -C homebrew restore . && git -C scoop restore ."
    echo
    confirm "Type $VERSION to commit: " "$VERSION" ||
        fail "not committed. Discard the changes with: $discard"

    HINT="Nothing is pushed. Undo the commits in each repository with: git reset --keep origin/main"
    step "Committing"
    commit_all

    echo
    confirm "Type push to publish: " push || fail "not pushed. $HINT"

    step "Publishing"
    push_all

    step "Published runa $VERSION to the AUR, Homebrew and Scoop"
}

main "$@"
