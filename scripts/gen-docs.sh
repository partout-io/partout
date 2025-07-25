#!/bin/bash
web_src=".build/plugins/Swift-DocC/outputs/Partout.doccarchive"
web_dst="docs"

set -e

swift package generate-documentation \
    --enable-experimental-combined-documentation \
    --target PartoutCore \
    --target PartoutProviders

if [[ -z $1 ]]; then
    exit
fi

port=$1
jekyll serve -s "$web_src" -d "$web_dst" -P $port
