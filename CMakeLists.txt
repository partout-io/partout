cmake_minimum_required(VERSION 3.28)
# Select per-target MSVC runtime checks before enabling any languages.
if(POLICY CMP0184)
    cmake_policy(SET CMP0184 NEW)
endif()
project(Partout LANGUAGES C)

option(PP_BUILD_LIBRARY "Build the Partout library" ON)
option(PP_BUILD_USE_OPENSSL "Enable the OpenSSL backend" OFF)
option(PP_BUILD_USE_MBEDTLS "Enable the MbedTLS backend" OFF)
option(PP_BUILD_USE_OPENVPN "Enable OpenVPN" OFF)
option(PP_BUILD_USE_WIREGUARD "Enable WireGuard" OFF)

include("cmake/platform.cmake")
include("cmake/winrt.cmake")
include("cmake/zig.cmake")
include("cmake/install.cmake")
