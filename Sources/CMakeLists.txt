# Package root is up one level, output dir from option
set(ROOT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/..)
set(OUTPUT_DIR ${PP_BUILD_OUTPUT}/partout)

# Include file lists
include("files.cmake")

# Header search paths from all C targets
set(PARTOUT_C_INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}/MiniFoundation_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/Partout_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCore_C/include
    ${CMAKE_CURRENT_SOURCE_DIR}/PartoutWireGuard_C/include
)
if(WIN32)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${PP_BUILD_OUTPUT}/wintun)
endif()

# Set up exclusions
set(EXCLUDED_PATTERNS "")

# Filter by crypto vendor
set(HAS_CRYPTO OFF)
if(PP_BUILD_USE_OPENSSL)
    set(HAS_CRYPTO ON)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCrypto/OpenSSL_C/include)
    if(NOT PP_BUILD_USE_MBEDTLS)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/)
    endif()
endif()
if(PP_BUILD_USE_MBEDTLS)
    set(HAS_CRYPTO ON)
    list(APPEND PARTOUT_C_INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/PartoutCrypto/Native_C/include)
    if(NOT PP_BUILD_USE_OPENSSL)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/OpenSSL_C\/)
    endif()
    if(NOT APPLE)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/darwin)
    endif()
    if(NOT LINUX AND NOT ANDROID)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/linux)
    endif()
    if(NOT WIN32)
        list(APPEND EXCLUDED_PATTERNS PartoutCrypto\/Native_C\/src/windows)
    endif()
endif()
if(NOT HAS_CRYPTO)
    list(APPEND EXCLUDED_PATTERNS PartoutCrypto)
endif()

# Filter by VPN support
if(PP_BUILD_USE_OPENVPN)
    if(NOT HAS_CRYPTO)
        message(FATAL_ERROR "OpenVPN requires a crypto vendor")
    endif()
    list(APPEND PARTOUT_C_INCLUDE_DIRS
        ${CMAKE_CURRENT_SOURCE_DIR}/PartoutOpenVPN_C/include
    )
else()
    list(APPEND EXCLUDED_PATTERNS
        PartoutOpenVPN\/
        PartoutOpenVPN_C\/
    )
endif()
if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_C_INCLUDE_DIRS
        ${CMAKE_CURRENT_SOURCE_DIR}/PartoutWireGuardBackend_C/include
    )
else()
    list(APPEND EXCLUDED_PATTERNS
        PartoutWireGuard\/
        PartoutWireGuardBackend_C\/
    )
endif()

# Exclude legacy connections
list(APPEND EXCLUDED_PATTERNS
    [=[PartoutOpenVPN/OpenVPNConnection[+]Alias[.]swift$]=]
    PartoutOpenVPN\/V2
    [=[PartoutWireGuard/WireGuardConnection[+]Alias[.]swift$]=]
    PartoutWireGuard\/V1
)

# Use Foundation on Apple, compatible otherwise
if(NOT APPLE)
    set(USE_COMPAT ON)
    list(APPEND EXCLUDED_PATTERNS
        PartoutOS\/Apple.*
    )
endif()

# Partout_C ############################################

# Base configuration
add_library(partout_c STATIC "")
target_compile_options(partout_c PRIVATE
    -DUSE_CMAKE
)

# Apply exclusions
foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Add computed files
target_sources(partout_c PRIVATE ${PARTOUT_C_SOURCES})
target_include_directories(partout_c PRIVATE ${PARTOUT_C_INCLUDE_DIRS})
if(LINUX OR ANDROID)
    target_compile_options(partout_c PRIVATE -fPIC)
endif()

# Partout_Swift ########################################

# Partout library base configuration
if(PP_BUILD_STATIC)
    add_library(partout STATIC "")
else()
    add_library(partout SHARED "")
endif()
add_library(Partout::partout ALIAS partout)

# Define symbols to skip Swift imports and legacy code
target_compile_options(partout PRIVATE
    -DUSE_CMAKE
)

# Exclude Foundation if compatibility is on
if(USE_COMPAT)
    target_compile_options(partout PRIVATE
        -DMINIF_COMPAT
    )
endif()

# Apply exclusions
foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Look up internal partout_c modulemaps while building
foreach(dir ${PARTOUT_C_INCLUDE_DIRS})
    target_include_directories(partout PRIVATE ${dir})
