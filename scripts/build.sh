#!/bin/bash
set -e
opt_configuration=Debug
build_dir=.cmake
bin_dir=bin

root_dir="$(dirname "$0")"/..
pushd $root_dir

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
        -gen-models)
            gen_models=1
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
            cmake_opts+=("-DPP_BUILD_USE_OPENVPN=ON")
            cmake_opts+=("-DPP_BUILD_USE_WIREGUARD=ON")
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
        -openvpn)
            cmake_opts+=("-DPP_BUILD_USE_OPENVPN=ON")
            shift
            ;;
        -wireguard)
            cmake_opts+=("-DPP_BUILD_USE_WIREGUARD=ON")
            shift
            ;;
        -l)
            cmake_opts+=("-DPP_BUILD_LIBRARY=ON")
            shift
            ;;
        -android)
            # Requires ANDROID_NDK_HOME
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

# Generate CMake files
if [[ ! -d $build_dir ]]; then
    mkdir $build_dir
fi
if [[ ! -d $bin_dir ]]; then
    mkdir $bin_dir
fi
if [[ $gen_build == 1 ]]; then
    scripts/gen-cmake-files.sh
    pushd $build_dir
    cmake -G Ninja "${cmake_opts[@]}" ..
else
    pushd $build_dir
fi
cmake --build .
popd

# Generate foreign models
if [[ $gen_models == 1 ]]; then
    openapi=scripts/openapi.yaml
    package=io.partout.abi
    models=cross
    tmpmodels=cross-models
    # Kotlin
    scripts/gen-models.sh $openapi kotlin $tmpmodels $package
    rm -rf $models/android/io/partout/abi
    mv $tmpmodels/src/main/kotlin/io/partout/abi $models/android/io/partout
    # C++ (TODO)
    ######
    rm -rf cross-models
fi

popd root_dir
