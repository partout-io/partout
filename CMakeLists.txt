cmake_minimum_required(VERSION 3.28)
# Select per-target MSVC runtime checks before enabling any languages.
if(POLICY CMP0184)
    cmake_policy(SET CMP0184 NEW)
endif()
project(Partout LANGUAGES C)
include(GNUInstallDirs)

option(PP_BUILD_LIBRARY "Build the Partout library" ON)
option(PP_BUILD_CPP "Build the portable C++ runtime" OFF)
option(PP_BUILD_WINRT "Build the WinRT VpnChannel runtime" OFF)
option(PP_BUILD_WINTUN "Build the Wintun/Winsock runtime" OFF)
if(PP_BUILD_WINRT OR PP_BUILD_WINTUN)
    set(PP_BUILD_CPP ON)
endif()
if(APPLE AND PP_BUILD_CPP)
    message(FATAL_ERROR "The C++ runtime is not supported on Apple platforms; set PP_BUILD_CPP=OFF")
endif()
if(WIN32 AND NOT PP_BUILD_WINRT AND NOT PP_BUILD_WINTUN)
    message(FATAL_ERROR "Windows builds require either PP_BUILD_WINRT or PP_BUILD_WINTUN")
endif()
if(NOT WIN32 AND (PP_BUILD_WINRT OR PP_BUILD_WINTUN))
    message(FATAL_ERROR "WinRT and Wintun require Windows")
endif()
if(PP_BUILD_WINRT AND PP_BUILD_WINTUN)
    messague(FATAL_ERROR "PP_BUILD_WINRT and PP_BUILD_WINTUN are mutually exclusive")
endif()
option(PP_BUILD_USE_OPENSSL "Enable the OpenSSL backend" OFF)
option(PP_BUILD_USE_MBEDTLS "Enable the MbedTLS backend" OFF)
option(PP_BUILD_USE_OPENVPN "Enable OpenVPN" OFF)
option(PP_BUILD_USE_WIREGUARD "Enable WireGuard" OFF)

# Platform identity and output layout.
string(TOLOWER "${CMAKE_SYSTEM_NAME}" PLATFORM_NAME)
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ARCH_NAME)
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    set(ARCH_NAME "${CMAKE_OSX_ARCHITECTURES}")
    list(LENGTH CMAKE_OSX_ARCHITECTURES architecture_count)
    if(NOT architecture_count EQUAL 1)
        message(FATAL_ERROR "Build one Apple architecture per CMake configuration")
    endif()
endif()
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

# Multi-config generators must not overwrite another configuration's runtimes.
get_property(partout_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
set(PARTOUT_OUTPUT_CONFIG "")
if(partout_multi_config)
    set(PARTOUT_OUTPUT_CONFIG "$<CONFIG>/")
endif()

# Distribute as SDK only if built as top level project.
set(partout_install_sdk ${PROJECT_IS_TOP_LEVEL})

# Resolve the Apple SDK once for both Zig and the Go bridge.
if(APPLE)
    if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
        set(PARTOUT_APPLE_SDK "${CMAKE_OSX_SYSROOT}")
    else()
        set(apple_sdk macosx)
        if(CMAKE_OSX_SYSROOT)
            set(apple_sdk "${CMAKE_OSX_SYSROOT}")
        endif()
        execute_process(COMMAND xcrun --sdk "${apple_sdk}" --show-sdk-path
            OUTPUT_VARIABLE PARTOUT_APPLE_SDK OUTPUT_STRIP_TRAILING_WHITESPACE
            COMMAND_ERROR_IS_FATAL ANY)
    endif()
endif()

# Public C ABI headers are available even when the native library is disabled.
add_library(partout-headers INTERFACE)
add_library(Partout::Headers ALIAS partout-headers)
target_include_directories(partout-headers INTERFACE
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")

include("cmake/vendors.cmake")
include("cmake/core.cmake")
include("cmake/runtimes.cmake")
include("cmake/exports.cmake")
include("cmake/install.cmake")
include("cmake/tests.cmake")
