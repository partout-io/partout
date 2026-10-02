#!/usr/bin/env bash
# Build only the host wg-go library for local Partout development.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: scripts/build-wg-go-local.sh" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd "${script_dir}/.." && pwd)"
host_os="$(go env GOHOSTOS)"
host_arch="$(go env GOHOSTARCH)"
work_dir="${repository_dir}/.build/local/wg-go/${host_os}-${host_arch}"
install_dir="${work_dir}/install"
make_args=(
    "GOOS=${host_os}" "GOARCH=${host_arch}"
    "BUILDDIR=${work_dir}/build" "DESTDIR=${install_dir}"
)

case "${host_os}" in
    darwin)
        # Retain the release build's sleep-aware runtime patch, and prepare it
        # again when either the host toolchain or the patch changes.
        runtime_key="$( { go version; go env GOROOT; cat "${repository_dir}"/src/wireguard/go/goruntime-*.diff; } | shasum -a 256 | cut -d ' ' -f 1)"
        make_args+=(
            APPLE=1 "TMPROOTDIR=${work_dir}/goroot-${runtime_key}"
            "SDKROOT=$(xcrun --sdk macosx --show-sdk-path)"
            "TARGET=$(uname -m)-apple-macos"
        )
        ;;
    linux)
        make_args+=(BUILDMODE=c-shared)
        ;;
    *)
        echo "Local wg-go builds support macOS and Linux; got ${host_os}." >&2
        exit 1
        ;;
esac

# Preserve the patched runtime and let Go reuse its compilation cache.
make -C "${repository_dir}/src/wireguard/go" install "${make_args[@]}"

printf '\nUse these options with Partout’s zig build command:\n'
printf '  -Dwireguard=true "-Dwg-go-include=%s/include" "-Dwg-go-lib=%s/lib"\n' \
    "${install_dir}" "${install_dir}"
