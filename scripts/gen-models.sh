#!/bin/bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 6 ]]; then
    echo "Usage: $0 <openapi> <language:swift|kotlin|cpp> <models_dir> <package_name> [extra_imports] [swift_prefix]" >&2
    exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd -P)
input=$1
language=$2
destination=$3
package=$4
extra_imports=${5:-}

swift_prefix=${6:-}
case "$language" in
    swift) ;;
    kotlin)
        package_dir=${package//./\/}
        destination="$destination/src/main/kotlin/$package_dir"
        ;;
    cpp) package=${package//./::} ;;
    *) echo "Unknown model language: $language" >&2; exit 1 ;;
esac
if [[ -z "$destination" || "$destination" == / || "$destination" == . || "$destination" == .. ]]; then
    echo "Refusing unsafe model destination: $destination" >&2
    exit 1
fi
# Render off to the side. Invalid schemas cannot delete the last good models.
parent=$(dirname "$destination")
mkdir -p "$parent"
staging=$(mktemp -d "$parent/.partout-codegen.XXXXXX")
cleanup() {
    if [[ -d "$staging/previous" && ! -e "$destination" ]]; then
        mv "$staging/previous" "$destination"
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
zig run "$script_dir/../tools/openapi_codegen.zig" -- \
    "$input" "$staging/models" --language "$language" --package "$package" \
    --external "$extra_imports" --swift-prefix "$swift_prefix"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous"
fi
mv "$staging/models" "$destination"
