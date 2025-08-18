#!/bin/bash
rm -f build/*.txt
if [ ! -d build ]; then
    mkdir build
fi
cd build && rm -rf PartoutProject*
cmake -G Ninja .. && cmake --build .
