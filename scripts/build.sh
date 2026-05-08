#!/bin/bash
set -e
opt_configuration=Debug
build_dir=.cmake
bin_dir=bin

positional_args=()
cmake_opts=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -clean)
            rm -rf $build_dir $bin_dir
            shift
            ;;
        -gen)
            gen_build=1
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
            # Requires ANDROID_NDK_HOME and toolchain in PATH
            export SWIFT_ANDROID_ABI=arm64-v8a
            export SWIFT_ANDROID_ARCH=aarch64
            export SWIFT_ANDROID_API_LEVEL=28
            export SWIFT_ANDROID_VERSION=6.3.1
            cmake_opts+=("-DCMAKE_TOOLCHAIN_FILE=toolchains/android.toolchain.cmake")
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

# Generate CMake files
if [ $gen_build == 1 ]; then
    scripts/gen-cmake-files.sh
    cd $build_dir
    cmake -G Ninja "${cmake_opts[@]}" ..
else
    cd $build_dir
fi

cmake --build .
