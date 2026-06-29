#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: ci/verify-linux.sh <install-dir>"
    exit 1
fi

get_required_command_path() {
    local name=$1

    if ! command -v "$name" >/dev/null 2>&1; then
        echo "$name not found on PATH" >&2
        exit 1
    fi
}

get_required_artifact() {
    local result_var=$1
    local root=$2
    local relative_path=$3
    local path="$root/$relative_path"

    if [[ ! -f $path ]]; then
        echo "Missing artifact: $path" >&2
        exit 1
    fi
    if [[ ! -s $path ]]; then
        echo "Empty artifact: $path" >&2
        exit 1
    fi

    local size
    size=$(wc -c < "$path")
    size=${size//[[:space:]]/}
    echo "$relative_path : $size bytes"
    printf -v "$result_var" "%s" "$path"
}

assert_x64_artifact() {
    local path=$1
    local headers

    headers=$(readelf -h "$path")
    if [[ ! $headers =~ Class:[[:space:]]+ELF64 ]]; then
        echo "Artifact is not ELF64: $path" >&2
        exit 1
    fi
    if [[ ! $headers =~ Machine:[[:space:]]+Advanced[[:space:]]Micro[[:space:]]Devices[[:space:]]X86-64 ]]; then
        echo "Artifact is not x64: $path" >&2
        exit 1
    fi
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
cd "$repo_root"

install_dir=$1
install_root="$(cd "$install_dir" && pwd -P)"
get_required_command_path readelf
echo "Using readelf: $(command -v readelf)"
echo "Verifying install directory: $install_root"

get_required_artifact partout_library "$install_root" "lib/libpartout.so"
assert_x64_artifact "$partout_library"
