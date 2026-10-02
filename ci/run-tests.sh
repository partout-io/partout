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

command -v zig >/dev/null 2>&1 || fail "missing required tool: zig"

cd "$repo_root"
exec zig build test -Dopenvpn=true -Dwireguard=true
