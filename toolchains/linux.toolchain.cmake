if(NOT DEFINED ENV{SWIFT_VERSION} OR "$ENV{SWIFT_VERSION}" STREQUAL "")
    message(FATAL_ERROR "SWIFT_VERSION must be defined")
endif()

set(CMAKE_C_COMPILER "clang")
set(CMAKE_CXX_COMPILER "clang")
set(CMAKE_C_FLAGS "-fPIC")

# Infer from Swift version
set(SWIFT_RESOURCE_DIR $ENV{HOME}/.local/share/swiftly/toolchains/$ENV{SWIFT_VERSION}/usr/lib/swift_static)

# Inherit clang resource dir (e.g. for stddef.h and stdbool.h)
execute_process(
    COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir
    OUTPUT_VARIABLE CLANG_RESOURCE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT CLANG_RESOURCE_DIR)
    message(FATAL_ERROR "Unable to infer clang resource directory")
endif()

set(CMAKE_Swift_FLAGS "\
    -resource-dir ${SWIFT_RESOURCE_DIR} \
    -Xcc -resource-dir -Xcc ${CLANG_RESOURCE_DIR} \
    -module-cache-path ${CMAKE_BINARY_DIR}/swift-module-cache \
    -lFoundationEssentials \
    -l_FoundationCollections \
    -l_FoundationCShims \
    -lswiftSynchronization \
    -ldispatch \
    -lstdc++ \
    -lm"
)
