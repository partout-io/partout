#!/bin/bash

set -euo pipefail

fail() {
    echo "bump-swift.sh: $*" >&2
    exit 1
}

version="${1:-}"
[[ $# -eq 1 ]] || fail "usage: $0 <version>"
[[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || fail "invalid version: $version"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
swift_constants="$root/cross/apple/Sources/PartoutCore/Version.swift"
swift_pattern='^([[:space:]]*)public static let version = "[^"]+"$'

if [[ $(grep -Ec "$swift_pattern" "$swift_constants") -ne 1 ]]; then
    fail "expected exactly one Swift version constant in $swift_constants"
fi

sed -i '' -E \
    "s/$swift_pattern/\\1public static let version = \"$version\"/" \
    "$swift_constants"

grep -Eq "^[[:space:]]*public static let version = \"$version\"$" \
    "$swift_constants" || fail "failed to update $swift_constants"

git -C "$root" add "$swift_constants"
git -C "$root" commit -m "Bump Swift version"
