#!/bin/bash
set -e

usage() {
    echo "Usage: $0 <openapi> <language:kotlin|swift|cpp> <models_dir> <package_name> [extra_imports]"
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
    swift)
        # Generate into a temporary client package, then keep only the models.
        #
        # DocC comments are emitted by openapi-generator from OpenAPI schema
        # descriptions. Keep descriptions in openapi.yaml to preserve them here.
        tmp_dir="$(mktemp -d)"
        cleanup() {
            rm -rf "$tmp_dir"
        }
        trap cleanup EXIT

        project_name=$package_name
        rm -rf "$models_dir"
        openapi-generator generate \
            -i "$infile" \
            -o "$tmp_dir" \
            -g swift5 \
            --global-property=models,modelDocs=false,modelTests=false \
            --additional-properties=projectName="$project_name" \
            --additional-properties=responseAs=AsyncAwait \
            --additional-properties=useSPMFileStructure=true \
            --additional-properties=useJsonEncodable=false \
            --additional-properties=validatable=false \
            --additional-properties=identifiableModels=false \
            --additional-properties=hashableModels=true

        generated_models_dir="$tmp_dir/Sources/$project_name/Models"
        mkdir -p "$models_dir"
        cp "$generated_models_dir"/*.swift "$models_dir"/
        perl -0pi -e 's/&#x60;/`/g; s/&quot;/"/g; s/&gt;/>/g; s/&lt;/</g; s/&amp;/&/g' "$models_dir"/*.swift
        ;;
    cpp)
        echo "cpp language is not implemented yet; exiting."
        exit 0
        ;;
    *)
        echo "unknown language '$language'; expected 'kotlin', 'swift', or 'cpp'"
        exit 1
        ;;
esac
