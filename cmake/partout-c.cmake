# C/C++ sources, including vendored PartoutCore
file(GLOB_RECURSE PARTOUT_C_SOURCES
    ${PARTOUT_CORE_C_SOURCES_DIR}/*.c
    ${PARTOUT_DIR}/Sources/*.c
    ${PARTOUT_DIR}/Sources/*.cc
    ${PARTOUT_DIR}/Sources/*.cpp
)

# TODO: #173, Restore later with platform/vendor conditionals (forcing OpenSSL now)
list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX "Apple.*")
list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX "Crypto\/CryptoWindows_C\/.*")
list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX "Crypto\/TLSMbed_C\/.*")
list(FILTER PARTOUT_C_SOURCES EXCLUDE REGEX "WireGuard.*")

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
target_compile_options(Partout_C PRIVATE
    -fPIC
)
target_include_directories(Partout_C PRIVATE
    ${PARTOUT_C_INCLUDE_DIRS}
)
