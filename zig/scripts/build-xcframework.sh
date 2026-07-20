#!/bin/bash

set -euo pipefail

# Xcode scheme actions export these internal Swift build settings, but command-line
# developer tools reject them as unsupported environment overrides.
unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION

framework_name=PartoutNative
ios_min=16.0
macos_min=13.0
tvos_min=17.0

fail() {
    echo "build-xcframework.sh: $*" >&2
    exit 1
}

if [[ $# -lt 1 ]]; then
    fail "usage: $0 <output.xcframework> [artifacts-directory] [--full]"
fi

output_argument=$1
artifacts_argument=
full_build=0
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            [[ $full_build -eq 0 ]] || fail "duplicate option: --full"
            full_build=1
            ;;
        -*) fail "unknown option: $1" ;;
        *)
            [[ -z $artifacts_argument ]] || fail "unexpected argument: $1"
            artifacts_argument=$1
            ;;
    esac
    shift
done

normalize_arch() {
    case "$1" in
        arm64|aarch64) printf '%s\n' arm64 ;;
        x86_64) printf '%s\n' x86_64 ;;
        *) return 1 ;;
    esac
}

normalize_platform() {
    case "${1#-}" in
        macos|macosx*) printf '%s\n' macos ;;
        ios|iphoneos*) printf '%s\n' ios ;;
        ios-simulator|iphonesimulator*) printf '%s\n' ios-simulator ;;
        tvos|appletvos*) printf '%s\n' tvos ;;
        tvos-simulator|appletvsimulator*) printf '%s\n' tvos-simulator ;;
        *) return 1 ;;
    esac
}

