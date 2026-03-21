#!/bin/bash
set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
infile="$script_dir/openapi.yaml"

usage() {
    echo "Usage: $0 <lang:kotlin|cpp> <ir-output-dir> <lang-dest-dir>"
    exit 1
}

if [ "$#" -ne 3 ]; then
    usage
fi

mode=$1
outdir=$2
dstdir=$3

case $mode in
    kotlin)
        package_name=io.partout.abi
        src=$outdir/src/main/kotlin/io/partout/abi
        dst=$dstdir/src/main/java/io/partout/abi

        openapi-generator generate \
            -i $infile \
            -o $outdir \
            -g kotlin \
            --global-property=models,modelDocs=false,modelTests=false \
            --schema-mappings URI=String \
            --import-mappings String=kotlin.String \
            --additional-properties=serializationLibrary=kotlinx_serialization \
            --additional-properties=packageName=$package_name \
            --additional-properties=modelPackage=$package_name

        rm -rf $dst
        mkdir -p $dst
        cp $src/*.kt $dst
        rm -rf $outdir
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
