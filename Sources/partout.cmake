set(ROOT_DIR ${CMAKE_SOURCE_DIR}/..)

# Swift sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_SOURCES
    ${ROOT_DIR}/vendors/core/Sources/PartoutCore/*.swift
    *.swift
)

# Set up global exclusions
set(EXCLUDED_PATTERNS
    # Executables
    partoutd
    test-.*
    # Unnecessary exports (wrong in monolith)
    Partout.*\/Exports\.swift
    PartoutOpenVPN\/Wrapper\/OpenVPNWrapper\.swift
    PartoutWireGuard\/Wrapper\/WireGuardWrapper\.swift
    # Bundled API resources
    PartoutAPI\/JSON\/
    PartoutAPI\/REST\/API\\+Bundle\.swift
    # OpenVPN legacy
    PartoutOpenVPN\/Cross\/Internal\/Legacy\/
    PartoutOpenVPN\/Legacy.*\/
    # FIXME: #118, restore WireGuard when properly integrated
    PartoutWireGuard\/
    Vendors\/WireGuardGo\/
)

# Exclude per platform
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

foreach(pattern ${EXCLUDED_PATTERNS})
    list(FILTER PARTOUT_SOURCES EXCLUDE REGEX ${pattern})
endforeach()

# Try simple vendor test
#add_library(Partout SHARED ${CMAKE_SOURCE_DIR}/file.c)

# Partout library base configuration
add_library(Partout SHARED ${PARTOUT_SOURCES})

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
target_link_libraries(Partout PRIVATE Partout_C)
