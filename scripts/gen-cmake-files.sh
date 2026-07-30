#!/bin/bash
LC_ALL=C
filelist=files.cmake
set -e

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
