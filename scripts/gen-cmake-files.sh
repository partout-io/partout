#!/bin/bash
LC_ALL=C
partout=partout.cmake
set -e
cd Sources
cat >${partout} <<EOF
set(PARTOUT_SOURCES
$(find . -name "*.swift" | sort)
)
set(PARTOUT_C_SOURCES
$(find . \( -name "*.c" -o -name "*.cc" \) | sort)
)
EOF
