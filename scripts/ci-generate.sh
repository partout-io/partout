#!/bin/bash
src_path="PartoutCore"
src_url="git@github.com:passepartoutvpn/partout-core.git"
src_sha1=`grep 'let sha1' Package.swift | sed -E "s/^let sha1 = \"([A-Fa-f0-9]{40})\"$/\\1/"`
git clone --no-checkout --filter=blob:none --depth=1 $src_url $src_path
( cd $src_path && git fetch origin $src_sha1 && git checkout $src_sha1 )
$src_path/scripts/create-framework.sh
