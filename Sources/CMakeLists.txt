cmake_minimum_required(VERSION 3.27)
project(PartoutProject LANGUAGES Swift C)

# Package root is up one level, output dir from option
set(ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/..)

# Partout_C ############################################

# Base configuration
add_library(partout_c STATIC "")
target_compile_options(partout_c PRIVATE
    -DPARTOUT_MONOLITH
    -DPARTOUT_FOUNDATION_COMPAT
)

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutABI_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCore_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutOpenVPN_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutWireGuard_C/include
)
if(WIN32)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${PP_BUILD_OUTPUT}/wintun)
endif()

# Set up exclusions
set(EXCLUDED_PATTERNS "")

# Filter by crypto vendor
if(DEFINED OPENSSL_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCrypto/OpenSSL_C/include)
else()
    list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/OpenSSL_C\/)
endif()
if(DEFINED MBEDTLS_DIR)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCrypto/Native_C/include)
    if(NOT APPLE)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/apple)
    endif()
    if(NOT LINUX)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/linux)
    endif()
    if(NOT WIN32)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/windows)
    endif()
    if(NOT ANDROID)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/android)
    endif()
else()
    list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/)
endif()

# C sources
file(GLOB_RECURSE PARTOUT_C_SOURCES *.c)

# Account for exclusions in source files
foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Add computed files
target_sources(partout_c PRIVATE ${PARTOUT_C_SOURCES})
target_include_directories(partout_c PRIVATE ${PARTOUT_C_INCLUDE_DIRS})
if(LINUX)
    target_compile_options(partout_c PRIVATE -fPIC)
endif()

# Partout_Swift ########################################

# Partout library base configuration
if(LINUX OR ANDROID)
    set(DYNLIBS 1)
    add_library(partout SHARED "")
else()
    add_library(partout STATIC "")
endif()

# Define symbols to skip Swift imports and legacy code
target_compile_options(partout PRIVATE
    -DPARTOUT_MONOLITH
    -DPARTOUT_OPENVPN
    -DPARTOUT_WIREGUARD
    -enable-library-evolution
)

# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    *.swift
)

set(EXCLUDED_PATTERNS
    # TODO: #228, Exclude Foundation replacements until done
    PartoutFoundation\/Compat
)

# Exclude Swift implementations on non-Apple
if(NOT APPLE)
    list(APPEND EXCLUDED_PATTERNS PartoutOS\/Apple.*)
endif()

foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Look for modulemaps in C "include" dirs
foreach(dir ${PARTOUT_C_INCLUDE_DIRS})
    target_include_directories(partout PRIVATE ${dir})
endforeach()

# Depend on C target (include before)
add_dependencies(partout partout_c)
target_sources(partout PRIVATE ${PARTOUT_SOURCES})
target_link_libraries(partout PRIVATE partout_c)
target_compile_options(partout PRIVATE
    -emit-module-interface
)

################################################

# Set overall output properties
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    Swift_MODULE_NAME "Partout"
    Swift_MODULE_DIRECTORY "${OUTPUT_DIR}/modules"
)
set_target_properties(partout_c PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
)

# Link to vendor-specific dependencies
if(DEFINED OPENSSL_DIR)
    target_include_directories(partout_c PRIVATE ${OPENSSL_DIR}/include)
    target_link_directories(partout_c PRIVATE ${OPENSSL_DIR}/lib)
    if(DYNLIBS)
        target_link_libraries(partout_c
            ${OPENSSL_DIR}/lib/libssl.so
            ${OPENSSL_DIR}/lib/libcrypto.so
        )
    else()
        target_link_libraries(partout_c ssl crypto)
    endif()
elseif(DEFINED MBEDTLS_DIR)
    target_include_directories(partout_c PRIVATE ${MBEDTLS_DIR}/include)
    target_link_directories(partout_c PRIVATE ${MBEDTLS_DIR}/lib)
    if(DYNLIBS)
        target_link_libraries(partout_c
            ${MBEDTLS_DIR}/lib/libmbedx509.so
            ${MBEDTLS_DIR}/lib/libmbedtls.so
            ${MBEDTLS_DIR}/lib/libmbedcrypto.so
        )
    else()
        target_link_libraries(partout_c mbedcrypto mbedtls mbedx509)
    endif()
endif()
if(DEFINED WGGO_DIR)
    target_include_directories(partout_c PRIVATE
        ${WGGO_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/PartoutWireGuard/Shared_C/include
    )
    target_link_directories(partout_c PRIVATE ${WGGO_DIR}/lib)
    if(DYNLIBS)
        target_link_libraries(partout_c
            ${WGGO_DIR}/lib/libwg-go.so
        )
    else()
        target_link_libraries(partout_c wg-go)
    endif()
endif()

# Copy ABI header
set(ABI_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/PartoutABI_C/include)
add_custom_command(
    TARGET partout
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy ${ABI_INCLUDE}/partout.h ${OUTPUT_DIR}
    COMMAND ${CMAKE_COMMAND} -E copy ${ABI_INCLUDE}/module.modulemap ${OUTPUT_DIR}
)

if(WIN32)
    set_target_properties(partout_c PROPERTIES PREFIX "lib")
    set_target_properties(partout PROPERTIES PREFIX "lib")
elseif(LINUX)
    set_target_properties(partout PROPERTIES
        BUILD_RPATH "\$ORIGIN"
        INSTALL_RPATH "\$ORIGIN"
        SKIP_BUILD_RPATH OFF
    )
endif()
