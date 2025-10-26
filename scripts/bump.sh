#!/bin/bash
version="$1"
if [[ -z $1 ]]; then                                                                                                                                      
    echo "Version required"
    exit 1
fi
abi="Sources/PartoutABI_C/partout.c"
set -e
sed -i '' -E "s/PARTOUT_VERSION = \"(.*)\"/PARTOUT_VERSION = \"$version\"/" $abi
git commit -m "[ci skip] Bump"
git tag -as "$version" -m "$version"
