#!/bin/bash

set -euo pipefail

fail() {
    echo "run-swift-tests.sh: $*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail "usage: $0"
command -v swift >/dev/null 2>&1 || fail "missing required tool: swift"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)

cd "$repo_root"
swift test
(cd cross/apple-legacy && swift test)
