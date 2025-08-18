#!/bin/bash
opt_configuration=Debug

positional_args=()
cmake_opts=()
while [[ $# -gt 0 ]]; do
    case $1 in
    -c)
        cmake_opts+=("-DCMAKE_BUILD_TYPE=$2") # Debug|Release
        shift
        shift
        ;;
    -l)
        cmake_opts+=("-DBUILD_LIBRARY=1")
        shift
        ;;
    -android)
        PATH=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin:$PATH
        cmake_opts+=("-DBUILD_FOR_ANDROID=1")
        shift
        ;;
    -*|--*)
        echo "Unknown option $1"
        exit 1
        ;;
    *)
        positional_args+=("$1")
        shift # past argument
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
