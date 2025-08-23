# C/C++ sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_C_SOURCES
    ${PARTOUT_CORE_C_SOURCES_DIR}/*.c
    ${PARTOUT_DIR}/Sources/*.c
    ${PARTOUT_DIR}/Sources/*.cc
    ${PARTOUT_DIR}/Sources/*.cpp
)

# Set up exclusions
set(EXCLUDED_PATTERNS
    # FIXME: #118, restore WireGuard when properly integrated
    PartoutWireGuard\/
    Vendors\/WireGuardGo\/
)

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${PARTOUT_CORE_C_INCLUDE_DIR}
    ${PARTOUT_DIR}/Sources/OS/Portable_C/include
    ${PARTOUT_DIR}/Sources/PartoutOpenVPN/Cross_C/include
)

# Filter by platform
if(NOT APPLE)
    list(APPEND EXCLUDED_PATTERNS OS\/Apple.*)
endif()
if(NOT LINUX)
    list(APPEND EXCLUDED_PATTERNS OS\/Linux.*)
endif()
if(NOT WIN32)
    list(APPEND EXCLUDED_PATTERNS OS\/Windows.*)
endif()
# XXX: Not sure about this condition
if(NOT BUILD_FOR_ANDROID)
    list(APPEND EXCLUDED_PATTERNS OS\/Android.*)
endif()

# Filter by crypto vendor
if(DEFINED OPENSSL_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${PARTOUT_DIR}/Sources/Impl/CryptoOpenSSL_C/include)
else()
    list(APPEND EXCLUDED_PATTERNS CryptoOpenSSL_C\/)
endif()
if(DEFINED MBEDTLS_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${PARTOUT_DIR}/Sources/Impl/CryptoNative_C/include)
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
