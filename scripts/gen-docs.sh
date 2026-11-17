#!/bin/bash
web_src=".build/plugins/Swift-DocC/outputs/partout.doccarchive"
web_dst=".build/docs"
set -e

if [[ -n $1 ]]; then
    port=$1
    jekyll serve -s "$web_src" -d "$web_dst" -P $port
    exit
fi

PP_BUILD_DOCS="1" swift package generate-documentation \
    --enable-experimental-combined-documentation \
    --target PartoutCore
