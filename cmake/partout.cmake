# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    ${PARTOUT_CORE_SOURCES_DIR}/*.swift
    ${PARTOUT_DIR}/Sources/*.swift
)

# Exclude unnecessary exports (wrong in monolith)
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "PartoutExports.swift")
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "OpenVPNWrapper.swift")
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "WireGuardWrapper.swift")

# TODO: #173, Exclude API due to bundled resources
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "API\/.*")

# Exclude OpenVPN legacy
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "OpenVPN\/CryptoOpenSSL_ObjC\/.*")
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "OpenVPN\/.*Legacy\/.*")

# TODO: #173, Exclude WireGuard until properly integrated
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "Apple.*")
list(FILTER PARTOUT_SOURCES EXCLUDE REGEX "WireGuard")

# Try simple vendor test
#add_library(Partout SHARED ${CMAKE_SOURCE_DIR}/file.c)

# Partout library base configuration
add_library(Partout SHARED ${PARTOUT_SOURCES})
set_target_properties(Partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
)

# Define symbols to skip Swift imports and legacy code
target_compile_options(Partout PRIVATE
    -DPARTOUT_MONOLITH
    -DOPENVPN_WRAPPED_NATIVE
)

# Look for modulemaps in C "include" dirs
foreach(dir ${PARTOUT_C_INCLUDE_DIRS})
    target_compile_options(Partout PRIVATE -I${dir})
endforeach()

# Depend on C targets (include before)
add_dependencies(Partout Partout_C)
target_link_libraries(Partout PRIVATE
    Partout_C
)
