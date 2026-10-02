#!/bin/bash

set -euo pipefail

fail() {
    echo "test-zig-apple-vendors.sh: $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    fail "usage: $0 <prebuilts-directory>"
fi

for tool in cmake go xcrun zig; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
prebuilts_dir=$1
[[ -d $prebuilts_dir ]] || fail "missing prebuilts directory: $prebuilts_dir"
prebuilts_dir=$(cd "$prebuilts_dir" && pwd -P)

slice_identifier=macos-arm64_x86_64
openssl_slice="$prebuilts_dir/openssl.xcframework/$slice_identifier"
mbedtls_slice="$prebuilts_dir/mbedtls.xcframework/$slice_identifier"

[[ -f "$openssl_slice/libopenssl.a" ]] ||
    fail "missing OpenSSL macOS library"
[[ -f "$mbedtls_slice/libmbedtls.a" ]] ||
    fail "missing MbedTLS macOS library"

cmake -S "$repo_root" -B "$repo_root/zig-out/vendor-test-cmake" \
    -DCMAKE_BUILD_TYPE=Debug -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DPP_BUILD_LIBRARY=OFF -DPP_BUILD_USE_OPENVPN=ON -DPP_BUILD_USE_WIREGUARD=ON \
    -DPP_BUILD_USE_OPENSSL=ON -DPP_BUILD_USE_MBEDTLS=ON \
    -DPP_BUILD_OPENSSL_INCLUDE="$openssl_slice/Headers" -DPP_BUILD_OPENSSL_LIB="$openssl_slice" \
    -DPP_BUILD_MBEDTLS_INCLUDE="$mbedtls_slice/Headers" -DPP_BUILD_MBEDTLS_LIB="$mbedtls_slice"
cmake --build "$repo_root/zig-out/vendor-test-cmake" --target partout-test
