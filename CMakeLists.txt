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

# Include SWON macros
add_subdirectory("vendors/swon")

# FIXME: Forward args to Partout subdirectory
# CMAKE_BUILD_TYPE (inherited from cmd line)
# CMAKE_Swift_COMPILER=${CMAKE_CURRENT_SOURCE_DIR}/scripts/swiftc-wrapper.sh
# CMAKE_TOOLCHAIN_FILE:FILEPATH=${CMAKE_TOOLCHAIN_FILE}
if(DEFINED CMAKE_TOOLCHAIN_FILE)
    list(APPEND PARTOUT_CMAKE_ARGS
        -DCMAKE_Swift_COMPILER=${CMAKE_CURRENT_SOURCE_DIR}/scripts/swiftc-wrapper.sh
        -DCMAKE_TOOLCHAIN_FILE:FILEPATH=${CMAKE_TOOLCHAIN_FILE}
    )
endif()

# All vendor-inherited args
set(VENDOR_DEPENDS)
if(PP_BUILD_USE_OPENSSL)
    include("vendors/openssl.cmake")
    ExternalProject_Get_Property(OpenSSLProject BINARY_DIR)
    list(APPEND VENDOR_DEPENDS OpenSSLProject)
    # Exports OPENSSL_DIR
elseif(PP_BUILD_USE_MBEDTLS)
    include("vendors/mbedtls.cmake")
    ExternalProject_Get_Property(MbedTLSProject BINARY_DIR)
    list(APPEND VENDOR_DEPENDS MbedTLSProject)
    # Exports MBEDTLS_DIR
endif()
if(PP_BUILD_USE_WGGO)
    include("vendors/wg-go.cmake")
    ExternalProject_Get_Property(WireGuardGoProject BINARY_DIR)
    list(APPEND VENDOR_DEPENDS WireGuardGoProject)
    # Exports WGGO_DIR
endif()

# Fetch wintun.dll on Windows
if(WIN32)
    set(WINTUN_VERSION "0.14.1")
    include("vendors/wintun.cmake")
endif()

# Build Partout library (opt-in), after vendored dependencies
if(PP_BUILD_LIBRARY)
    add_subdirectory(Sources)
    add_dependencies(partout_c ${VENDOR_DEPENDS})
    target_link_libraries(partout PRIVATE SWONInterface)
endif()
