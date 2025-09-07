#!/bin/bash
# FIXME: #199, Pick from environment
NDKTOOLS=~/Library/Android/sdk/ndk/29.0.13846066/toolchains/llvm/prebuilt/darwin-x86_64/bin/
PATH=$NDKTOOLS:$PATH
make ANDROID=1
