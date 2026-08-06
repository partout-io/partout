cmake_minimum_required(VERSION 3.28)
project(Partout LANGUAGES C)

include(GNUInstallDirs)
include("cmake/prebuilt.cmake")

option(PP_BUILD_STATIC "Build Partout as a static library" OFF)
option(PP_BUILD_LIBRARY "Build the Partout library" ON)
option(PP_BUILD_USE_OPENSSL "Enable the OpenSSL backend" OFF)
option(PP_BUILD_USE_MBEDTLS "Enable the MbedTLS backend" OFF)
option(PP_BUILD_USE_OPENVPN "Enable OpenVPN" OFF)
option(PP_BUILD_USE_WIREGUARD "Enable WireGuard" OFF)

string(TOLOWER "${CMAKE_SYSTEM_NAME}" PLATFORM_NAME)
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ARCH_NAME)
if(WIN32)
    if(CMAKE_C_COMPILER_ARCHITECTURE_ID)
        string(TOLOWER "${CMAKE_C_COMPILER_ARCHITECTURE_ID}" ARCH_NAME)
    elseif(DEFINED ENV{VSCMD_ARG_TGT_ARCH})
        string(TOLOWER "$ENV{VSCMD_ARG_TGT_ARCH}" ARCH_NAME)
    endif()
    if(ARCH_NAME MATCHES "^(x64|x86_64|amd64)(-|$)")
        set(ARCH_NAME amd64)
    elseif(ARCH_NAME MATCHES "^(arm64|aarch64)(-|$)")
        set(ARCH_NAME arm64)
    endif()
endif()

set(PP_BUILD_OUTPUT "${CMAKE_CURRENT_SOURCE_DIR}/bin/${PLATFORM_NAME}-${ARCH_NAME}"
    CACHE PATH "Build output directory")
file(TO_CMAKE_PATH "${PP_BUILD_OUTPUT}" PP_BUILD_OUTPUT)
set(PP_BUILD_PREFIX "${PP_BUILD_OUTPUT}/partout" CACHE PATH "Partout install prefix")
file(TO_CMAKE_PATH "${PP_BUILD_PREFIX}" PP_BUILD_PREFIX)

if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PP_SYSTEM_VENDORS_AVAILABLE ON)
else()
    set(PP_SYSTEM_VENDORS_AVAILABLE OFF)
endif()

set(PKG_CONFIG_USE_CMAKE_PREFIX_PATH ON)
if(APPLE AND PP_SYSTEM_VENDORS_AVAILABLE)
    find_program(HOMEBREW_EXECUTABLE brew)
endif()

function(partout_use_homebrew_formula formula)
    if(NOT HOMEBREW_EXECUTABLE)
        return()
    endif()
    execute_process(
        COMMAND "${HOMEBREW_EXECUTABLE}" --prefix "${formula}"
        RESULT_VARIABLE result
        OUTPUT_VARIABLE prefix
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(result EQUAL 0)
        list(PREPEND CMAKE_PREFIX_PATH "${prefix}")
        set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
    endif()
endfunction()

if(WIN32)
    set(MAKE_CMD nmake)
else()
    set(MAKE_CMD make)
endif()
if(CMAKE_CONFIGURATION_TYPES)
    set(PP_BUILD_CONFIG_ARGS --config $<CONFIG>)
endif()

if(ANDROID)
    file(GLOB android_toolchains "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/*")
    list(GET android_toolchains 0 android_toolchain)
    if(CMAKE_HOST_WIN32)
        set(VENDOR_PATH "${android_toolchain}/bin;$ENV{PATH}")
        string(REPLACE ";" "\\;" VENDOR_PATH "${VENDOR_PATH}")
    else()
        set(VENDOR_PATH "${android_toolchain}/bin:$ENV{PATH}")
    endif()
    set(VENDOR_ENV "${CMAKE_COMMAND}" -E env "PATH=${VENDOR_PATH}")
endif()

set(PARTOUT_ZIG_ARGS build install
    --prefix "${PP_BUILD_PREFIX}"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dshared=$<IF:$<BOOL:${PP_BUILD_STATIC}>,false,true>"
)
set(PARTOUT_ZIG_DEPENDS)

if(PP_BUILD_USE_OPENSSL)
    include("cmake/dependencies/openssl.cmake")
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE_DIR}"
        "-Dopenssl-lib=${PARTOUT_OPENSSL_LIBRARY_DIR}"
    )
    if(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR)
        list(APPEND PARTOUT_ZIG_ARGS
            "-Dopenssl-config-include=${PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR}"
        )
    endif()
    list(APPEND PARTOUT_ZIG_DEPENDS ${PARTOUT_OPENSSL_DEPENDENCY})
