#!/bin/bash
set -e

usage() {
    echo "Usage: $0 <openapi> <language:swift|kotlin|cpp> <models_dir> <package_name> [extra_imports]"
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

postprocess_swift_models() {
    local models_dir=$1

    perl -0pi -e 's/&#x60;/`/g; s/&quot;/"/g; s/&gt;/>/g; s/&lt;/</g; s/&amp;/&/g' "$models_dir"/*.swift
    perl -0pi -e 's/^import Foundation\n//mg; s/^#if canImport\(AnyCodable\)\nimport AnyCodable\n#endif\n\n?//mg' "$models_dir"/*.swift
    perl -0pi -e 's/(\/\/ https:\/\/openapi-generator\.tech\n\/\/\n)\n+/$1\n/g' "$models_dir"/*.swift
    perl -0pi -e 's/\n    public enum CodingKeys: String, CodingKey, CaseIterable(?:, Sendable)? \{\n(?:        case [^\n]+\n)*    \}\n//g; s/\n    \/\/ Encodable protocol methods\n\n    public func encode\(to encoder: Encoder\) throws \{\n(?:        .*\n)*?    \}\n//g' "$models_dir"/*.swift
    perl -0pi -e 's/\n    public static let \w+Rule = (?:StringRule|NumericRule<[^>]+>|ArrayRule)\([^\n]+\)\n//g' "$models_dir"/*.swift
}

case $language in
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

        rm -rf "$models_dir"
        openapi-generator generate \
            -i "$infile" \
            -o "$tmp_dir" \
            -g swift6 \
            --global-property=models,modelDocs=false,modelTests=false \
            --schema-mappings Address=Address \
            --schema-mappings DNSModule.ProtocolType=DNSModuleProtocolType \
            --schema-mappings Endpoint=Endpoint \
            --schema-mappings EndpointProtocol=EndpointProtocol \
            --schema-mappings ExtendedEndpoint=ExtendedEndpoint \
            --schema-mappings ModuleImportContext=ModuleImportContext \
            --schema-mappings Subnet=Subnet \
            --schema-mappings UniqueID=UniqueID \
            --schema-mappings UInt16=UInt16 \
            --schema-mappings UInt32=UInt32 \
            --schema-mappings UInt64=UInt64 \
            --schema-mappings SecureData=SecureData \
            --schema-mappings TaggedModule=TaggedModule \
            --schema-mappings OpenVPN.CryptoContainer=OpenVPNCryptoContainer \
            --schema-mappings OpenVPN.ObfuscationMethod=OpenVPNObfuscationMethod \
            --schema-mappings WireGuard.Key=WireGuardKey \
            --type-mappings JSONValue=JSON,AnyCodable=JSON,URI=URL \
            --import-mappings JSONValue=JSON \
            --model-name-mappings Profile=TaggedProfile \
            --additional-properties=enumPropertyNaming=original,sortModelPropertiesByRequiredFlag=false,sortParamsByRequiredFlag=false

        generated_models_dir="$(find "$tmp_dir/Sources" -type d -name Models -print -quit)"
        if [[ -z "$generated_models_dir" ]]; then
            echo "Unable to find generated Swift models in $tmp_dir"
            exit 1
        fi
        mkdir -p "$models_dir"
        cp "$generated_models_dir"/*.swift "$models_dir"/
        postprocess_swift_models "$models_dir"
        ;;
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
            --model-name-mappings Profile=TaggedProfile \
            "${kotlin_extra_imports_opts[@]}"
        ;;
    cpp)
        tmp_dir="$(mktemp -d)"
        cleanup() {
            rm -rf "$tmp_dir"
        }
        trap cleanup EXIT

        cpp_generator=(openapi-generator)
        if [[ -n "$OPENAPI_GENERATOR_JAR" ]]; then
            cpp_generator=(java -jar "$OPENAPI_GENERATOR_JAR")
        fi
        cpp_version=$("${cpp_generator[@]}" version)
        if [[ "$cpp_version" != 7.20.0 ]]; then
            echo "C++ models require OpenAPI Generator 7.20.0 (found $cpp_version)."
            echo "Install that version or set OPENAPI_GENERATOR_JAR to its CLI jar."
            exit 1
        fi

        python3 "$(dirname "$0")/prepare-cpp-schema.py" \
            "$infile" "$tmp_dir/openapi.json" "$tmp_dir/unions.txt"
        union_models=$(cat "$tmp_dir/unions.txt")
        IFS=':' read -ra union_names <<< "$union_models"
        union_mappings=()
        for name in "${union_names[@]}"; do
            union_mappings+=(--schema-mappings "$name=$name")
        done

        # Stock value models provide optional fields and validation. The stock
        # httplib backend supplies typed unions and discriminator dispatch only.
        "${cpp_generator[@]}" generate \
            -i "$tmp_dir/openapi.json" -o "$tmp_dir/values" \
            -g cpp-pistache-server \
            --global-property=models,supportingFiles=Helpers.h:Helpers.cpp,modelDocs=false,modelTests=false \
            --type-mappings JSONValue=nlohmann::json,set=std::vector \
            --import-mappings 'JSONValue=#include <nlohmann/json.hpp>' \
            --name-mappings interface=interface_ \
            --additional-properties="modelPackage=$package_name,helpersPackage=Partout.Helpers,useStructModel=true,variableNameFirstCharacterUppercase=false,sortModelPropertiesByRequiredFlag=false" \
            "${union_mappings[@]}"
        "${cpp_generator[@]}" generate \
            -i "$tmp_dir/openapi.json" -o "$tmp_dir/unions" \
            -g cpp-httplib-server \
            --global-property="models=$union_models,modelDocs=false,modelTests=false" \
            --additional-properties="modelNamespace=${package_name//./::}"

        mkdir -p "$tmp_dir/models"
        cp "$tmp_dir/values/model/"*.h "$tmp_dir/values/model/"*.cpp "$tmp_dir/models/"
        cp "$tmp_dir/unions/models/"*.h "$tmp_dir/models/"
        python3 "$(dirname "$0")/finish-cpp-models.py" "$tmp_dir/models" "$tmp_dir/openapi.json"
        rm -rf "$models_dir"
        mkdir -p "$models_dir"
        cp "$tmp_dir/models/"* "$models_dir/"
        ;;
    *)
        echo "unknown language '$language'; expected 'swift', 'kotlin', or 'cpp'"
        exit 1
        ;;
esac
