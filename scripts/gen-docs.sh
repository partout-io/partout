#!/bin/bash
web_src=".build/plugins/Swift-DocC/outputs/partout.doccarchive"
web_dst=".build/docs"

set -e

PP_BUILD_DOCS="1" swift package generate-documentation \
    --enable-experimental-combined-documentation \
    --target Partout \
    --target PartoutCore \
    --target PartoutOS \
    --target PartoutOpenVPN \
    --target PartoutOpenVPNConnection \
    --target PartoutWireGuard \
    --target PartoutWireGuardConnection

if [[ -z $1 ]]; then
    exit
fi

port=$1
jekyll serve -s "$web_src" -d "$web_dst" -P $port
