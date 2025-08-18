#!/bin/bash
build_type=Debug
if [ -n $1 ]; then
    build_type=$1
fi
rm -f build/*.txt
if [ ! -d build ]; then
    mkdir build
fi
set -e
cd build
rm -rf PartoutProject*
cmake -G Ninja -DCMAKE_BUILD_TYPE="$build_type" ..
cmake --build .
