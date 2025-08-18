#!/bin/bash
rm -f build/*.txt
if [ ! -d build ]; then
    mkdir build
fi
set -e
cd build && rm -rf PartoutProject*
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release ..
cmake --build .
