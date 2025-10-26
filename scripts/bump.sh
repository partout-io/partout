#!/bin/bash
version=`cat .version`
abi="Sources/PartoutABI_C/partout.c"
set -e
sed -i '' -E "s/PARTOUT_VERSION = \"(.*)\"/PARTOUT_VERSION = \"$version\"/" $abi
git add .version $abi
git commit -m "[ci skip] Bump"
