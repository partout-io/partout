#!/bin/bash

set -euo pipefail

fail() {
    echo "run-tests.sh: $*" >&2
    exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)

if [[ $# -eq 2 && $1 == --apple-vendors ]]; then
    exec "$script_dir/test-zig-apple-vendors.sh" "$2"
fi
[[ $# -eq 0 ]] || fail "usage: $0 [--apple-vendors <prebuilts-directory>]"

for tool in cmake go zig; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

cd "$repo_root"
cmake -S . -B zig-out/test-cmake -DCMAKE_BUILD_TYPE=Debug \
    -DPP_BUILD_LIBRARY=OFF -DPP_BUILD_USE_OPENVPN=ON -DPP_BUILD_USE_WIREGUARD=ON
exec cmake --build zig-out/test-cmake --target partout-test
