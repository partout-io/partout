set(MBEDTLS_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/${PP_BUILD_OUTPUT}/mbedtls)

# Use cl compiler on Windows
if(WIN32)
    set(MBEDTLS_CC cl)
else()
    set(MBEDTLS_CC cc)
endif()

ExternalProject_Add(
    MbedTLSProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/mbedtls
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${MBEDTLS_OUTPUT_DIR} -DCMAKE_C_COMPILER=${MBEDTLS_CC}
)
