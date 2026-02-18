cmake_minimum_required(VERSION 3.27)
project(Partout LANGUAGES Swift C CXX)
include(ExternalProject)
include(FetchContent)

# Command line options
option(PP_BUILD_LIBRARY "Include main library" 0)
option(PP_BUILD_USE_OPENSSL "Use OpenSSL" 0)
option(PP_BUILD_USE_MBEDTLS "Use MbedTLS" 0)
option(PP_BUILD_USE_WGGO "Use WireGuard Go" 0)

# Output per platform/arch
string(TOLOWER ${CMAKE_SYSTEM_NAME} PLATFORM_NAME)
string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} ARCH_NAME)
if(DEFINED PP_BUILD_OUTPUT)
    set(PP_BUILD_OUTPUT_UNIVERSAL "${PP_BUILD_OUTPUT}")
else()
    set(PP_BUILD_OUTPUT_UNIVERSAL "${CMAKE_CURRENT_SOURCE_DIR}/bin")
    set(PP_BUILD_OUTPUT "${PP_BUILD_OUTPUT_UNIVERSAL}/${PLATFORM_NAME}-${ARCH_NAME}")
endif()

# Options
message(STATUS "Option CMAKE_BUILD_TYPE = ${CMAKE_BUILD_TYPE}")
message(STATUS "Option PP_BUILD_LIBRARY = ${PP_BUILD_LIBRARY}")
message(STATUS "Option PP_BUILD_USE_OPENSSL = ${PP_BUILD_USE_OPENSSL}")
message(STATUS "Option PP_BUILD_USE_MBEDTLS = ${PP_BUILD_USE_MBEDTLS}")
message(STATUS "Option PP_BUILD_USE_WGGO = ${PP_BUILD_USE_WGGO}")
message(STATUS "Option PP_BUILD_OUTPUT = ${PP_BUILD_OUTPUT}")

# All vendor-inherited args
if(PP_BUILD_USE_OPENSSL)
    include("vendors/openssl.cmake")
elseif(PP_BUILD_USE_MBEDTLS)
    include("vendors/mbedtls.cmake")
endif()
if(PP_BUILD_USE_WGGO)
    include("vendors/wg-go.cmake")
endif()

# Include SWON macros
add_subdirectory("vendors/swon")

# Fetch wintun.dll on Windows
if(WIN32)
    set(WINTUN_VERSION "0.14.1")
    include("vendors/wintun.cmake")
endif()

# Build Partout library (opt-in), after vendored dependencies
if(PP_BUILD_LIBRARY)
    add_subdirectory(Sources)
    if(PP_BUILD_USE_OPENSSL)
        target_link_libraries(partout_c PUBLIC OpenSSLInterface)
    elseif(PP_BUILD_USE_MBEDTLS)
        target_link_libraries(partout_c PUBLIC MbedTLSInterface)
    endif()
    if(PP_BUILD_USE_WGGO)
        target_link_libraries(partout_c PUBLIC WireGuardGoInterface)
    endif()
    target_link_libraries(partout PUBLIC SWONInterface)
endif()