endforeach()

# Look up public headers
set(PARTOUT_C_API_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/Partout_C/include/partout.h")
target_include_directories(partout PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Partout_C/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

# Depend on C target (include before)
add_dependencies(partout partout_c)

# Make partout.h an explicit Swift input, so Ninja reinvokes swiftc when the C ABI changes.
set(PARTOUT_C_HEADER_DEPENDENCY_SWIFT "${CMAKE_CURRENT_BINARY_DIR}/PartoutCHeaderDependency.swift")
add_custom_command(
    OUTPUT "${PARTOUT_C_HEADER_DEPENDENCY_SWIFT}"
    COMMAND "${CMAKE_COMMAND}" -E touch "${PARTOUT_C_HEADER_DEPENDENCY_SWIFT}"
    DEPENDS "${PARTOUT_C_API_HEADER}"
    VERBATIM
)
set_source_files_properties("${PARTOUT_C_HEADER_DEPENDENCY_SWIFT}" PROPERTIES GENERATED TRUE)
target_sources(partout
    PRIVATE
        ${PARTOUT_SOURCES}
        "${PARTOUT_C_HEADER_DEPENDENCY_SWIFT}"
    PUBLIC
        FILE_SET api_headers
        TYPE HEADERS
        BASE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}/Partout_C/include
        FILES "${PARTOUT_C_API_HEADER}"
)
target_link_libraries(partout PRIVATE partout_c)

# Apple still requires Swift 5 for NE
if(APPLE)
    set(SWIFT_MODE 5)
else()
    set(SWIFT_MODE 6)
endif()
target_compile_options(partout PRIVATE
    -language-mode ${SWIFT_MODE}
)

################################################

# Set vendor symbols
if(PP_BUILD_USE_OPENVPN)
    target_compile_options(partout_c PRIVATE
        -DPARTOUT_OPENVPN
    )
    target_compile_options(partout PRIVATE
        -DPARTOUT_OPENVPN
    )
endif()
if(PP_BUILD_USE_WIREGUARD)
    target_compile_options(partout_c PRIVATE
        -DPARTOUT_WIREGUARD
    )
    target_compile_options(partout PRIVATE
        -DPARTOUT_WIREGUARD
    )
endif()
if(PP_BUILD_USE_OPENSSL)
    target_compile_options(partout_c PRIVATE
        -DPARTOUT_CRYPTO_OPENSSL
    )
    target_compile_options(partout PRIVATE
        -DPARTOUT_CRYPTO_OPENSSL
    )
endif()
if(PP_BUILD_USE_MBEDTLS)
    target_compile_options(partout_c PRIVATE
        -DPARTOUT_CRYPTO_MBEDTLS
    )
    target_compile_options(partout PRIVATE
        -DPARTOUT_CRYPTO_MBEDTLS
    )
endif()

# Set overall output properties
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    Swift_MODULE_NAME "Partout"
    Swift_MODULE_DIRECTORY "${OUTPUT_DIR}/modules"
    Swift_COMPILATION_MODE incremental
)
set_target_properties(partout_c PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
)

# Platform specifics
if(WIN32)
    set_target_properties(partout_c PROPERTIES PREFIX "lib")
    set_target_properties(partout PROPERTIES PREFIX "lib")
else()
    if(APPLE)
        set(RPATH_ORIGIN "@loader_path")
    else()
        set(RPATH_ORIGIN "\$ORIGIN")
    endif()
    set_target_properties(partout PROPERTIES
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "${RPATH_ORIGIN}"
    )
    unset(RPATH_ORIGIN)
endif()

# Strip after build
if((LINUX OR ANDROID) AND NOT PP_BUILD_STATIC)
    add_custom_command(TARGET partout POST_BUILD
        COMMAND ${CMAKE_STRIP} $<TARGET_FILE:partout>
        COMMENT "Stripping $<TARGET_FILE_NAME:partout>"
    )
endif()

# Configure install
install(TARGETS partout
    EXPORT PartoutTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    FILE_SET api_headers DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/Partout_C/include/module.modulemap
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# Include partout_c if building statically (cannot embed)
if(PP_BUILD_STATIC)
    install(TARGETS partout_c
        EXPORT PartoutTargets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    )
endif()
