#!/bin/bash
swift run partout-codegen \
    --manifest scripts/manifest.yaml \
    --aliases SecureData:string,UniqueID:string \
    >scripts/openapi.yaml
