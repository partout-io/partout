#!/bin/bash
build_cfg="debug"
if [ -n "$1" ]; then
    build_cfg="$1"
fi
PARTOUT_OS="android" \
PARTOUT_CORE="remoteSource" \
swiftly run \
swift build \
    -c $build_cfg \
    --swift-sdk aarch64-unknown-linux-android24
