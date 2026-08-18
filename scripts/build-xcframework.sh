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

usage() {
    cat <<EOF
usage: $0 [output.xcframework] [artifacts-directory] [--full] [--legacy]

Build PartoutNative.xcframework against the latest vendor prebuilts. With no
arguments, the output is PartoutNative.xcframework at the repository root and
the prebuilts cache is prebuilts at the repository root.

options:
  --full      build every supported platform and architecture
  --legacy    build a static library that requires external vendor libraries
  --monolith  build the default dynamic monolith (kept for compatibility)
  -h, --help  show this help
EOF
}

caller_dir=$(pwd)
script_dir=$(cd "$(dirname "$0")" && pwd)
zig_dir=$(cd "$script_dir/.." && pwd)
repo_dir=$zig_dir

output_argument=
artifacts_argument=
full_build=0
build_mode=monolith
build_mode_option=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            [[ $full_build -eq 0 ]] || fail "duplicate option: --full"
            full_build=1
            ;;
        --monolith)
            [[ -z $build_mode_option ]] || fail "duplicate build mode: $1"
            build_mode=monolith
            build_mode_option=$1
            ;;
        --legacy)
            [[ -z $build_mode_option ]] || fail "duplicate build mode: $1"
            build_mode=legacy
            build_mode_option=$1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*) fail "unknown option: $1" ;;
        *)
            if [[ -z $output_argument ]]; then
                output_argument=$1
            elif [[ -z $artifacts_argument ]]; then
                artifacts_argument=$1
            else
                fail "unexpected argument: $1"
            fi
            ;;
    esac
    shift
done

if [[ -z $output_argument ]]; then
    output_argument="$repo_dir/$framework_name.xcframework"
fi

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

framework_binary() {
    local framework=$1
    local platform=$2

    if [[ $platform == macos ]]; then
        printf '%s/Versions/A/%s\n' "$framework" "$framework_name"
    else
        printf '%s/%s\n' "$framework" "$framework_name"
    fi
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
if [[ $build_mode == monolith ]]; then
    echo "Building a dynamic monolith with statically linked vendors"
    library_name=libpartout.dylib
    library_extension=dylib
else
    echo "Building a static library with external vendor implementations"
    library_name=libpartout.a
    library_extension=a
fi

for tool in curl ditto lipo plutil swift xcodebuild xcrun zig; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

if [[ -n $artifacts_argument ]]; then
    case "$artifacts_argument" in
        /*) artifacts_dir=$artifacts_argument ;;
        *) artifacts_dir="$caller_dir/$artifacts_argument" ;;
    esac
else
    artifacts_dir="$repo_dir/prebuilts"
fi
mkdir -p "$artifacts_dir"
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

version_file="$repo_dir/src/version.zig"
[[ -f $version_file ]] || fail "missing library version file: $version_file"
library_version=$(sed -nE \
    's/^pub const number = "([0-9A-Za-z.+-]+)";$/\1/p' \
    "$version_file")
[[ -n $library_version && $library_version != *$'\n'* ]] ||
    fail "unable to determine library version from $version_file"

identifier_matches_platform() {
    local identifier=$1

    case "$active_platform:$identifier" in
        macos:macos-*) return 0 ;;
        ios:ios-*-simulator) return 1 ;;
        ios:ios-*) return 0 ;;
        ios-simulator:ios-*-simulator) return 0 ;;
        tvos:tvos-*-simulator) return 1 ;;
        tvos:tvos-*) return 0 ;;
        tvos-simulator:tvos-*-simulator) return 0 ;;
        *) return 1 ;;
    esac
}

find_active_slice_identifier() {
    local slice
    local identifier
    local framework
    local binary
    local existing_archs

    [[ -d "$output_path" && -f "$output_path/Info.plist" ]] || return 1
    plutil -lint "$output_path/Info.plist" >/dev/null 2>&1 || return 1
    for slice in "$output_path"/*; do
        [[ -d "$slice" ]] || continue
        identifier=${slice##*/}
        identifier_matches_platform "$identifier" || continue
        framework="$slice/$framework_name.framework"
        binary=$(framework_binary "$framework" "$active_platform")
        [[ -f "$binary" ]] || continue
        existing_archs=$(lipo -archs "$binary" 2>/dev/null) || continue
        if [[ " $existing_archs " == *" $active_arch "* ]]; then
            printf '%s\n' "$identifier"
            return 0
        fi
    done
    return 1
}