resolve_active_arch() {
    local candidates=("${CURRENT_ARCH:-}")
    local candidate
    local configured_archs

    if [[ -n ${ARCHS:-} ]]; then
        read -r -a configured_archs <<< "$ARCHS"
        [[ ${#configured_archs[@]} -ne 1 ]] || candidates+=("${configured_archs[0]}")
    fi
    candidates+=("${NATIVE_ARCH_ACTUAL:-}" "$(uname -m)")
    for candidate in "${candidates[@]}"; do
        normalize_arch "$candidate" && return
    done
    fail "unable to determine active architecture"
}

resolve_active_platform() {
    local candidate

    for candidate in "${PLATFORM_NAME:-}" "${SDK_NAME:-}" "${EFFECTIVE_PLATFORM_NAME:-}"; do
        [[ -z $candidate ]] || normalize_platform "$candidate" ||
            fail "unsupported active platform: $candidate"
        [[ -z $candidate ]] || return 0
    done
    printf '%s\n' macos
}

active_arch=
active_platform=
if [[ $full_build -eq 0 ]]; then
    active_arch=$(resolve_active_arch)
    active_platform=$(resolve_active_platform)
    echo "Building active slice only: $active_platform $active_arch (pass --full for all slices)"
else
    echo "Building all platform and architecture slices"
fi

for tool in zig xcrun xcodebuild lipo; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

caller_dir=$(pwd)
script_dir=$(cd "$(dirname "$0")" && pwd)
zig_dir=$(cd "$script_dir/.." && pwd)
repo_dir=$(cd "$zig_dir/.." && pwd)

if [[ -n $artifacts_argument ]]; then
    case "$artifacts_argument" in
        /*) artifacts_dir=$artifacts_argument ;;
        *) artifacts_dir="$caller_dir/$artifacts_argument" ;;
    esac
else
    artifacts_dir="$repo_dir/.build/artifacts"
fi
[[ -d "$artifacts_dir" ]] || fail "missing SwiftPM artifacts directory: $artifacts_dir"
artifacts_dir=$(cd "$artifacts_dir" && pwd -P)

case "$output_argument" in
    /*) output_path=$output_argument ;;
    *) output_path="$caller_dir/$output_argument" ;;
esac
output_parent=$(dirname "$output_path")
mkdir -p "$output_parent"
output_parent=$(cd "$output_parent" && pwd)
output_path="$output_parent/$(basename "$output_path")"
[[ "$output_path" != / ]] || fail "refusing to replace root directory"
[[ "$(basename "$output_path")" == *.xcframework ]] ||
    fail "output must have an .xcframework extension: $output_path"
if [[ $full_build -eq 0 && ! -d "$output_path" ]]; then
    echo "missing XCFramework to update, falling back to --full build: $output_path"
    full_build=1
fi

find_xcframework() {
    local package=$1
    local product=$2
    local package_dir="$artifacts_dir/$package"
    local result

    [[ -d "$package_dir" ]] || fail "missing SwiftPM artifact: $package_dir"
    result=$(find "$package_dir" -type d -name "$product.xcframework" -print -quit)
    [[ -n "$result" ]] || fail "unable to find $product.xcframework under $package_dir"
    cd "$(dirname "$result")"
    printf '%s/%s\n' "$(pwd)" "$(basename "$result")"
}

framework_search_path() {
    local xcframework=$1
    local identifier=$2
    local product=$3
    local header=$4
    local framework="$xcframework/$identifier/$product.framework"
    local headers

    if [[ -d "$framework/Headers" ]]; then
        headers="$framework/Headers"
    elif [[ -d "$framework/Versions/A/Headers" ]]; then
        headers="$framework/Versions/A/Headers"
    else
        fail "missing headers for $product slice $identifier"
    fi
    [[ -f "$headers/$header" ]] ||
        fail "$product artifact slice $identifier must contain Headers/$header"
    cd "$xcframework/$identifier"
    pwd -P
}

openssl_xcframework=$(find_xcframework openssl-apple openssl)
wg_go_xcframework=$(find_xcframework wg-go-apple wg-go)

work_dir="$zig_dir/zig-out/xcframework-build"
cache_dir="$zig_dir/zig-out/xcframework-cache"
global_cache_dir="$zig_dir/zig-out/xcframework-global-cache"
if [[ $full_build -eq 1 ]]; then
    echo "Removing cached XCFramework build"
    rm -rf "$work_dir" "$cache_dir" "$global_cache_dir"
fi
mkdir -p "$work_dir" "$cache_dir" "$global_cache_dir"
chmod 755 "$work_dir" "$cache_dir" "$global_cache_dir"

macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
ios_simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
tvos_sdk=$(xcrun --sdk appletvos --show-sdk-path)
tvos_simulator_sdk=$(xcrun --sdk appletvsimulator --show-sdk-path)

build_slice() {
    local name=$1
    local target=$2
    local sdk=$3
    local openssl_identifier=$4
    local wg_go_identifier=$5
    local install_root="$work_dir/install/$name"
    local openssl_include
    local wg_go_include

    openssl_include=$(framework_search_path "$openssl_xcframework" "$openssl_identifier" openssl rand.h)
    wg_go_include=$(framework_search_path "$wg_go_xcframework" "$wg_go_identifier" wg_go wg_go.h)
    mkdir -p "$install_root"
    chmod 755 "$work_dir/install" "$install_root"

    echo "Building $name ($target)"
    (
        cd "$zig_dir"
        zig build \
            -j1 \
            --prefix "$install_root" \
            --cache-dir "$cache_dir" \
            --global-cache-dir "$global_cache_dir" \
            --release=small \
            -Dtarget="$target" \
            -Dapple-sdk-path="$sdk" \
            -Dopenssl-include="$openssl_include" \
            -Dopenvpn=true \
            -Dwireguard=true \
            -Dwg-go-include="$wg_go_include"
    )
}

configure_slice() {
    local platform=$1
    local arch=$2
    local zig_arch=x86_64

    [[ $arch == arm64 ]] && zig_arch=aarch64
    slice_name="$platform-$arch"
    case "$platform:$arch" in
        macos:*)
            slice_target="$zig_arch-macos.$macos_min"
            slice_sdk=$macos_sdk
            slice_openssl=macos-arm64_x86_64
            slice_wg_go=macos-arm64_x86_64
            slice_identifier=macos-arm64_x86_64
            ;;
        ios:arm64)
            slice_target="aarch64-ios.$ios_min"
            slice_sdk=$ios_sdk
            slice_openssl=ios-arm64_arm64e
            slice_wg_go=ios-arm64
            slice_identifier=ios-arm64
            ;;
        ios-simulator:*)
            slice_target="$zig_arch-ios.$ios_min-simulator"
            slice_sdk=$ios_simulator_sdk
            slice_openssl=ios-arm64_x86_64-simulator
            slice_wg_go=ios-arm64-simulator
            slice_identifier=ios-arm64_x86_64-simulator
            ;;
        tvos:arm64)
            slice_target="aarch64-tvos.$tvos_min"
            slice_sdk=$tvos_sdk
            slice_openssl=tvos-arm64
            slice_wg_go=tvos-arm64
            slice_identifier=tvos-arm64
            ;;
        tvos-simulator:*)
            slice_target="$zig_arch-tvos.$tvos_min-simulator"
            slice_sdk=$tvos_simulator_sdk
            slice_openssl=tvos-arm64_x86_64-simulator
            slice_wg_go=tvos-arm64-simulator
            slice_identifier=tvos-arm64_x86_64-simulator
            ;;
        *) fail "$platform does not support architecture $arch" ;;
    esac
}

build_configured_slice() {
    configure_slice "$1" "$2"
    build_slice "$slice_name" "$slice_target" "$slice_sdk" "$slice_openssl" "$slice_wg_go"
}

if [[ $full_build -eq 1 ]]; then
    slices=(
        macos:arm64 macos:x86_64
        ios:arm64 ios-simulator:arm64 ios-simulator:x86_64
        tvos:arm64 tvos-simulator:arm64 tvos-simulator:x86_64
    )
    for slice in "${slices[@]}"; do
        build_configured_slice "${slice%:*}" "${slice#*:}"
    done
else
    build_configured_slice "$active_platform" "$active_arch"
fi

rm -rf "$work_dir/universal" "$work_dir/frameworks" "$work_dir/$framework_name.xcframework"
mkdir -p "$work_dir/universal"
if [[ $full_build -eq 1 ]]; then
    for platform in macos ios-simulator tvos-simulator; do
        lipo -create \
            "$work_dir/install/$platform-arm64/lib/libpartout.a" \
            "$work_dir/install/$platform-x86_64/lib/libpartout.a" \
            -output "$work_dir/universal/$platform.a"
    done
fi

write_info_plist() {
    local path=$1
    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$framework_name</string>
  <key>CFBundleIdentifier</key>
  <string>io.partout.$framework_name</string>
  <key>CFBundleName</key>
  <string>$framework_name</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
PLIST
}

make_framework() {
    local platform=$1
    local binary=$2
    local framework="$work_dir/frameworks/$platform/$framework_name.framework"
    local content=$framework
    local plist="$framework/Info.plist"

    if [[ $platform == macos ]]; then
        content="$framework/Versions/A"
        plist="$content/Resources/Info.plist"
        mkdir -p "$content/Resources"
    fi
    mkdir -p "$content/Headers" "$content/Modules"
    cp "$binary" "$content/$framework_name"
    cp "$zig_dir/src/partout.h" "$content/Headers/partout.h"
    cp "$zig_dir/src/module.modulemap" "$content/Modules/module.modulemap"
    write_info_plist "$plist"
    if [[ $platform == macos ]]; then
        ln -s A "$framework/Versions/Current"
        ln -s "Versions/Current/$framework_name" "$framework/$framework_name"
        for directory in Headers Modules Resources; do
            ln -s "Versions/Current/$directory" "$framework/$directory"
        done
    fi
    printf '%s\n' "$framework"
}

framework_binary() {
    local framework=$1
    local platform=$2

    if [[ $platform == macos ]]; then
        printf '%s/Versions/A/%s\n' "$framework" "$framework_name"
    else
        printf '%s/%s\n' "$framework" "$framework_name"
    fi
}

generated_output="$work_dir/$framework_name.xcframework"
if [[ $full_build -eq 1 ]]; then
    xcframework_arguments=()
    for platform in macos ios ios-simulator tvos tvos-simulator; do
        case "$platform" in
            ios|tvos) binary="$work_dir/install/$platform-arm64/lib/libpartout.a" ;;
            *) binary="$work_dir/universal/$platform.a" ;;
        esac
        framework=$(make_framework "$platform" "$binary")
        xcframework_arguments+=(-framework "$framework")
    done
    xcodebuild -create-xcframework \
        "${xcframework_arguments[@]}" \
        -output "$generated_output"
else
    active_binary="$work_dir/install/$slice_name/lib/libpartout.a"

    # Preserve every other XCFramework slice and replace only the active
    # architecture in the matching platform variant.
    cp -R "$output_path" "$generated_output"
    existing_framework="$generated_output/$slice_identifier/$framework_name.framework"
    existing_binary=$(framework_binary "$existing_framework" "$active_platform")
    [[ -f $existing_binary ]] ||
        fail "missing $active_platform $active_arch slice in $output_path (rebuild it with --full)"
    existing_archs=$(lipo -archs "$existing_binary")
    [[ " $existing_archs " == *" $active_arch "* ]] ||
        fail "missing $active_platform $active_arch slice in $output_path (rebuild it with --full)"
    if [[ $existing_archs == "$active_arch" ]]; then
        cp "$active_binary" "$existing_binary"
    else
        replacement_binary="$work_dir/replacement-$active_platform-$active_arch.a"
        lipo "$existing_binary" -replace "$active_arch" "$active_binary" -output "$replacement_binary"
        mv "$replacement_binary" "$existing_binary"
    fi
    cp "$zig_dir/src/partout.h" "$existing_framework/Headers/partout.h"
    cp "$zig_dir/src/module.modulemap" "$existing_framework/Modules/module.modulemap"
fi

if [[ $full_build -eq 0 ]] && diff -qr --no-dereference "$output_path" "$generated_output" >/dev/null; then
    rm -rf "$generated_output"
    echo "Unchanged $output_path"
else
    rm -rf "$output_path"
    mv "$generated_output" "$output_path"
    echo "Generated $output_path"
fi
