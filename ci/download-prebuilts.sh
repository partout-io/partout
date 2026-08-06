#!/bin/bash

set -euo pipefail

fail() {
    echo "download-prebuilts.sh: $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    fail "usage: $0 <artifacts-directory>"
fi

for tool in ditto gh; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

prebuilts_repository=partout-io/prebuilts
artifacts_dir=$1
mkdir -p "$artifacts_dir"
artifacts_dir=$(cd "$artifacts_dir" && pwd -P)

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/partout-prebuilts.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

prebuilts_tag=$(gh release view \
    --repo "$prebuilts_repository" \
    --json tagName \
    --jq .tagName)
[[ -n $prebuilts_tag ]] || fail "unable to resolve the latest prebuilts release"

for vendor in openssl mbedtls wg-go; do
    archive="$vendor.xcframework.zip"
    package_dir="$artifacts_dir/$vendor-apple"
    gh release download "$prebuilts_tag" \
        --repo "$prebuilts_repository" \
        --pattern "$archive" \
        --dir "$temp_dir"
    mkdir -p "$package_dir"
    ditto -x -k "$temp_dir/$archive" "$package_dir"
    [[ -d "$package_dir/$vendor.xcframework" ]] ||
        fail "missing $vendor.xcframework in $archive"
done

echo "$prebuilts_tag"
