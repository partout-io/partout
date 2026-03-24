#!/bin/bash
swift run codegen \
    --manifest scripts/manifest.yaml \
    --aliases SecureData:string,UniqueID:string \
    >scripts/openapi.yaml
