if(NOT PP_BUILD_LIBRARY)
    return()
endif()

if(WIN32 AND NOT MSVC)
    message(FATAL_ERROR "The Windows core DLL requires MSVC")
endif()
set(PARTOUT_ZIG_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/zig-core/$<CONFIG>")

# Build options and enabled backends.
set(PARTOUT_ZIG_ARGS build install
    --prefix "${PARTOUT_ZIG_PREFIX}"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dstrip=$<IF:$<CONFIG:Debug,RelWithDebInfo>,false,true>"
)

if(PP_BUILD_USE_OPENSSL)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE_DIR}"
    )
    if(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR)
        list(APPEND PARTOUT_ZIG_ARGS
            "-Dopenssl-config-include=${PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR}"
        )
    endif()
endif()

if(PP_BUILD_USE_MBEDTLS)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE_DIR}"
    )
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${wg_source}/include"
    )
endif()

# Target architecture, SDK, and libc.
set(PARTOUT_ZIG_ARCH "${ARCH_NAME}")
if(PARTOUT_ZIG_ARCH MATCHES "^(arm64|aarch64)$")
    set(PARTOUT_ZIG_ARCH aarch64)
elseif(PARTOUT_ZIG_ARCH MATCHES "^(x64|x86_64|amd64)$")
    set(PARTOUT_ZIG_ARCH x86_64)
endif()

if(ANDROID)
    string(REGEX REPLACE "^android-" "" PARTOUT_ANDROID_API "${ANDROID_PLATFORM}")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-android.${PARTOUT_ANDROID_API}")
    set(PARTOUT_ZIG_LIBC "${CMAKE_CURRENT_BINARY_DIR}/android.libc")
    file(WRITE "${PARTOUT_ZIG_LIBC}"
        "include_dir=${CMAKE_SYSROOT}/usr/include
sys_include_dir=${CMAKE_SYSROOT}/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}
crt_dir=${CMAKE_SYSROOT}/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}/${PARTOUT_ANDROID_API}
msvc_lib_dir=
kernel32_lib_dir=
cc_dir=${CMAKE_SYSROOT}/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}/${PARTOUT_ANDROID_API}
darwin_sdk_dir=
"
    )
    list(APPEND PARTOUT_ZIG_ARGS "-Dlibc-file=${PARTOUT_ZIG_LIBC}")
elseif(APPLE)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(PARTOUT_APPLE_OS ios)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        set(PARTOUT_APPLE_OS tvos)
    else()
        set(PARTOUT_APPLE_OS macos)
    endif()
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-${PARTOUT_APPLE_OS}")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        string(APPEND PARTOUT_ZIG_TARGET ".${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        string(APPEND PARTOUT_ZIG_TARGET "-simulator")
    endif()
    list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(PP_BUILD_WINRT)
    list(APPEND PARTOUT_ZIG_ARGS -Dwinrt=true)
elseif(PP_BUILD_WINTUN)
    list(APPEND PARTOUT_ZIG_ARGS -Dwintun=true)
endif()
# Zig compiles the static core; CMake owns the final shared library.
find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
set(PARTOUT_ZIG_LIBRARY "${PARTOUT_ZIG_PREFIX}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}partout${CMAKE_STATIC_LIBRARY_SUFFIX}")
# Let Zig track transitive Zig/C/SDK inputs and reuse its build cache. A CMake
# source-only stamp would miss dependencies discovered by Zig.
add_custom_target(partout-zig ALL
    COMMAND "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
    BYPRODUCTS ${PARTOUT_ZIG_LIBRARY}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMAND_EXPAND_LISTS
    VERBATIM
)
