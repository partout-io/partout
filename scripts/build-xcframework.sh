#!/bin/bash

set -euo pipefail

# Xcode exports these, but command-line Swift tools reject them.
unset SWIFT_DEBUG_INFORMATION_FORMAT SWIFT_DEBUG_INFORMATION_VERSION

name=PartoutNative
ios_min=16.0
macos_min=13.0
tvos_min=17.0

fail() {
    echo "build-xcframework.sh: $*" >&2
    exit 1
}

repo_dir=$(cd "$(dirname "$0")/.." && pwd -P)
output=${1:-"$repo_dir/$name.xcframework"}
prebuilts=${2:-"$repo_dir/prebuilts"}
mode=${3:-}

[[ $# -le 3 ]] || fail "usage: $0 [output.xcframework] [prebuilts-directory] [--full]"
[[ -z $mode || $mode == --full ]] || fail "unknown option: $mode"
[[ $output == *.xcframework ]] || fail "output must have an .xcframework extension"

for tool in curl ditto lipo swift xcodebuild xcrun zig; do
    command -v "$tool" >/dev/null || fail "missing required tool: $tool"
done

mkdir -p "$prebuilts" "$(dirname "$output")"
prebuilts=$(cd "$prebuilts" && pwd -P)
output=$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")
version=$(sed -nE 's/^pub const number = "([0-9A-Za-z.+-]+)";$/\1/p' "$repo_dir/src/version.zig")
[[ -n $version ]] || fail "unable to read the library version"

download_prebuilts() {
    local repository=https://github.com/partout-io/prebuilts
    local resolved tag base temp vendor archive checksum expected actual

    resolved=$(curl -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' "$repository/releases/latest")
    tag=${resolved##*/}
    tag=${tag%%\?*}
    [[ $resolved == */releases/tag/* ]] || fail "unable to resolve the latest prebuilts release"
    base="$repository/releases/download/$tag"
    temp=$(mktemp -d "${TMPDIR:-/tmp}/partout-prebuilts.XXXXXX")
    trap 'rm -rf "$temp"' EXIT

    echo "Using prebuilts $tag"
    for vendor in openssl mbedtls wg-go; do
        archive="$vendor.xcframework.zip"
        checksum="$archive.checksum"
        curl -fsSL --retry 3 -o "$temp/$checksum" "$base/$checksum"
        expected=$(tr -d '\r\n' < "$temp/$checksum")
        [[ $expected =~ ^[0-9a-f]{64}$ ]] || fail "invalid checksum for $archive"

        actual=
        [[ ! -f "$prebuilts/$archive" ]] ||
            actual=$(swift package compute-checksum "$prebuilts/$archive")
        if [[ $actual != "$expected" ]]; then
            echo "Downloading $archive"
            curl -fsSL --retry 3 -o "$temp/$archive" "$base/$archive"
            actual=$(swift package compute-checksum "$temp/$archive")
            [[ $actual == "$expected" ]] || fail "checksum mismatch for $archive"
            mv "$temp/$archive" "$prebuilts/$archive"
        fi

        rm -rf "$prebuilts/$vendor.xcframework"
        ditto -x -k "$prebuilts/$archive" "$prebuilts"
        [[ -d "$prebuilts/$vendor.xcframework" ]] || fail "missing $vendor.xcframework"
        mv "$temp/$checksum" "$prebuilts/$checksum"
    done

    echo "$tag" > "$prebuilts/prebuilts-version.txt"
    rm -rf "$temp"
    trap - EXIT
}

download_prebuilts

work="$repo_dir/zig-out/xcframework-build"
cache="$repo_dir/zig-out/xcframework-cache"
global_cache="$repo_dir/zig-out/xcframework-global-cache"
rm -rf "$work"
mkdir -p "$work/install" "$work/frameworks" "$work/universal" "$work/dsyms" "$cache" "$global_cache"
chmod 755 "$work" "$work/install" "$cache" "$global_cache"

build_slice() {
    local platform=$1 arch=$2 zig_arch target clang_target sdk_name vendor_id
    local sdk install openssl mbedtls wg_go library

    [[ $arch == arm64 ]] && zig_arch=aarch64 || zig_arch=x86_64
    case "$platform:$arch" in
        macos:*)
            target="$zig_arch-macos.$macos_min"
            clang_target="$arch-apple-macos$macos_min"
            sdk_name=macosx
            vendor_id=macos-arm64_x86_64
            ;;
        ios:arm64)
            target="aarch64-ios.$ios_min"
            clang_target="arm64-apple-ios$ios_min"
            sdk_name=iphoneos
            vendor_id=ios-arm64
            ;;
        ios-simulator:*)
            target="$zig_arch-ios.$ios_min-simulator"
            clang_target="$arch-apple-ios$ios_min-simulator"
            sdk_name=iphonesimulator
            vendor_id=ios-arm64_x86_64-simulator
            ;;
        tvos:arm64)
            target="aarch64-tvos.$tvos_min"
            clang_target="arm64-apple-tvos$tvos_min"
            sdk_name=appletvos
            vendor_id=tvos-arm64
            ;;
        tvos-simulator:*)
            target="$zig_arch-tvos.$tvos_min-simulator"
            clang_target="$arch-apple-tvos$tvos_min-simulator"
            sdk_name=appletvsimulator
            vendor_id=tvos-arm64_x86_64-simulator
            ;;
        *) fail "unsupported slice: $platform $arch" ;;
    esac

    sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
    install="$work/install/$platform-$arch"
    openssl="$prebuilts/openssl.xcframework/$vendor_id"
    mbedtls="$prebuilts/mbedtls.xcframework/$vendor_id"
    wg_go="$prebuilts/wg-go.xcframework/$vendor_id"
    for library in "$openssl/libopenssl.a" "$mbedtls/libmbedtls.a" "$wg_go/libwg-go.a"; do
        [[ -f $library ]] || fail "missing vendor library: $library"
    done

    echo "Building $platform $arch"
    (
        cd "$repo_dir"
        zig build install -j1 \
            --prefix "$install" \
            --cache-dir "$cache" \
            --global-cache-dir "$global_cache" \
            --release=small \
            -Dstrip=false \
            -Dtarget="$target" \
            -Dapple-sdk-path="$sdk" \
            -Dopenvpn=true \
            -Dwireguard=true \
            -Dopenssl-include="$openssl/Headers" \
            -Dopenssl-lib="$openssl" \
            -Dmbedtls-include="$mbedtls/Headers" \
            -Dmbedtls-lib="$mbedtls" \
            -Dwg-go-include="$wg_go/Headers" \
            -Dwg-go-lib="$wg_go"
    )

    xcrun clang \
        -target "$clang_target" \
        -isysroot "$sdk" \
        -dynamiclib \
        -Wl,-install_name,"@rpath/$name.framework/$name" \
        -Wl,-compatibility_version,1.0.0 \
        -Wl,-current_version,1.0.0 \
        -Wl,-dead_strip \
        -Wl,-rpath,@loader_path \
        -Wl,-exported_symbols_list,"$repo_dir/src/partout.exports" \
        -Wl,-force_load,"$install/lib/libpartout.a" \
        "$openssl/libopenssl.a" \
        "$mbedtls/libmbedtls.a" \
        "$wg_go/libwg-go.a" \
        -framework CoreFoundation \
        -framework Security \
        -o "$install/lib/libpartout.dylib"
}

active_slice() {
    local platform=${PLATFORM_NAME:-${SDK_NAME:-macos}}
    local arch=${CURRENT_ARCH:-}

    case "$arch" in
        arm64|aarch64|x86_64) ;;
        *) arch=${NATIVE_ARCH_ACTUAL:-$(uname -m)} ;;
    esac

    case "$platform" in
        macos|macosx*) platform=macos ;;
        ios|iphoneos*) platform=ios ;;
        ios-simulator|iphonesimulator*) platform=ios-simulator ;;
        tvos|appletvos*) platform=tvos ;;
        tvos-simulator|appletvsimulator*) platform=tvos-simulator ;;
        *) fail "unsupported platform: $platform" ;;
    esac
    case "$arch" in
        arm64|aarch64) arch=arm64 ;;
        x86_64) ;;
        *) fail "unsupported architecture: $arch" ;;
    esac
    echo "$platform:$arch"
}

if [[ $mode == --full ]]; then
    slices=(
        macos:arm64 macos:x86_64
        ios:arm64 ios-simulator:arm64 ios-simulator:x86_64
        tvos:arm64 tvos-simulator:arm64 tvos-simulator:x86_64
    )
else
    slices=("$(active_slice)")
fi

for slice in "${slices[@]}"; do
    build_slice "${slice%:*}" "${slice#*:}"
done

if [[ $mode == --full ]]; then
    for platform in macos ios-simulator tvos-simulator; do
        lipo -create \
            "$work/install/$platform-arm64/lib/libpartout.dylib" \
            "$work/install/$platform-x86_64/lib/libpartout.dylib" \
            -output "$work/universal/$platform.dylib"
    done
fi

write_plist() {
    local path=$1 platform=$2 key minimum
    case "$platform" in
        macos) key=LSMinimumSystemVersion; minimum=$macos_min ;;
        ios|ios-simulator) key=MinimumOSVersion; minimum=$ios_min ;;
        tvos|tvos-simulator) key=MinimumOSVersion; minimum=$tvos_min ;;
    esac
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>io.partout.$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>$key</key><string>$minimum</string>
</dict></plist>
EOF
}

make_framework() {
    local platform=$1 binary=$2 content plist
    made_framework="$work/frameworks/$platform/$name.framework"
    content=$made_framework
    plist="$content/Info.plist"

    if [[ $platform == macos ]]; then
        content="$made_framework/Versions/A"
        plist="$content/Resources/Info.plist"
        mkdir -p "$content/Resources"
    fi
    mkdir -p "$content/Headers" "$content/Modules"
    cp "$binary" "$content/$name"
    cp "$repo_dir/src/partout.h" "$content/Headers/partout.h"
    cp "$repo_dir/src/module.modulemap" "$content/Modules/module.modulemap"
    write_plist "$plist" "$platform"

    if [[ $platform == macos ]]; then
        ln -s A "$made_framework/Versions/Current"
        ln -s "Versions/Current/$name" "$made_framework/$name"
        for directory in Headers Modules Resources; do
            ln -s "Versions/Current/$directory" "$made_framework/$directory"
        done
    fi
}

add_framework() {
    local platform=$1 binary=$2 framework_binary dsym
    make_framework "$platform" "$binary"
    framework_binary="$made_framework/$name"
    [[ $platform != macos ]] || framework_binary="$made_framework/Versions/A/$name"
    dsym="$work/dsyms/$platform/$name.framework.dSYM"
    mkdir -p "$(dirname "$dsym")"
    xcrun dsymutil "$framework_binary" -o "$dsym"
    xcrun strip -S -x "$framework_binary"
    xcframework_args+=(-framework "$made_framework" -debug-symbols "$dsym")
}

xcframework_args=()
if [[ $mode == --full ]]; then
    for platform in macos ios ios-simulator tvos tvos-simulator; do
        case "$platform" in
            ios|tvos) binary="$work/install/$platform-arm64/lib/libpartout.dylib" ;;
            *) binary="$work/universal/$platform.dylib" ;;
        esac
        add_framework "$platform" "$binary"
    done
else
    slice=${slices[0]}
    add_framework "${slice%:*}" "$work/install/${slice/:/-}/lib/libpartout.dylib"
fi

generated="$work/$name.xcframework"
xcodebuild -create-xcframework "${xcframework_args[@]}" -output "$generated"
rm -rf "$output"
mv "$generated" "$output"
echo "Generated $output"
