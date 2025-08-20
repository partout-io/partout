#!/bin/bash
is_release=$1
cmake_cfg="Debug"
spm_cfg="debug"
if [ "$is_release" == 1 ]; then
    cmake_cfg="Release"
    spm_cfg="release"
fi
set -e

# 1. Build CMake vendors (if release)

if [ "$is_release" == 1 ]; then
    scripts/build.sh -config $cmake_cfg -android
fi

# 2. Build SwiftPM with Android SDK

PP_BUILD_OS="android" \
PP_BUILD_CORE="localSource" \
PP_BUILD_CMAKE_OUTPUT="bin/android-arm64" \
swiftly run \
swift build \
    -c $spm_cfg \
    --swift-sdk aarch64-unknown-linux-android24
