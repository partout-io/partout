cmake_minimum_required(VERSION 3.28)
# Select per-target MSVC runtime checks before enabling any languages.
if(POLICY CMP0184)
    cmake_policy(SET CMP0184 NEW)
endif()
project(Partout LANGUAGES C)
include(GNUInstallDirs)

option(PP_BUILD_LIBRARY "Build the Partout library" ON)
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

include("cmake/windows.cmake")
include("cmake/vendors.cmake")
include("cmake/core.cmake")
include("cmake/runtimes.cmake")
include("cmake/install.cmake")
