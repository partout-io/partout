# C/C++ sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_C_SOURCES
    ${PARTOUT_CORE_C_SOURCES_DIR}/*.c
    ${PARTOUT_DIR}/Sources/*.c
    ${PARTOUT_DIR}/Sources/*.cc
    ${PARTOUT_DIR}/Sources/*.cpp
)

# Set up exclusions
set(EXCLUDED_PATTERNS
    # FIXME: #118, WireGuard excluded until properly integrated
    WireGuard\/
)

# Filter by platform
# FIXME: #173, exclude Windows regardless for now
#if (NOT WIN32)
    list(APPEND EXCLUDED_PATTERNS Crypto\/CryptoWindows_C\/)
#endif()
if (NOT DEFINED OPENSSL_DIR)
    list(APPEND EXCLUDED_PATTERNS Crypto\/.*OpenSSL_C\/)
endif()
if (NOT DEFINED MBEDTLS_DIR)
    list(APPEND EXCLUDED_PATTERNS Crypto\/.*MbedTLS_C\/)
endif()

foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${PARTOUT_CORE_C_INCLUDE_DIR}
    ${PARTOUT_DIR}/Sources/Crypto/CryptoCore_C/include
    ${PARTOUT_DIR}/Sources/Crypto/TLSCore_C/include
    ${PARTOUT_DIR}/Sources/OpenVPN/Cross_C/include
    ${PARTOUT_DIR}/Sources/Vendors/Portable_C/include
)

# Define Partout_C sub-target for Partout
add_library(Partout_C STATIC
    ${PARTOUT_C_SOURCES}
)
target_include_directories(Partout_C PRIVATE
    ${PARTOUT_C_INCLUDE_DIRS}
)
if (LINUX)
    target_compile_options(Partout_C PRIVATE -fPIC)
endif()
