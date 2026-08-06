set(PARTOUT_MBEDTLS_DEPENDENCY "")
set(PARTOUT_MBEDTLS_IS_PREBUILT OFF)
set(PARTOUT_MBEDTLS_SYSTEM_FOUND OFF)

if(PP_SYSTEM_VENDORS_AVAILABLE)
    partout_use_homebrew_formula(mbedtls)
    find_path(PARTOUT_MBEDTLS_INCLUDE_DIR mbedtls/ssl.h)
    find_library(PARTOUT_MBEDTLS_TLS_LIBRARY mbedtls)
    find_library(PARTOUT_MBEDTLS_X509_LIBRARY mbedx509)
    find_library(PARTOUT_MBEDTLS_CRYPTO_LIBRARY mbedcrypto)
    if(PARTOUT_MBEDTLS_INCLUDE_DIR AND
       PARTOUT_MBEDTLS_TLS_LIBRARY AND
       PARTOUT_MBEDTLS_X509_LIBRARY AND
       PARTOUT_MBEDTLS_CRYPTO_LIBRARY)
        set(PARTOUT_MBEDTLS_SYSTEM_FOUND ON)
    endif()
endif()

if(PARTOUT_MBEDTLS_SYSTEM_FOUND)
    get_filename_component(PARTOUT_MBEDTLS_LIBRARY_DIR
        "${PARTOUT_MBEDTLS_TLS_LIBRARY}" DIRECTORY)
    foreach(library IN ITEMS PARTOUT_MBEDTLS_X509_LIBRARY PARTOUT_MBEDTLS_CRYPTO_LIBRARY)
        get_filename_component(library_dir "${${library}}" DIRECTORY)
        if(NOT library_dir STREQUAL PARTOUT_MBEDTLS_LIBRARY_DIR)
            set(PARTOUT_MBEDTLS_SYSTEM_FOUND OFF)
        endif()
    endforeach()
endif()

if(PARTOUT_MBEDTLS_SYSTEM_FOUND)
    message(STATUS "Using system MbedTLS")
else()
    partout_use_prebuilt_vendor(mbedtls MBEDTLS_DIR)
    set(PARTOUT_MBEDTLS_IS_PREBUILT ON)
    set(PARTOUT_MBEDTLS_INCLUDE_DIR "${MBEDTLS_DIR}/include")
    set(PARTOUT_MBEDTLS_LIBRARY_DIR "${MBEDTLS_DIR}/lib")
endif()
