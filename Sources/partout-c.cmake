set(ROOT_DIR ${CMAKE_SOURCE_DIR}/..)

# C/C++ sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_C_SOURCES
    ${ROOT_DIR}/vendors/core/Sources/_PartoutCore_C/*.c
    *.c
)

# Set up exclusions
set(EXCLUDED_PATTERNS "")

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${ROOT_DIR}/vendors/core/Sources/_PartoutCore_C/include
    ${CMAKE_SOURCE_DIR}/Partout_C/include
    ${CMAKE_SOURCE_DIR}/OS/Portable_C/include
    ${CMAKE_SOURCE_DIR}/PartoutOpenVPN/Cross_C/include
    ${CMAKE_SOURCE_DIR}/PartoutWireGuard/Interfaces_C
    ${CMAKE_SOURCE_DIR}/Vendors/WireGuard_C/include
)

# Filter by platform
if(NOT APPLE)
    list(APPEND EXCLUDED_PATTERNS OS\/Apple.*)
endif()
if(NOT LINUX)
    list(APPEND EXCLUDED_PATTERNS OS\/Linux.*)
endif()
if(WIN32)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${ROOT_DIR}/vendors/wintun)
else()
    list(APPEND EXCLUDED_PATTERNS
        test-wintun.*
        OS\/Windows.*
    )
endif()
# XXX: Not sure about this condition
if(NOT BUILD_FOR_ANDROID)
    list(APPEND EXCLUDED_PATTERNS OS\/Android.*)
endif()

# Filter by crypto vendor
if(DEFINED OPENSSL_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/Impl/CryptoOpenSSL_C/include)
else()
    list(APPEND EXCLUDED_PATTERNS CryptoOpenSSL_C\/)
endif()
if(DEFINED MBEDTLS_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/Impl/CryptoNative_C/include)
    if(NOT APPLE)
        list(APPEND EXCLUDED_PATTERNS CryptoNative_C\/src/apple)
    endif()
    if(NOT LINUX)
        list(APPEND EXCLUDED_PATTERNS CryptoNative_C\/src/linux)
    endif()
    if(NOT WIN32)
        list(APPEND EXCLUDED_PATTERNS CryptoNative_C\/src/windows)
    endif()
    # XXX: Not sure about this condition
    if(NOT BUILD_FOR_ANDROID)
        list(APPEND EXCLUDED_PATTERNS CryptoNative_C\/src/android)
    endif()
else()
    list(APPEND EXCLUDED_PATTERNS CryptoNative_C\/)
endif()

foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Define Partout_C sub-target for Partout
add_library(Partout_C STATIC
    ${PARTOUT_C_SOURCES}
)
target_include_directories(Partout_C PRIVATE
    ${PARTOUT_C_INCLUDE_DIRS}
)
if(LINUX)
    target_compile_options(Partout_C PRIVATE -fPIC)
endif()
