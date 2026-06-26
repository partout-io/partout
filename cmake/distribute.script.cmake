# Defaults
include("${CMAKE_CURRENT_LIST_DIR}/swift/swift-macros.cmake")

if(NOT DEFINED PARTOUT_OUTPUT_DIR AND DEFINED OUTPUT_DIR)
    set(PARTOUT_OUTPUT_DIR "${OUTPUT_DIR}")
endif()
if(NOT DEFINED PARTOUT_DIST_DIR AND DEFINED DIST_DIR)
    set(PARTOUT_DIST_DIR "${DIST_DIR}")
endif()

if(NOT DEFINED PARTOUT_OUTPUT_DIR)
    message(FATAL_ERROR "PARTOUT_OUTPUT_DIR is required")
endif()
if(NOT DEFINED PARTOUT_DIST_DIR)
    message(FATAL_ERROR "PARTOUT_DIST_DIR is required")
endif()

# OpenSSL outputs to "bin" on Windows
if(WIN32)
    set(PARTOUT_OPENSSL_FOLDER bin)
else()
    set(PARTOUT_OPENSSL_FOLDER lib)
endif()

# Library and vendors
file(GLOB PARTOUT_LIBRARY_FILES
    "${PARTOUT_OUTPUT_DIR}/partout/libpartout*"
)
file(GLOB PARTOUT_OPENSSL_SSL_FILES
    "${PARTOUT_OUTPUT_DIR}/openssl/${PARTOUT_OPENSSL_FOLDER}/libssl*"
)
file(GLOB PARTOUT_OPENSSL_CRYPTO_FILES
    "${PARTOUT_OUTPUT_DIR}/openssl/${PARTOUT_OPENSSL_FOLDER}/libcrypto*"
)
file(GLOB PARTOUT_WIREGUARD_GO_FILES
    "${PARTOUT_OUTPUT_DIR}/wg-go/lib/*wg-go*"
)

# Copy to distribution folder
file(MAKE_DIRECTORY "${PARTOUT_DIST_DIR}")
foreach(lib IN LISTS
        PARTOUT_LIBRARY_FILES
        PARTOUT_OPENSSL_SSL_FILES
        PARTOUT_OPENSSL_CRYPTO_FILES
        PARTOUT_WIREGUARD_GO_FILES)
    file(COPY "${lib}" DESTINATION "${PARTOUT_DIST_DIR}")
endforeach()

# Clean up static libs and metadata
file(GLOB PARTOUT_DISTRIBUTION_CLEANUP
    "${PARTOUT_DIST_DIR}/*.a"
    "${PARTOUT_DIST_DIR}/*.d"
    "${PARTOUT_DIST_DIR}/*.lib"
    # Keep for debugging.
    "${PARTOUT_DIST_DIR}/*.exp"
    "${PARTOUT_DIST_DIR}/*.pdb"
    "${PARTOUT_DIST_DIR}/*.ilk"
)
foreach(file IN LISTS PARTOUT_DISTRIBUTION_CLEANUP)
    file(REMOVE "${file}")
endforeach()

# Windows steps
set(PARTOUT_PREBUILT_LIBS "")
if(WIN32)
    list(APPEND PARTOUT_PREBUILT_LIBS
        "${PARTOUT_OUTPUT_DIR}/wintun/wintun.dll"
    )
endif()
foreach(lib IN LISTS PARTOUT_PREBUILT_LIBS)
    file(COPY "${lib}" DESTINATION "${PARTOUT_DIST_DIR}")
endforeach()
swift_copy_windows_runtime("${PARTOUT_DIST_DIR}")
