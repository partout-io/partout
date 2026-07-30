#!/bin/bash
LC_ALL=C
filelist=files.cmake
set -e

(
    cd Sources
    cat >${filelist} <<EOF
set(PARTOUT_SOURCES
$(find . -name "*.swift" | sort)
)
set(PARTOUT_C_SOURCES
$(find . \( -name "*.c" -o -name "*.cc" \) | sort)
)
EOF
)

(
    cd zig
    cat >src/${filelist} <<EOF
set(PARTOUT_ZIG_SOURCES
$(find build.zig src tests tools -name "*.zig" | sort)
)
set(PARTOUT_C_SOURCES
$(find -L src -name "*.c" | sort)
)
EOF
)
