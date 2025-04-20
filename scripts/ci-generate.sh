#!/bin/bash
core_sha1=`git submodule status | cut -d ' ' -f 2`
sed -i '' "s/^let sha1 = .*$/let sha1 = \"$core_sha1\"/" "Package.swift"
CoreSource/scripts/create-framework.sh
