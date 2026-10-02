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
[[ $# -ge 1 ]] ||
    fail "usage: $0 <prebuilts-version> [--out output.xcframework] [--prebuilts-out directory] [--full] [--crypto openssl,mbedtls]"
prebuilts_version=$1
shift
output="$repo_dir/$name.xcframework"
prebuilts="$repo_dir/prebuilts"
mode=
crypto_backends=openssl,mbedtls
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out|--prebuilts-out|--crypto)
            [[ $# -ge 2 && $2 != --* ]] || fail "missing value for $1"
            case "$1" in
                --out) output=$2 ;;
                --prebuilts-out) prebuilts=$2 ;;
                --crypto) crypto_backends=$2 ;;
            esac
            shift 2
            ;;
        --full) mode=--full; shift ;;
        *) fail "unknown option: $1" ;;
    esac
done

# Crypto backends default to all. WireGuard is always included.
vendors=()
if [[ -n $crypto_backends ]]; then
    [[ $crypto_backends != ,* && $crypto_backends != *, && $crypto_backends != *,,* ]] ||
        fail "invalid crypto backend list: $crypto_backends"
    IFS=, read -r -a backends <<< "$crypto_backends"
    for backend in "${backends[@]}"; do
        case "$backend" in
            openssl|mbedtls) ;;
            *) fail "unknown crypto backend: $backend" ;;
        esac
        [[ " ${vendors[*]-} " != *" $backend "* ]] || fail "duplicate crypto backend: $backend"
        vendors+=("$backend")
    done
fi

[[ $prebuilts_version =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] ||
    fail "invalid prebuilts version: $prebuilts_version"
[[ $output == *.xcframework ]] || fail "output must have an .xcframework extension"

for tool in cmake go curl ditto lipo swift xcodebuild xcrun zig; do
    command -v "$tool" >/dev/null || fail "missing required tool: $tool"
done

mkdir -p "$prebuilts" "$(dirname "$output")"
prebuilts=$(cd "$prebuilts" && pwd -P)
output=$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")
version=$(sed -nE 's/^pub const number = "([0-9A-Za-z.+-]+)";$/\1/p' "$repo_dir/src/version.zig")
[[ -n $version ]] || fail "unable to read the library version"

download_prebuilts() {
    local repository=https://github.com/partout-io/prebuilts
    local base temp vendor archive checksum expected actual

    if [[ -f "$prebuilts/prebuilts-version.txt" &&
          $(cat "$prebuilts/prebuilts-version.txt") == "$prebuilts_version" &&
          -d "$prebuilts/openssl.xcframework" &&
          -d "$prebuilts/mbedtls.xcframework" ]]; then
        echo "Using local prebuilts $prebuilts_version"
        return
    fi

    base="$repository/releases/download/$prebuilts_version"
    temp=$(mktemp -d "${TMPDIR:-/tmp}/partout-prebuilts.XXXXXX")
    trap 'rm -rf "$temp"' EXIT

    echo "Using prebuilts $prebuilts_version"
    for vendor in openssl mbedtls; do
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

    echo "$prebuilts_version" > "$prebuilts/prebuilts-version.txt"
    rm -rf "$temp"
    trap - EXIT
}

download_prebuilts

work="$repo_dir/zig-out/xcframework-build"
build_cache="$repo_dir/zig-out/xcframework-cmake"
rm -rf "$work"
mkdir -p "$work/install" "$work/frameworks" "$work/universal" "$work/dsyms"
chmod 755 "$work" "$work/install"

build_slice() {
    local platform=$1 arch=$2 clang_target sdk_name
    local sdk install build system minimum vendor
    local cmake_args=()

    case "$platform:$arch" in
        macos:*)
            clang_target="$arch-apple-macos$macos_min"
            sdk_name=macosx
            system=Darwin
            minimum=$macos_min
            ;;
        ios:arm64)
            clang_target="arm64-apple-ios$ios_min"
            sdk_name=iphoneos
            system=iOS
            minimum=$ios_min
            ;;
        ios-simulator:*)
            clang_target="$arch-apple-ios$ios_min-simulator"
            sdk_name=iphonesimulator
            system=iOS
            minimum=$ios_min
            ;;
        tvos:arm64)
            clang_target="arm64-apple-tvos$tvos_min"
            sdk_name=appletvos
            system=tvOS
            minimum=$tvos_min
            ;;
        tvos-simulator:*)
            clang_target="$arch-apple-tvos$tvos_min-simulator"
            sdk_name=appletvsimulator
            system=tvOS
            minimum=$tvos_min
            ;;
        *) fail "unsupported slice: $platform $arch" ;;
    esac

    sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
    install="$work/install/$platform-$arch"
    build="$build_cache/$platform-$arch"
    cmake_args=(-DPP_BUILD_USE_OPENSSL=OFF -DPP_BUILD_USE_MBEDTLS=OFF)
    for vendor in "${vendors[@]+"${vendors[@]}"}"; do
        case "$vendor" in
            openssl) cmake_args+=(-DPP_BUILD_USE_OPENSSL=ON) ;;
            mbedtls) cmake_args+=(-DPP_BUILD_USE_MBEDTLS=ON) ;;
        esac
    done

    echo "Building $platform $arch"
    cmake -S "$repo_dir" -B "$build" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DPP_BUILD_LIBRARY=ON \
        -DPP_BUILD_USE_OPENVPN=ON \
        -DPP_BUILD_USE_WIREGUARD=ON \
        "-DPP_BUILD_OUTPUT=$work/install/$platform-$arch-build" \
        "-DCMAKE_INSTALL_PREFIX=$install" \
        "-DPP_BUILD_APPLE_PREBUILTS=$prebuilts" \
        "-DPP_BUILD_APPLE_INSTALL_NAME=@rpath/$name.framework/$name" \
        "-DPP_BUILD_GO_RUNTIME_CACHE=$build_cache/go-runtime" \
        "-DCMAKE_SYSTEM_NAME=$system" \
        "-DCMAKE_OSX_ARCHITECTURES=$arch" \
        "-DCMAKE_OSX_SYSROOT=$sdk" \
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum" \
        "-DCMAKE_C_COMPILER_TARGET=$clang_target" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        "${cmake_args[@]}"
    cmake --build "$build" --config RelWithDebInfo
    cmake --install "$build" --config RelWithDebInfo
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
        arm64|arm64e|aarch64) arch=arm64 ;;
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
