#!/bin/bash
version="$1"
if [[ -z $1 ]]; then                                                                                                                                      
    echo "Version required"
    exit 1
fi
constants="Sources/PartoutCore/PartoutConstants.swift"
set -e
sed -i '' -E "s/version = \"(.*)\"/version = \"$version\"/" $constants
git add "$constants"
git commit -m "Bump version"
git tag -as "$version" -m "$version"
