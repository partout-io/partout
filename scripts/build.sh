#!/bin/bash
opt_configuration=Debug

positional_args=()
cmake_opts=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -clean)
            rm -rf build bin
            shift
            ;;
        -config)
            # Debug|Release
            cmake_opts+=("-DCMAKE_BUILD_TYPE=$2")
            shift
            shift
            ;;
        -crypto)
            # openssl|mbedtls
            case $2 in
                openssl)
                    cmake_opts+=("-DPP_BUILD_USE_OPENSSL=ON")
                    ;;
                mbedtls)
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
        -l)
            cmake_opts+=("-DPP_BUILD_LIBRARY=ON")
            shift
            ;;
        -android)
            PATH=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH
            rm -rf build bin/android
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

rm -f build/*.txt
if [ ! -d build ]; then
    mkdir build
fi

set -e
cd build
rm -rf PartoutProject*

cmake -G Ninja "${cmake_opts[@]}" ..
cmake --build .
