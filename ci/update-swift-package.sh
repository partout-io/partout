#!/bin/bash

set -euo pipefail

fail() {
    echo "update-swift-package.sh: $*" >&2
    exit 1
}

if [[ $# -ne 3 ]]; then
    fail "usage: $0 <version> <checksum-file> <branch>"
fi

version=$1
checksum_file=$2
branch=$3

[[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || fail "invalid version: $version"
[[ -r $checksum_file ]] || fail "checksum file not readable: $checksum_file"
git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
    fail "invalid branch: $branch"

checksum=$(tr -d '\r\n' < "$checksum_file")
[[ $checksum =~ ^[0-9a-f]{64}$ ]] || fail "invalid checksum"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
cd "$repo_root"

package_pattern='^    \.remote\("[^"]+", checksum: "[0-9a-f]{64}"\)$'
if [[ $(grep -Ec "$package_pattern" Package.swift) -ne 1 ]]; then
    fail "expected exactly one remote binary target in Package.swift"
fi

sed -i '' -E \
    "s/$package_pattern/    .remote(\"$version\", checksum: \"$checksum\")/" \
    Package.swift
grep -Fx \
    "    .remote(\"$version\", checksum: \"$checksum\")" \
    Package.swift >/dev/null || fail "failed to update Package.swift"

if git diff --quiet -- Package.swift; then
    exit 0
fi

git add Package.swift
git commit -S -m "Update PartoutNative to $version"
git push origin "HEAD:refs/heads/$branch"
