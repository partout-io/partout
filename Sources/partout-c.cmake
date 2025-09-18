set(ROOT_DIR ${CMAKE_SOURCE_DIR}/..)

# Base configuration
add_library(Partout_C STATIC "")
target_compile_options(Partout_C PRIVATE
    -DPARTOUT_MONOLITH
    -DOPENVPN_DEPRECATED_LZO
)

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${ROOT_DIR}/vendors/core/Sources/_PartoutCore_C/include
    ${ROOT_DIR}/vendors/lzo/include
    ${CMAKE_SOURCE_DIR}/Partout_C/include
    ${CMAKE_SOURCE_DIR}/PartoutOS_C/include
    ${CMAKE_SOURCE_DIR}/PartoutOpenVPN_C/include
    ${CMAKE_SOURCE_DIR}/PartoutWireGuard_C/include
)
if(WIN32)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${ROOT_DIR}/vendors/wintun)
endif()

# Set up exclusions
set(EXCLUDED_PATTERNS "")

# Filter by crypto vendor
if(DEFINED OPENSSL_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/PartoutCrypto/OpenSSL_C/include)
else()
    list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/OpenSSL_C\/)
endif()
if(DEFINED MBEDTLS_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/PartoutCrypto/Native_C/include)
    if(NOT APPLE)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/apple)
    endif()
    if(NOT LINUX)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/linux)
    endif()
    if(NOT WIN32)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/windows)
    endif()
    # XXX: Not sure about this condition
    if(NOT BUILD_FOR_ANDROID)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/android)
    endif()
else()
    list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/)
endif()

# C sources, including vendored PartoutCore and LZO
file(GLOB_RECURSE PARTOUT_C_SOURCES
    ${ROOT_DIR}/vendors/core/Sources/_PartoutCore_C/*.c
    ${ROOT_DIR}/vendors/lzo/*.c
    *.c
)

# Account for exclusions in source files
foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Add computed files
target_sources(Partout_C PRIVATE ${PARTOUT_C_SOURCES})
target_include_directories(Partout_C PRIVATE ${PARTOUT_C_INCLUDE_DIRS})
if(LINUX)
    target_compile_options(Partout_C PRIVATE -fPIC)
endif()
