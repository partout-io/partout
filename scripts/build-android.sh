#!/bin/bash
cmake_cfg="Debug"
spm_cfg="debug"
if [ "$1" == 1 ]; then
    cmake_cfg="Release"
    spm_cfg="release"
fi

# 1. Build CMake vendors

scripts/build.sh -clean -config $cmake_cfg -android

# 2. Build SwiftPM with Android SDK

PARTOUT_OS="android" \
PARTOUT_CORE="remoteSource" \
swiftly run \
swift build \
    -c $spm_cfg \
    --swift-sdk aarch64-unknown-linux-android24
