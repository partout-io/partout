#!/bin/bash
NDKTOOLS=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin
PATH=$NDKTOOLS:$PATH
make ANDROID=1
