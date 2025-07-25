#!/bin/bash
core_src="../partout-core/Sources"
core_dst="PartoutCore"
web_src=".build/plugins/Swift-DocC/outputs/Partout.doccarchive"
web_dst="docs"

set -e

rm -rf "$core_dst"
mkdir "$core_dst"
cp -rp "$core_src/PartoutCore" \
    "$core_src/_PartoutCore_C" \
    "$core_dst"

swift package generate-documentation \
    --enable-experimental-combined-documentation \
    --target PartoutCore \
    --target PartoutProviders

if [[ -z $1 ]]; then
    exit
fi

port=$1
jekyll serve -s "$web_src" -d "$web_dst" -P $port
