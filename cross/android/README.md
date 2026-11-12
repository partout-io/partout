# Local Android library

Include this directory as a module in the consuming application's Gradle build.
The application supplies the Android and Kotlin plugin versions. For example,
use Gradle 9.8.0, AGP 9.2.1, Kotlin serialization plugin 2.3.21, and JDK 17.

In the application's `settings.gradle.kts`:

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.android.application") version "9.2.1"
        id("com.android.library") version "9.2.1"
        id("org.jetbrains.kotlin.plugin.serialization") version "2.3.21"
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
include(":app", ":partout")
project(":partout").projectDir = file("../partout/cross/android")
```

Merge these declarations into existing settings and use consistent plugin
versions throughout the build. Adjust the checkout path for your app.
Set `android.useAndroidX=true` in the application's `gradle.properties`.

In `app/build.gradle.kts`:

```kotlin
dependencies {
    implementation(project(":partout"))
}
```

Install Android SDK platform 36, the NDK selected by AGP, and CMake 3.28 or newer,
and put the
repository's supported Zig compiler (see `build.zig.zon`) on PATH before starting
Gradle/Android Studio. Set the SDK location in the application's local.properties
or ANDROID_HOME. Then run `./gradlew :partout:assembleDebug` from the app.

Partout leaves the NDK version to AGP by default. The consuming build can configure
the `:partout` module's `android.ndkVersion` directly when needed. The app module's
own NDK setting is independent and is not inherited by Partout.

The module builds arm64-v8a, requires API 24, and packages Kotlin,
`libpartout-jni.so`, and the linked `libpartout.so`. Load the JNI library with:

```kotlin
val wrapper = io.partout.PartoutWrapper()
```

The application owns its VpnService, manifest declarations, VPN consent, and
service lifecycle. The library manifest deliberately declares no service.
Consumer rules preserve JNI entry points and callbacks when the app uses R8.

Protocol and crypto backends retain the root CMake defaults (disabled). To enable
features, configure this module's `android.defaultConfig.externalNativeBuild.cmake`
arguments, for example `-DPP_BUILD_USE_OPENVPN=ON` together with a crypto backend
and its Android vendor package. WireGuard additionally requires the Go toolchain.
The existing vendor download fallback supports only arm64-v8a; when using it,
restrict this module's ABI filters accordingly. Native outputs are isolated per
Gradle variant and ABI. Do not also copy these libraries into app jniLibs.

This is a local project dependency; no publishing setup or Maven coordinates are
provided. Gradle still uses repositories to resolve Android/Kotlin tooling and
third-party dependencies.

The module uses AGP 9 built-in Kotlin support.
