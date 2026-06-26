#!/bin/bash
set -e
opt_configuration=Debug
build_dir=.cmake
bin_dir=bin
swift_version=6.3.1

root_dir="$(dirname "$0")"/..
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
            install_dir=$2
            mkdir $install_dir || true
            cmake_opts+=("-DCMAKE_INSTALL_PREFIX=$install_dir")
            shift
            shift
            ;;
        -a)
            do_build=1
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