endif()

if(PP_BUILD_USE_MBEDTLS)
    include("cmake/dependencies/mbedtls.cmake")
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE_DIR}"
        "-Dmbedtls-lib=${PARTOUT_MBEDTLS_LIBRARY_DIR}"
    )
    list(APPEND PARTOUT_ZIG_DEPENDS ${PARTOUT_MBEDTLS_DEPENDENCY})
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    include("cmake/dependencies/wg-go.cmake")
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${PARTOUT_WGGO_INCLUDE_DIR}"
        "-Dwg-go-lib=${PARTOUT_WGGO_LIBRARY_DIR}"
    )
    list(APPEND PARTOUT_ZIG_DEPENDS ${PARTOUT_WGGO_DEPENDENCY})
endif()

if(WIN32 AND PP_BUILD_LIBRARY AND PP_BUILD_WINTUN_PREBUILT_URL)
    include("cmake/dependencies/wintun.cmake")
    list(APPEND PARTOUT_ZIG_ARGS "-Dwintun-include=${WINTUN_DIR}")
endif()

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
gcc_dir=
")
    list(APPEND PARTOUT_ZIG_ARGS --libc "${PARTOUT_ZIG_LIBC}")
elseif(APPLE)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-macos")
    if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
        set(PARTOUT_APPLE_SDK "${CMAKE_OSX_SYSROOT}")
    else()
        execute_process(
            COMMAND xcrun --sdk macosx --show-sdk-path
            OUTPUT_VARIABLE PARTOUT_APPLE_SDK
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
    endif()
    if(PARTOUT_APPLE_SDK)
        list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
    endif()
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(PP_BUILD_LIBRARY)
    find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
    add_custom_target(partout ALL
        COMMAND "${CMAKE_COMMAND}" -E chdir "${CMAKE_CURRENT_SOURCE_DIR}/zig"
            "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
        DEPENDS ${PARTOUT_ZIG_DEPENDS}
        USES_TERMINAL
        COMMAND_EXPAND_LISTS
        VERBATIM
    )
endif()

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

function(partout_install_runtime_file file)
    install(FILES "${file}"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        OPTIONAL
    )
endfunction()

function(partout_install_runtime_directory directory)
    if(WIN32)
        set(runtime_patterns PATTERN "*.dll")
    elseif(APPLE)
        set(runtime_patterns PATTERN "*.dylib")
    else()
        set(runtime_patterns PATTERN "*.so" PATTERN "*.so.*")
    endif()
    install(DIRECTORY "${directory}/"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        OPTIONAL
        USE_SOURCE_PERMISSIONS
        FILES_MATCHING
        ${runtime_patterns}
    )
endfunction()

if(WIN32)
    set(PARTOUT_RUNTIME_LIBRARY "${PP_BUILD_PREFIX}/bin/partout.dll")
    if(WINTUN_DIR)
        partout_install_runtime_file("${PP_BUILD_PREFIX}/bin/wintun.dll")
    endif()
else()
    set(PARTOUT_RUNTIME_LIBRARY
        "${PP_BUILD_PREFIX}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()
partout_install_runtime_file("${PARTOUT_RUNTIME_LIBRARY}")
if(PP_BUILD_USE_WIREGUARD)
    partout_install_runtime_file("${WGGO_RUNTIME_LIBRARY}")
endif()
if(PARTOUT_OPENSSL_IS_PREBUILT)
    partout_install_runtime_directory("${OPENSSL_DIR}/bin")
    partout_install_runtime_directory("${OPENSSL_DIR}/lib")
endif()
if(PARTOUT_MBEDTLS_IS_PREBUILT)
    partout_install_runtime_directory("${MBEDTLS_DIR}/bin")
    partout_install_runtime_directory("${MBEDTLS_DIR}/lib")
endif()
