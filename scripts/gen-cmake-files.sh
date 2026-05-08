#!/bin/bash
partout=partout.cmake

set -e
cd Sources

cat >${partout} <<EOF
set(PARTOUT_SOURCES
$(find . -name "*.swift")
)
set(PARTOUT_C_SOURCES
$(find . -name "*.c")
)
EOF
