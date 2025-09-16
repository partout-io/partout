set(ROOT_DIR ${CMAKE_SOURCE_DIR}/..)

# Partout library base configuration
add_library(Partout SHARED ${PARTOUT_SOURCES})

# Define symbols to skip Swift imports and legacy code
target_compile_options(Partout PRIVATE
    -DPARTOUT_MONOLITH
    -DPARTOUT_API
    -DPARTOUT_OPENVPN
    -DPARTOUT_WIREGUARD
    -DOPENVPN_WRAPPER_NATIVE
)

# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    ${ROOT_DIR}/vendors/core/Sources/PartoutCore/*.swift
    *.swift
)

# Set up global exclusions
set(EXCLUDED_PATTERNS
    # Bundled API resources
    PartoutAPI\/JSON\/
    PartoutAPI\/REST\/API\\+Bundle\.swift
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
    target_compile_options(Partout PRIVATE -I${dir})
endforeach()

# Depend on C target (include before)
add_dependencies(Partout Partout_C)
target_sources(Partout PRIVATE ${PARTOUT_SOURCES})
target_link_libraries(Partout PRIVATE Partout_C)
