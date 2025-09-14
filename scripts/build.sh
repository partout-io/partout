#!/bin/bash
opt_configuration=Debug
build_dir=.cmake
bin_dir=.bin
ndk_toolchain=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin

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
            PATH=$ndk_toolchain:$PATH
            rm -rf $build_dir $bin_dir/android
            cmake_opts+=("-DPP_BUILD_FOR_ANDROID=ON")
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

rm -f $build_dir/*.txt
if [ ! -d $build_dir ]; then
    mkdir $build_dir
fi

set -e
cd $build_dir
rm -rf PartoutProject*

cmake -G Ninja "${cmake_opts[@]}" ..
cmake --build .
