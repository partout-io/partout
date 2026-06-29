#!/bin/bash
set -e
build_dir=.cmake
bin_dir=bin
swift_version=6.3.1
vendor_source=
vendor_prebuilt_url=
crypto_selected=
crypto_openssl=
crypto_mbedtls=
script_dir="$(dirname "$0")"

print_common_help() {
    cat "$script_dir/build-help.txt"
}

print_help() {
    cat <<EOF
Usage: scripts/build.sh [options]

Options:
EOF
    print_common_help
    cat <<EOF
  -gen-models [all|swift|kotlin|cpp]
                                  Generate OpenAPI models
  -config Debug|Release          Set the CMake build type
EOF
}

if [[ $# -eq 0 ]]; then
    print_help
    exit 0
fi

root_dir="$script_dir"/..
pushd $root_dir

generate_swift_models() {
    local openapi=$1

    scripts/gen-models.sh $openapi swift Sources/PartoutCore/OpenAPI/Codegen PartoutCore
}

generate_kotlin_models() {
    local openapi=$1
    local package=io.partout.models
    local models=cross
    local tmpmodels=cross-models

    scripts/gen-models.sh $openapi kotlin $tmpmodels $package
    rm -rf $models/android/io/partout/models
    mv $tmpmodels/src/main/kotlin/io/partout/models $models/android/io/partout
    rm -rf $tmpmodels
}

generate_cpp_models() {
    # TODO
    :
}

generate_models() {
    local language=${1:-all}
    local openapi=scripts/openapi.yaml

    case $language in
        all)
            generate_swift_models $openapi
            generate_kotlin_models $openapi
            generate_cpp_models $openapi
            ;;
        swift)
            generate_swift_models $openapi
            ;;
        kotlin)
            generate_kotlin_models $openapi
            ;;
        cpp)
            generate_cpp_models $openapi
            ;;
        *)
            echo "Unknown models language '$language'; expected 'all', 'swift', 'kotlin', or 'cpp'"
            exit 1
            ;;
    esac
}

positional_args=()
cmake_opts=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -clean)
            rm -rf $build_dir $bin_dir
            shift
            ;;
        -gen)
            do_build=1
            gen_build=1
            shift
            ;;
        -gen-models)
            gen_models=1
            if [[ -n $2 && $2 != -* ]]; then
                gen_models_language=$2
                shift
            fi
            shift
            ;;
        -config)
            # Debug|Release
            cmake_opts+=("-DCMAKE_BUILD_TYPE=$2")
            shift
            shift
            ;;
        -install)
            if [[ -z ${2:-} || $2 == -* ]]; then
                echo "-install requires a value"
                exit 1
            fi
            install_dir=$2
            mkdir -p "$install_dir"
            cmake_opts+=("-DCMAKE_INSTALL_PREFIX=$install_dir")
            do_build=1
            shift
            shift
            ;;
        -crypto)
            # openssl|native, comma-separated
            if [[ -z ${2:-} || $2 == -* ]]; then
                echo "-crypto requires a value"
                exit 1
            fi
            if [[ $2 == ,* || $2 == *, || $2 == *,,* ]]; then
                echo "Empty crypto in '$2'"
                exit 1
            fi
            crypto_selected=1
            do_build=1
            IFS=',' read -ra crypto_args <<< "$2"
            for crypto in "${crypto_args[@]}"; do
                crypto="${crypto//[[:space:]]/}"
                case $crypto in
                    openssl)
                        crypto_openssl=1
                        ;;
                    native)
                        crypto_mbedtls=1
                        ;;
                    "")
                        echo "Empty crypto in '$2'"
                        exit 1
                        ;;
                    *)
                        echo "Unknown crypto '$crypto'"
                        exit 1
                        ;;
                esac
            done
            shift
            shift
            ;;
        -openvpn)
            do_build=1
            cmake_opts+=("-DPP_BUILD_USE_OPENVPN=ON")
            shift
            ;;
        -wireguard)
            do_build=1
            cmake_opts+=("-DPP_BUILD_USE_WIREGUARD=ON")
            shift
            ;;
        -l)
            do_build=1
            cmake_opts+=("-DPP_BUILD_LIBRARY=ON")
            shift
            ;;
        -android)
            is_android=1
            build_dir=.cmake-android
            cmake_opts+=("-DCMAKE_ANDROID_NDK=$ANDROID_NDK_HOME")
            cmake_opts+=("-DANDROID_ABI=arm64-v8a")
            cmake_opts+=("-DANDROID_STL=c++_shared")
            cmake_opts+=("-DSWIFT_VERSION=$swift_version")
            cmake_opts+=("-DCMAKE_TOOLCHAIN_FILE=cmake/swift/swift-android.toolchain.cmake")
            shift
            ;;
        -vendors)
            if [[ -z ${2:-} || $2 == -* ]]; then
                shift
            else
                case $2 in
                    auto)
                        vendor_source=
                        ;;
                    bundled)
                        vendor_source=bundled
                        ;;
                    *)
                        vendor_prebuilt_url=$2
                        ;;
                esac
                shift
                shift
            fi
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

# Crypto
if [[ $crypto_selected == 1 ]]; then
    if [[ $crypto_openssl == 1 ]]; then
        cmake_opts+=("-DPP_BUILD_USE_OPENSSL=ON")
    else
        cmake_opts+=("-DPP_BUILD_USE_OPENSSL=OFF")
    fi
    if [[ $crypto_mbedtls == 1 ]]; then
        cmake_opts+=("-DPP_BUILD_USE_MBEDTLS=ON")
    else
        cmake_opts+=("-DPP_BUILD_USE_MBEDTLS=OFF")
    fi
fi

# Vendor overrides
if [[ -n $vendor_source ]]; then
    cmake_opts+=("-DPP_BUILD_VENDOR_SOURCE=$vendor_source")
fi
if [[ -n $vendor_prebuilt_url ]]; then
    cmake_opts+=("-DPP_BUILD_VENDOR_PREBUILT_URL=$vendor_prebuilt_url")
fi

# On Linux, use custom toolchain
if [[ $is_android != 1 && `uname -s` == "Linux" ]]; then
    cmake_opts+=("-DSWIFT_VERSION=$swift_version")
    cmake_opts+=("-DCMAKE_TOOLCHAIN_FILE=cmake/swift/swift-linux.toolchain.cmake")
fi

# Generate models
if [[ $gen_models == 1 ]]; then
    generate_models $gen_models_language
fi

# Generate CMake files
if [[ ! -d $build_dir ]]; then
    mkdir $build_dir
fi
if [[ ! -d $bin_dir ]]; then
    mkdir $bin_dir
fi
if [[ $gen_build == 1 ]]; then
    scripts/gen-cmake-files.sh
    cmake -G Ninja -S . -B $build_dir "${cmake_opts[@]}"
fi

# Execute
if [[ $do_build == 1 ]]; then
    cmake --build $build_dir
    if [[ -n $install_dir ]]; then
        cmake --install $build_dir
    fi
fi

popd
