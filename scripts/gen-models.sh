#!/bin/bash
set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
infile="$script_dir/openapi.yaml"

usage() {
    echo "Usage: $0 <lang:kotlin|cpp> <models-dir>"
    exit 1
}

if [ "$#" -ne 2 ]; then
    usage
fi

mode=$1
models_dir=$2

# First, update the OpenAPI metadata
$script_dir/gen-api.sh

case $mode in
    kotlin)
        package_name=io.partout.abi
        rm -rf $models_dir/src/main/kotlin/io/partout/abi
        openapi-generator generate \
            -i $infile \
            -o $models_dir \
            -g kotlin \
            --global-property=models,modelDocs=false,modelTests=false \
            --type-mappings number=Double,URI=String,kotlin.Any=kotlinx.serialization.json.JsonElement \
            --import-mappings Double=kotlin.Double,String=kotlin.String \
            --additional-properties=serializationLibrary=kotlinx_serialization \
            --additional-properties=packageName=$package_name \
            --additional-properties=modelPackage=$package_name
        ;;
    cpp)
        echo "cpp mode is not implemented yet; exiting."
        exit 0
        ;;
    *)
        echo "unknown mode '$mode'; expected 'kotlin' or 'cpp'"
        exit 1
        ;;
esac
