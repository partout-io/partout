#!/bin/bash
opt_configuration=Debug
build_dir=.cmake
bin_dir=bin

#export ANDROID_NDK_ROOT=
export SWIFT_ANDROID_SDK=~/.swiftpm/swift-sdks/swift-6.2-RELEASE-android-0.1.artifactbundle

# These are derived from the above
export ANDROID_NDK_TOOLCHAIN=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin
export ANDROID_NDK_SYSROOT=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/sysroot
export ANDROID_NDK_API=28
export SWIFT_ANDROID_RESOURCE_DIR=$SWIFT_ANDROID_SDK/swift-android/swift-resources/usr/lib/swift-aarch64

positional_args=()
cmake_opts=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -clean)
            rm -rf $build_dir $bin_dir
            shift
            ;;
        -config)
            # Debug|Release
            cmake_opts+=("-DCMAKE_BUILD_TYPE=$2")
            shift
            shift
            ;;
        -a)
            cmake_opts+=("-DPP_BUILD_LIBRARY=ON")
            cmake_opts+=("-DPP_BUILD_USE_OPENSSL=ON")
            cmake_opts+=("-DPP_BUILD_USE_WGGO=ON")
            shift
            ;;
        -crypto)
            # openssl|native
            case $2 in
                openssl)
                    cmake_opts+=("-DPP_BUILD_USE_OPENSSL=ON")
                    ;;
                native)
                    cmake_opts+=("-DPP_BUILD_USE_MBEDTLS=ON")
                    ;;
                *)
                    echo "Unknown crypto '$2'"
                    exit 1
                    ;;
            esac
            shift
            shift
            ;;
        -wireguard)
            cmake_opts+=("-DPP_BUILD_USE_WGGO=ON")
            shift
            ;;
        -l)
            cmake_opts+=("-DPP_BUILD_LIBRARY=ON")
            shift
            ;;
        -android)
            PATH=$ANDROID_NDK_TOOLCHAIN:$PATH
            cmake_opts+=("-DCMAKE_TOOLCHAIN_FILE=android.cmake")
            shift
            ;;
        -*|--*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            positional_args+=("$1")
            shift
            ;;
    esac
done
set -- "${positional_args[@]}"

set -e
if [ ! -d $build_dir ]; then
    mkdir $build_dir
fi
cd $build_dir
rm -f *.txt
cmake -G Ninja "${cmake_opts[@]}" ..
cmake --build .
