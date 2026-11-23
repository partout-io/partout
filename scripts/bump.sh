#!/bin/bash

set -euo pipefail

fail() {
    echo "bump.sh: $*" >&2
    exit 1
}

version="${1:-}"
[[ $# -eq 1 ]] || fail "usage: $0 <version>"

[[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || fail "invalid version: $version"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
zig_constants="$root/src/version.zig"
swift_constants="$root/runtimes/apple/Sources/PartoutCore/Version.swift"

zig_pattern='^pub const number = "[^"]+";$'
if [[ $(grep -Ec "$zig_pattern" "$zig_constants") -ne 1 ]]; then
    fail "expected exactly one Zig version constant in $zig_constants"
fi

swift_pattern='^([[:space:]]*)public static let version = "[^"]+"$'
if [[ $(grep -Ec "$swift_pattern" "$swift_constants") -ne 1 ]]; then
    fail "expected exactly one Swift version constant in $swift_constants"
fi

sed -i '' -E "s/$zig_pattern/pub const number = \"$version\";/" "$zig_constants"
sed -i '' -E \
    "s/$swift_pattern/\\1public static let version = \"$version\"/" \
    "$swift_constants"

grep -Fxq "pub const number = \"$version\";" "$zig_constants" ||
    fail "failed to update $zig_constants"
grep -Eq "^[[:space:]]*public static let version = \"$version\"$" \
    "$swift_constants" || fail "failed to update $swift_constants"

git -C "$root" add "$zig_constants" "$swift_constants"
git -C "$root" commit -m "Bump version"
