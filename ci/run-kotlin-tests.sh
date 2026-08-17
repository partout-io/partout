#!/bin/bash

set -euo pipefail

fail() {
    echo "run-kotlin-tests.sh: $*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail "usage: $0"
for tool in java curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

kotlinc=${KOTLINC:-}
if [[ -z $kotlinc ]] && command -v kotlinc >/dev/null 2>&1; then
    kotlinc=$(command -v kotlinc)
fi
if [[ -z $kotlinc && -x /Applications/Android\ Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc ]]; then
    kotlinc=/Applications/Android\ Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc
fi
[[ -x $kotlinc ]] || fail "missing required tool: kotlinc"

while [[ -L $kotlinc ]]; do
    kotlinc_dir=$(cd "$(dirname "$kotlinc")" && pwd -P)
    kotlinc_target=$(readlink "$kotlinc")
    case $kotlinc_target in
        /*) kotlinc=$kotlinc_target ;;
        *) kotlinc="$kotlinc_dir/$kotlinc_target" ;;
    esac
done
kotlinc=$(cd "$(dirname "$kotlinc")" && pwd -P)/$(basename "$kotlinc")

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
android_platform=${ANDROID_PLATFORM:-36}
android_jar="$android_home/platforms/android-$android_platform/android.jar"
[[ -f $android_jar ]] || fail "missing Android platform JAR: $android_jar"

kotlin_home=$(cd "$(dirname "$kotlinc")/.." && pwd -P)
serialization_plugin=
for candidate in \
    "$kotlin_home/lib/kotlinx-serialization-compiler-plugin.jar" \
    "$kotlin_home/lib/kotlin-serialization-compiler-plugin.jar"; do
    if [[ -f $candidate ]]; then
        serialization_plugin=$candidate
        break
    fi
done
[[ -n $serialization_plugin ]] || fail "missing Kotlin serialization compiler plugin"

work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/partout-kotlin.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
dependencies_dir="$work_dir/dependencies"
mkdir -p "$dependencies_dir"

download() {
    local url=$1
    local output=$2
    curl --fail --location --silent --show-error "$url" --output "$output"
}

add_jar() {
    local repository=$1
    local path=$2
    local filename=${path##*/}
    local output="$dependencies_dir/$filename"
    download "$repository/$path" "$output"
    classpath="$classpath:$output"
}

add_aar() {
    local path=$1
    local name=${path##*/}
    local output="$dependencies_dir/$name"
    local extracted="$dependencies_dir/${name%.aar}"
    download "https://dl.google.com/dl/android/maven2/$path" "$output"
    mkdir -p "$extracted"
    unzip -qq "$output" classes.jar -d "$extracted"
    classpath="$classpath:$extracted/classes.jar"
}

classpath=$android_jar
google_maven=https://dl.google.com/dl/android/maven2
maven_central=https://repo.maven.apache.org/maven2
add_aar androidx/core/core/1.16.0/core-1.16.0.aar
add_aar androidx/core/core-ktx/1.16.0/core-ktx-1.16.0.aar
add_aar androidx/annotation/annotation-experimental/1.4.1/annotation-experimental-1.4.1.aar
add_jar "$google_maven" androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar
add_jar "$google_maven" androidx/collection/collection-jvm/1.5.0/collection-jvm-1.5.0.jar
add_jar "$maven_central" org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.9.0/kotlinx-coroutines-core-jvm-1.9.0.jar
add_jar "$maven_central" org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.10.0/kotlinx-serialization-core-jvm-1.10.0.jar
add_jar "$maven_central" org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.10.0/kotlinx-serialization-json-jvm-1.10.0.jar

sources=()
while IFS= read -r source; do
    sources[${#sources[@]}]=$source
done < <(find "$repo_root/cross/android" -type f -name '*.kt' | sort)
[[ ${#sources[@]} -gt 0 ]] || fail "no Kotlin sources found"

"$kotlinc" \
    "${sources[@]}" \
    -classpath "$classpath" \
    -Xplugin="$serialization_plugin" \
    -jvm-target 21 \
    -d "$work_dir/classes"