output_has_framework_slices() {
    local framework

    [[ -d "$output_path" ]] || return 1
    for framework in "$output_path"/*/"$framework_name.framework"; do
        [[ -d "$framework" ]] && return 0
    done
    return 1
}

create_active_output=0
active_output_identifier=
if [[ $full_build -eq 0 ]]; then
    if active_output_identifier=$(find_active_slice_identifier); then
        :
    elif output_has_framework_slices; then
        fail "missing $active_platform $active_arch slice in $output_path (rebuild it with --full)"
    else
        echo "No existing XCFramework slices; creating $active_platform $active_arch only"
        create_active_output=1
    fi
fi

download_prebuilts() {
    local repository_url=https://github.com/partout-io/prebuilts
    local latest_url="$repository_url/releases/latest"
    local resolved_url
    local prebuilts_tag
    local download_url
    local vendor
    local archive
    local release_checksum
    local expected_checksum
    local archive_path
    local actual_checksum
    local framework
    local checksum_marker
    local extracted_checksum
    local extract_dir

    resolved_url=$(curl -fsSLI --retry 3 \
        --output /dev/null \
        --write-out '%{url_effective}' \
        "$latest_url")
    prebuilts_tag=${resolved_url##*/}
    prebuilts_tag=${prebuilts_tag%%\?*}
    [[ $resolved_url == */releases/tag/* && \
        $prebuilts_tag =~ ^[0-9A-Za-z._+-]+$ ]] ||
        fail "unable to resolve the latest prebuilts release: $resolved_url"

    echo "Using prebuilts release $prebuilts_tag"
    download_url="$repository_url/releases/download/$prebuilts_tag"
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/partout-prebuilts.XXXXXX")
    trap 'rm -rf "$temp_dir"' EXIT

    for vendor in openssl mbedtls wg-go; do
        archive="$vendor.xcframework.zip"
        release_checksum="$archive.checksum"
        curl -fsSL --retry 3 \
            --output "$temp_dir/$release_checksum" \
            "$download_url/$release_checksum"
        expected_checksum=$(tr -d '\r\n' < "$temp_dir/$release_checksum")
        [[ $expected_checksum =~ ^[0-9a-f]{64}$ ]] ||
            fail "invalid checksum in $release_checksum"

        archive_path="$artifacts_dir/$archive"
        actual_checksum=
        if [[ -f $archive_path ]]; then
            actual_checksum=$(swift package compute-checksum "$archive_path")
        fi

        if [[ $actual_checksum == "$expected_checksum" ]]; then
            echo "Using cached $archive"
        else
            echo "Downloading $archive"
            curl -fsSL --retry 3 \
                --output "$temp_dir/$archive" \
                "$download_url/$archive"
            actual_checksum=$(swift package compute-checksum "$temp_dir/$archive")
            [[ $actual_checksum == "$expected_checksum" ]] ||
                fail "checksum mismatch for $archive"
            mv "$temp_dir/$archive" "$archive_path"
        fi
        mv "$temp_dir/$release_checksum" "$artifacts_dir/$release_checksum"

        framework="$artifacts_dir/$vendor.xcframework"
        checksum_marker="$artifacts_dir/.$vendor.xcframework.checksum"
        extracted_checksum=
        if [[ -f $checksum_marker ]]; then
            extracted_checksum=$(tr -d '\r\n' < "$checksum_marker")
        fi

        if [[ -d $framework && $extracted_checksum == "$expected_checksum" ]]; then
            echo "Using extracted $vendor.xcframework"
            continue
        fi

        echo "Extracting $archive"
        extract_dir="$temp_dir/$vendor"
        mkdir -p "$extract_dir"
        ditto -x -k "$archive_path" "$extract_dir"
        [[ -d "$extract_dir/$vendor.xcframework" ]] ||
            fail "missing $vendor.xcframework in $archive"
        rm -rf "$framework"
        mv "$extract_dir/$vendor.xcframework" "$framework"
        printf '%s\n' "$expected_checksum" > "$checksum_marker"
    done

    printf '%s\n' "$prebuilts_tag" > "$artifacts_dir/prebuilts-version.txt"
    rm -rf "$temp_dir"
    trap - EXIT
}

download_prebuilts

find_xcframework() {
    local package=$1
    local result

    result=$(find "$artifacts_dir" -type d -name "$package.xcframework" -print -quit)
    [[ -n "$result" ]] || fail "unable to find $package.xcframework under $artifacts_dir"
    cd "$(dirname "$result")"
    printf '%s/%s\n' "$(pwd)" "$(basename "$result")"
}

resolve_xcframework_paths() {
    local xcframework=$1
    local identifier=$2
    local product=$3
    local framework_header=$4
    local library_header=$5
    local library_name=$6
    local slice="$xcframework/$identifier"
    local framework="$xcframework/$identifier/$product.framework"
    local headers
    local header

    if [[ -d "$framework/Headers" ]]; then
        headers="$framework/Headers"
        header=$framework_header
        xcframework_include_path=$slice
        xcframework_library_path=$slice
    elif [[ -d "$framework/Versions/A/Headers" ]]; then
        headers="$framework/Versions/A/Headers"
        header=$framework_header
        xcframework_include_path=$slice
        xcframework_library_path=$slice
    elif [[ -d "$slice/Headers" ]]; then
        headers="$slice/Headers"
        header=$library_header
        [[ -f "$slice/$library_name" ]] ||
            fail "$product artifact slice $identifier must contain $library_name"
        xcframework_include_path=$(cd "$headers" && pwd -P)
        xcframework_library_path=$(cd "$slice" && pwd -P)
    else
        fail "missing headers for $product slice $identifier"
    fi
    [[ -f "$headers/$header" ]] ||
        fail "$product artifact slice $identifier must contain Headers/$header"
}

openssl_xcframework=$(find_xcframework openssl)
mbedtls_xcframework=$(find_xcframework mbedtls)
wg_go_xcframework=$(find_xcframework wg-go)

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

link_monolith() {
    local install_root=$1
    local clang_target=$2
    local sdk=$3
    local openssl_lib=$4
    local mbedtls_lib=$5
    local wg_go_lib=$6
    local static_library="$install_root/lib/libpartout.a"
    local dynamic_library="$install_root/lib/libpartout.dylib"

    [[ -f "$static_library" ]] || fail "missing static Partout library: $static_library"
    xcrun clang \
        -target "$clang_target" \
        -isysroot "$sdk" \
        -dynamiclib \
        -Wl,-install_name,"@rpath/$framework_name.framework/$framework_name" \
        -Wl,-compatibility_version,1.0.0 \
        -Wl,-current_version,1.0.0 \
        -Wl,-dead_strip \
        -Wl,-rpath,@loader_path \
        -Wl,-exported_symbols_list,"$zig_dir/src/partout.exports" \
        -Wl,-force_load,"$static_library" \
        "$openssl_lib/libopenssl.a" \
        "$mbedtls_lib/libmbedtls.a" \
        "$wg_go_lib/libwg-go.a" \
        -framework CoreFoundation \
        -framework Security \
        -o "$dynamic_library"
}

build_slice() {
    local name=$1
    local target=$2
    local clang_target=$3
    local sdk=$4
    local openssl_identifier=$5
    local mbedtls_identifier=$6
    local wg_go_identifier=$7
    local install_root="$work_dir/install/$name"
    local openssl_include
    local openssl_lib
    local mbedtls_include
    local mbedtls_lib
    local wg_go_include
    local wg_go_lib

    resolve_xcframework_paths \
        "$openssl_xcframework" "$openssl_identifier" openssl \
        rand.h openssl/rand.h libopenssl.a
    openssl_include=$xcframework_include_path
    openssl_lib=$xcframework_library_path
    resolve_xcframework_paths \
        "$mbedtls_xcframework" "$mbedtls_identifier" mbedtls \
        mbedtls/ssl.h mbedtls/ssl.h libmbedtls.a
    mbedtls_include=$xcframework_include_path
    mbedtls_lib=$xcframework_library_path
    resolve_xcframework_paths \
        "$wg_go_xcframework" "$wg_go_identifier" wg_go \
        wg_go.h wg_go/wg_go.h libwg-go.a
    wg_go_include=$xcframework_include_path
    wg_go_lib=$xcframework_library_path
    rm -rf "$install_root"
    mkdir -p "$install_root"
    chmod 755 "$work_dir/install" "$install_root"

    local build_options=(
        -Dtarget="$target"
        -Dapple-sdk-path="$sdk"
        -Dopenvpn=true
        -Dwireguard=true
        -Dopenssl-include="$openssl_include"
        -Dopenssl-lib="$openssl_lib"
        -Dmbedtls-include="$mbedtls_include"
        -Dmbedtls-lib="$mbedtls_lib"
        -Dwg-go-include="$wg_go_include"
        -Dwg-go-lib="$wg_go_lib"
    )
    if [[ $build_mode == legacy ]]; then
        build_options+=(-Dlegacy-build=true)
    fi

    echo "Building $name ($target)"
    (
        cd "$zig_dir"
        zig build install \
            -j1 \
            --prefix "$install_root" \
            --cache-dir "$cache_dir" \
            --global-cache-dir "$global_cache_dir" \
            --release=small \
            "${build_options[@]}"
    )
    if [[ $build_mode == monolith ]]; then
        link_monolith \
            "$install_root" "$clang_target" "$sdk" \
            "$openssl_lib" "$mbedtls_lib" "$wg_go_lib"
    fi
}

configure_slice() {
    local platform=$1
    local arch=$2
    local zig_arch=x86_64

    [[ $arch == arm64 ]] && zig_arch=aarch64
    local clang_arch=$arch
    slice_name="$platform-$arch"
    case "$platform:$arch" in
        macos:*)
            slice_target="$zig_arch-macos.$macos_min"
            slice_clang_target="$clang_arch-apple-macos$macos_min"
            slice_sdk=$macos_sdk
            slice_openssl=macos-arm64_x86_64
            slice_mbedtls=macos-arm64_x86_64
            slice_wg_go=macos-arm64_x86_64
            ;;
        ios:arm64)
            slice_target="aarch64-ios.$ios_min"
            slice_clang_target="arm64-apple-ios$ios_min"
            slice_sdk=$ios_sdk
            slice_openssl=ios-arm64
            slice_mbedtls=ios-arm64
            slice_wg_go=ios-arm64
            ;;
        ios-simulator:*)
            slice_target="$zig_arch-ios.$ios_min-simulator"
            slice_clang_target="$clang_arch-apple-ios$ios_min-simulator"
            slice_sdk=$ios_simulator_sdk
            slice_openssl=ios-arm64_x86_64-simulator
            slice_mbedtls=ios-arm64_x86_64-simulator
            slice_wg_go=ios-arm64_x86_64-simulator
            ;;
        tvos:arm64)
            slice_target="aarch64-tvos.$tvos_min"
            slice_clang_target="arm64-apple-tvos$tvos_min"
            slice_sdk=$tvos_sdk
            slice_openssl=tvos-arm64
            slice_mbedtls=tvos-arm64
            slice_wg_go=tvos-arm64
            ;;
        tvos-simulator:*)
            slice_target="$zig_arch-tvos.$tvos_min-simulator"
            slice_clang_target="$clang_arch-apple-tvos$tvos_min-simulator"
            slice_sdk=$tvos_simulator_sdk
            slice_openssl=tvos-arm64_x86_64-simulator
            slice_mbedtls=tvos-arm64_x86_64-simulator
            slice_wg_go=tvos-arm64_x86_64-simulator
            ;;
        *) fail "$platform does not support architecture $arch" ;;
    esac
}

build_configured_slice() {
    configure_slice "$1" "$2"
    build_slice \
        "$slice_name" "$slice_target" "$slice_clang_target" "$slice_sdk" \
        "$slice_openssl" "$slice_mbedtls" "$slice_wg_go"
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
            "$work_dir/install/$platform-arm64/lib/$library_name" \
            "$work_dir/install/$platform-x86_64/lib/$library_name" \
            -output "$work_dir/universal/$platform.$library_extension"
    done
fi

write_info_plist() {
    local path=$1
    local platform=$2
    local minimum_os_key
    local minimum_os_version

    case "$platform" in
        macos)
            minimum_os_key=LSMinimumSystemVersion
            minimum_os_version=$macos_min
            ;;
        ios|ios-simulator)
            minimum_os_key=MinimumOSVersion
            minimum_os_version=$ios_min
            ;;
        tvos|tvos-simulator)
            minimum_os_key=MinimumOSVersion
            minimum_os_version=$tvos_min
            ;;
        *) fail "unsupported framework platform: $platform" ;;
    esac

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
  <string>$library_version</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>$minimum_os_key</key>
  <string>$minimum_os_version</string>
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
    write_info_plist "$plist" "$platform"
    if [[ $platform == macos ]]; then
        ln -s A "$framework/Versions/Current"
        ln -s "Versions/Current/$framework_name" "$framework/$framework_name"
        for directory in Headers Modules Resources; do
            ln -s "Versions/Current/$directory" "$framework/$directory"
        done
    fi
    printf '%s\n' "$framework"
}

generated_output="$work_dir/$framework_name.xcframework"
if [[ $full_build -eq 1 ]]; then
    xcframework_arguments=()
    for platform in macos ios ios-simulator tvos tvos-simulator; do
        case "$platform" in
            ios|tvos) binary="$work_dir/install/$platform-arm64/lib/$library_name" ;;
            *) binary="$work_dir/universal/$platform.$library_extension" ;;
        esac
        framework=$(make_framework "$platform" "$binary")
        xcframework_arguments+=(-framework "$framework")
    done
    xcodebuild -create-xcframework \
        "${xcframework_arguments[@]}" \
        -output "$generated_output"
elif [[ $create_active_output -eq 1 ]]; then
    active_binary="$work_dir/install/$slice_name/lib/$library_name"
    framework=$(make_framework "$active_platform" "$active_binary")
    xcodebuild -create-xcframework \
        -framework "$framework" \
        -output "$generated_output"
else
    active_binary="$work_dir/install/$slice_name/lib/$library_name"

    # Preserve every other XCFramework slice and replace only the active
    # architecture in the matching platform variant.
    cp -R "$output_path" "$generated_output"
    existing_framework="$generated_output/$active_output_identifier/$framework_name.framework"
    existing_binary=$(framework_binary "$existing_framework" "$active_platform")
    [[ -f $existing_binary ]] ||
        fail "missing $active_platform $active_arch slice in $output_path (rebuild it with --full)"
    existing_archs=$(lipo -archs "$existing_binary")
    [[ " $existing_archs " == *" $active_arch "* ]] ||
        fail "missing $active_platform $active_arch slice in $output_path (rebuild it with --full)"
    if [[ $existing_archs == "$active_arch" ]]; then
        cp "$active_binary" "$existing_binary"
    else
        replacement_binary="$work_dir/replacement-$active_platform-$active_arch.$library_extension"
        lipo "$existing_binary" -replace "$active_arch" "$active_binary" -output "$replacement_binary"
        mv "$replacement_binary" "$existing_binary"
    fi
    cp "$zig_dir/src/partout.h" "$existing_framework/Headers/partout.h"
    cp "$zig_dir/src/module.modulemap" "$existing_framework/Modules/module.modulemap"
    if [[ $active_platform == macos ]]; then
        existing_plist="$existing_framework/Versions/A/Resources/Info.plist"
    else
        existing_plist="$existing_framework/Info.plist"
    fi
    write_info_plist "$existing_plist" "$active_platform"
fi

if [[ $full_build -eq 0 && -d "$output_path" ]] &&
    diff -qr --no-dereference "$output_path" "$generated_output" >/dev/null; then
    rm -rf "$generated_output"
    echo "Unchanged $output_path"
else
    rm -rf "$output_path"
    mv "$generated_output" "$output_path"
    echo "Generated $output_path"
fi
