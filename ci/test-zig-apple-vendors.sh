#!/bin/bash

set -euo pipefail

fail() {
    echo "test-zig-apple-vendors.sh: $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    fail "usage: $0 <prebuilts-directory>"
fi

for tool in xcrun zig; do
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
wg_go_slice="$prebuilts_dir/wg-go.xcframework/$slice_identifier"

[[ -f "$openssl_slice/libopenssl.a" ]] ||
    fail "missing OpenSSL macOS library"
[[ -f "$mbedtls_slice/libmbedtls.a" ]] ||
    fail "missing MbedTLS macOS library"
[[ -f "$wg_go_slice/libwg-go.a" ]] ||
    fail "missing wg-go macOS library"

case "$(uname -m)" in
    arm64|aarch64) target=aarch64-macos.13.0 ;;
    x86_64) target=x86_64-macos.13.0 ;;
    *) fail "unsupported host architecture: $(uname -m)" ;;
esac

sdk=$(xcrun --sdk macosx --show-sdk-path)
cache_dir="$repo_root/zig-out/vendor-test-cache"
global_cache_dir="$repo_root/zig-out/vendor-test-global-cache"
mkdir -p "$cache_dir" "$global_cache_dir"

cd "$repo_root"
zig build test \
    --cache-dir "$cache_dir" \
    --global-cache-dir "$global_cache_dir" \
    -Dtarget="$target" \
    -Dapple-sdk-path="$sdk" \
    -Dopenvpn=true \
    -Dwireguard=true \
    -Dopenssl-include="$openssl_slice/Headers" \
    -Dopenssl-lib="$openssl_slice" \
    -Dmbedtls-include="$mbedtls_slice/Headers" \
    -Dmbedtls-lib="$mbedtls_slice" \
    -Dwg-go-include="$wg_go_slice/Headers" \
    -Dwg-go-lib="$wg_go_slice"
