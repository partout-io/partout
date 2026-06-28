#!/bin/bash
LC_ALL=C
filelist=files.cmake
set -e
cd Sources
cat >${filelist} <<EOF
set(PARTOUT_SOURCES
$(find . -name "*.swift" | sort)
)
set(PARTOUT_C_SOURCES
$(find . \( -name "*.c" -o -name "*.cc" \) | sort)
)
EOF
