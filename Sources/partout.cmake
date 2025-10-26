set(ROOT_DIR ${CMAKE_SOURCE_DIR}/..)

# Partout library base configuration
add_library(partout SHARED ${PARTOUT_SOURCES})

# Define symbols to skip Swift imports and legacy code
target_compile_options(partout PRIVATE
    -DPARTOUT_MONOLITH
    -DPARTOUT_OPENVPN
    -DPARTOUT_WIREGUARD
    -DOPENVPN_WRAPPER_NATIVE
    -DOPENVPN_DEPRECATED_LZO
)

# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    *.swift
)

# Set up global exclusions
set(EXCLUDED_PATTERNS
    # Legacy
    PartoutOpenVPN\/Cross\/Internal\/Legacy\/
    PartoutOpenVPN\/Legacy.*\/
    PartoutWireGuard\/Legacy.*\/
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
    target_compile_options(partout PRIVATE -I${dir})
endforeach()

# Depend on C target (include before)
add_dependencies(partout partout_c)
target_sources(partout PRIVATE ${PARTOUT_SOURCES})
target_link_libraries(partout PRIVATE partout_c)
