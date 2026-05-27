#!/bin/bash
set -e

usage() {
    echo "Usage: $0 <openapi> <language:kotlin|cpp> <models_dir> <package_name> [extra_imports]"
    exit 1
}

if [ "$#" -lt 4 ]; then
    usage
fi

infile=$1
language=$2
models_dir=$3
package_name=$4
extra_imports=$5

# First, update the OpenAPI metadata
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
$script_dir/gen-api.sh

case $language in
    kotlin)
        kotlin_extra_imports_opts=()
        if [[ -n "$extra_imports" ]]; then
            IFS=',' read -ra extra_import_names <<< "$extra_imports"
            for name in "${extra_import_names[@]}"; do
                name="${name#"${name%%[![:space:]]*}"}"
                name="${name%"${name##*[![:space:]]}"}"

                if [[ -n "$name" ]]; then
                    kotlin_extra_imports_opts+=(
                        --import-mappings "$name=io.partout.models.$name"
                        --schema-mappings "$name=$name"
                    )
                fi
            done
        fi

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
            "${kotlin_extra_imports_opts[@]}"
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
