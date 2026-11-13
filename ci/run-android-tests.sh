#!/bin/bash

set -euo pipefail

fail() {
    echo "run-android-tests.sh: $*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail "usage: $0"
for tool in java curl unzip cc realpath; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

kotlinc=${KOTLINC:-$(command -v kotlinc || true)}
if [[ -z $kotlinc ]]; then
    kotlinc=/Applications/Android\ Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc
fi
[[ -x $kotlinc ]] || fail "missing required tool: kotlinc"

kotlinc=$(realpath "$kotlinc")

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd "$script_dir/.." && pwd -P)
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
android_platform=${ANDROID_PLATFORM:-36}
android_jar="$android_home/platforms/android-$android_platform/android.jar"
[[ -f $android_jar ]] || fail "missing Android platform JAR: $android_jar"

kotlin_home=$(cd "$(dirname "$kotlinc")/.." && pwd -P)
serialization_plugin="$kotlin_home/lib/kotlinx-serialization-compiler-plugin.jar"
if [[ ! -f $serialization_plugin ]]; then
    serialization_plugin="$kotlin_home/lib/kotlin-serialization-compiler-plugin.jar"
fi
[[ -f $serialization_plugin ]] || fail "missing Kotlin serialization compiler plugin"

work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/partout-kotlin.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
dependencies_dir="$work_dir/dependencies"
mkdir -p "$dependencies_dir"

add_dependency() {
    local repository=$1
    local path=$2
    local filename=${path##*/}
    local output="$dependencies_dir/$filename"
    curl --fail --location --silent --show-error "$repository/$path" --output "$output"
    if [[ $path == *.aar ]]; then
        unzip -p "$output" classes.jar > "${output%.aar}.jar"
        output="${output%.aar}.jar"
    fi
    classpath="$classpath:$output"
}

classpath=$android_jar
google_maven=https://dl.google.com/dl/android/maven2
maven_central=https://repo.maven.apache.org/maven2
add_dependency "$google_maven" androidx/core/core/1.16.0/core-1.16.0.aar
add_dependency "$google_maven" androidx/core/core-ktx/1.16.0/core-ktx-1.16.0.aar
add_dependency "$google_maven" androidx/annotation/annotation-experimental/1.4.1/annotation-experimental-1.4.1.aar
add_dependency "$google_maven" androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar
add_dependency "$google_maven" androidx/collection/collection-jvm/1.5.0/collection-jvm-1.5.0.jar
add_dependency "$maven_central" org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.9.0/kotlinx-coroutines-core-jvm-1.9.0.jar
add_dependency "$maven_central" org/jetbrains/kotlinx/kotlinx-serialization-core-jvm/1.10.0/kotlinx-serialization-core-jvm-1.10.0.jar
add_dependency "$maven_central" org/jetbrains/kotlinx/kotlinx-serialization-json-jvm/1.10.0/kotlinx-serialization-json-jvm-1.10.0.jar

"$kotlinc" \
    "$repo_root/cross/android/src" \
    "$repo_root/cross/android/tests/ControllerBindingsTest.kt" \
    -classpath "$classpath" \
    -Xplugin="$serialization_plugin" \
    -jvm-target 21 \
    -d "$work_dir/classes"

# Execute the production C -> Kotlin bindings on the host JVM.
jni_java_home=${JAVA_HOME:-$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^[[:space:]]*java.home = //p')}
case $(uname -s) in
    Darwin) jni_platform=darwin ;;
    Linux) jni_platform=linux ;;
    *) fail "unsupported JNI test host" ;;
esac
# Android exposes AttachCurrentThread with JNIEnv**, while host JDKs use void**.
cc -shared -fPIC -D__ANDROID__ -Wno-incompatible-pointer-types \
    -I"$jni_java_home/include" -I"$jni_java_home/include/$jni_platform" \
    -I"$repo_root/cross/android/tests/host" -I"$repo_root/src" \
    -I"$repo_root/cross/android/native" \
    "$repo_root/cross/android/native/controller.c" \
    "$repo_root/cross/android/native/jni.c" \
    "$repo_root/cross/android/tests/controller_bindings.c" \
    -o "$work_dir/controller-bindings.so"
java -Xcheck:jni -cp "$work_dir/classes:$kotlin_home/lib/kotlin-stdlib.jar" \
    io.partout.ControllerBindingsTest "$work_dir/controller-bindings.so"
