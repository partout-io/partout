#!/bin/bash
set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

usage() {
    echo "Usage: $0 <openapi> <language:kotlin|cpp> <models_dir> <package_name>"
    exit 1
}

if [ "$#" -ne 4 ]; then
    usage
fi

infile=$1
language=$2
models_dir=$3
package_name=$4

# First, update the OpenAPI metadata
$script_dir/gen-api.sh

case $language in
    kotlin)
        package_dir=${package_name//./\/}
        rm -rf $models_dir/src/main/kotlin/$package_dir
        openapi-generator generate \
            -i $infile \
            -o $models_dir \
            -g kotlin \
            --global-property=models,modelDocs=false,modelTests=false \
            --type-mappings number=Double,URI=String,kotlin.Any=kotlinx.serialization.json.JsonElement \
            --import-mappings Double=kotlin.Double,String=kotlin.String \
            --additional-properties=serializationLibrary=kotlinx_serialization \
            --additional-properties=packageName=$package_name \
            --additional-properties=modelPackage=$package_name \
            --schema-mappings OpenVPN.CryptoContainer=kotlin.String \
        ;;
    cpp)
        echo "cpp language is not implemented yet; exiting."
        exit 0
        ;;
    *)
        echo "unknown language '$language'; expected 'kotlin' or 'cpp'"
        exit 1
        ;;
esac
