#!/bin/bash
version="$1"
if [[ -z $1 ]]; then                                                                                                                                      
    echo "Version required"
    exit 1
fi
abi="Sources/PartoutABI_C/partout.c"
set -e
sed -i '' -E "s/PARTOUT_VERSION = \"(.*)\"/PARTOUT_VERSION = \"$version\"/" $abi
git add "$abi"
git commit --allow-empty -m "[ci skip] Bump"
git tag -as "$version" -m "$version"
