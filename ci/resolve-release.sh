#!/bin/bash

set -euo pipefail

fail() {
    echo "::error::$*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail "usage: $0"
[[ ${GITHUB_REF_TYPE:-} == branch && ${GITHUB_REF_NAME:-} == master ]] ||
    fail "Releases must run from master"
[[ -n ${GITHUB_OUTPUT:-} ]] || fail "GITHUB_OUTPUT is not set"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
cd "$repo_root"

swift_version=$(sed -nE \
    's/^[[:space:]]*public static let version = "([^"]+)"$/\1/p' \
    cross/apple/Sources/PartoutCore/Version.swift)
native_version=$(sed -nE \
    's/^pub const number = "([^"]+)";$/\1/p' \
    src/version.zig)
artifact_version=$(sed -nE \
    's/^[[:space:]]*nativeTarget = \.remote\("([^"]+)", checksum: "[0-9a-f]{64}"\)$/\1/p' \
    Package.swift)

for version in "$swift_version" "$native_version" "$artifact_version"; do
    [[ $version =~ ^[0-9A-Za-z.+-]+$ ]] || fail "Invalid release version"
done

mode=swift
if [[ $native_version != "$artifact_version" ]]; then
    [[ $swift_version == "$native_version" ]] ||
        fail "Native releases require matching Swift and native versions"
    mode=native
fi

tag_status=0
git ls-remote --exit-code --tags \
    origin "refs/tags/$swift_version" >/dev/null 2>&1 || tag_status=$?
if [[ $tag_status -eq 0 ]]; then
    [[ ${GITHUB_EVENT_NAME:-} != workflow_dispatch ]] ||
        fail "Tag $swift_version already exists"
    echo "::notice::Tag $swift_version already exists; nothing to release"
    mode=none
elif [[ $tag_status -ne 2 ]]; then
    fail "Unable to query tag $swift_version"
fi

echo "mode=$mode" >> "$GITHUB_OUTPUT"
echo "version=$swift_version" >> "$GITHUB_OUTPUT"
echo "native_version=$native_version" >> "$GITHUB_OUTPUT"
