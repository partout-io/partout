#!/bin/bash
set -e

version="${1:-}"
if [[ -z $version ]]; then
    echo "Version required"
    exit 1
fi

if [[ ! $version =~ ^[0-9A-Za-z.+-]+$ ]]; then
    echo "Invalid version: $version"
    exit 1
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zig_constants="$root/src/partout.zig"

zig_pattern='^const version = "[^"]+";$'
if [[ $(grep -Ec "$zig_pattern" "$zig_constants") -ne 1 ]]; then
    echo "Expected exactly one Zig version constant in $zig_constants"
    exit 1
fi

sed -i '' -E "s/$zig_pattern/const version = \"$version\";/" "$zig_constants"

git -C "$root" add "$zig_constants"
git -C "$root" commit --allow-empty -m "Bump version"
