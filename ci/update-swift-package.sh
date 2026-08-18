#!/bin/bash

set -euo pipefail

fail() {
    echo "update-swift-package.sh: $*" >&2
    exit 1
}

if [[ $# -ne 2 ]]; then
    fail "usage: $0 <version> <checksum-file>"
fi

version=$1
checksum_file=$2

[[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || fail "invalid version: $version"
[[ -r $checksum_file ]] || fail "checksum file not readable: $checksum_file"

checksum=$(tr -d '\r\n' < "$checksum_file")
[[ $checksum =~ ^[0-9a-f]{64}$ ]] || fail "invalid checksum"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
cd "$repo_root"

git diff --quiet || fail "working tree has tracked changes"
git diff --cached --quiet || fail "index has staged changes"

package_pattern='^([[:space:]]*)nativeTarget = \.remote\("[^"]+", checksum: "[0-9a-f]{64}"\)$'
if [[ $(grep -Ec "$package_pattern" Package.swift) -ne 1 ]]; then
    fail "expected exactly one remote binary target in Package.swift"
fi

sed -i '' -E \
    "s/$package_pattern/\\1nativeTarget = .remote(\"$version\", checksum: \"$checksum\")/" \
    Package.swift
updated_line=$(grep -E "$package_pattern" Package.swift | sed -E 's/^[[:space:]]*//')
[[ $updated_line == \
    "nativeTarget = .remote(\"$version\", checksum: \"$checksum\")" \
]] || fail "failed to update Package.swift"

git add Package.swift
git commit -S -m "Update PartoutNative to $version"
