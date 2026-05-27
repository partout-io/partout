#!/bin/bash
cwd=`dirname $0`
swift run codegen \
    --manifest $cwd/manifest.yaml \
    --aliases SecureData:string,UniqueID:string \
    >$cwd/openapi.yaml
