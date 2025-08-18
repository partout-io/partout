# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    ${PARTOUT_CORE_SOURCES_DIR}/*.swift
    ${PARTOUT_DIR}/Sources/*.swift
)

# Set up global exclusions
set(EXCLUDED_PATTERNS
    # Unnecessary exports (wrong in monolith)
    Partout\/PartoutExports\.swift
    OpenVPN\/Wrapper\/OpenVPNWrapper\.swift
    WireGuard\/Wrapper\/WireGuardWrapper\.swift
    # Bundled API resources
    API\/Bundle\/API\\+Bundle\.swift
    API\/Bundle\/JSON\/
    # OpenVPN legacy
    OpenVPN\/Cross\/Internal\/Legacy\/
    OpenVPN\/CryptoOpenSSL_ObjC\/
    OpenVPN\/Legacy\/
    OpenVPN\/Legacy_ObjC\/
    # FIXME: #118, restore WireGuard when properly integrated
    WireGuard\/
)

# Exclude per platform
if(NOT APPLE)
    list(APPEND EXCLUDED_PATTERNS
        Vendors\/Apple\/
        Vendors\/AppleNE\/
    )
endif()

foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Try simple vendor test
#add_library(Partout SHARED ${CMAKE_SOURCE_DIR}/file.c)

# Partout library base configuration
add_library(partout SHARED ${PARTOUT_SOURCES})
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
)

# Define symbols to skip Swift imports and legacy code
target_compile_options(partout PRIVATE
    -DPARTOUT_MONOLITH
    -DOPENVPN_WRAPPED_NATIVE
)

# Look for modulemaps in C "include" dirs
foreach(dir ${PARTOUT_C_INCLUDE_DIRS})
    target_compile_options(partout PRIVATE -I${dir})
endforeach()

# Depend on C targets (include before)
add_dependencies(partout partout_c)
target_link_libraries(partout PRIVATE partout_c)
