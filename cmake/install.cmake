include(GNUInstallDirs)

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

function(partout_install_runtime_file file)
    install(FILES "${file}"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        OPTIONAL
    )
endfunction()

function(partout_install_runtime_directory directory)
    if(WIN32)
        set(runtime_patterns PATTERN "*.dll")
    elseif(APPLE)
        set(runtime_patterns PATTERN "*.dylib")
    else()
        set(runtime_patterns PATTERN "*.so" PATTERN "*.so.*")
    endif()
    install(DIRECTORY "${directory}/"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        OPTIONAL
        USE_SOURCE_PERMISSIONS
        FILES_MATCHING
        ${runtime_patterns}
    )
endfunction()

function(partout_install_link_file file)
    install(FILES "${file}"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        OPTIONAL
    )
endfunction()

function(partout_install_link_directory directory)
    install(DIRECTORY "${directory}/"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        OPTIONAL
        USE_SOURCE_PERMISSIONS
        FILES_MATCHING
        PATTERN "*.a"
        PATTERN "*.lib"
    )
endfunction()

install(DIRECTORY "${PP_BUILD_OUTPUT}/partout/include/"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    OPTIONAL
    USE_SOURCE_PERMISSIONS
)

if(WIN32 AND WINTUN_DIR)
    partout_install_runtime_file("${PP_BUILD_OUTPUT}/partout/bin/wintun.dll")
endif()

if(PP_BUILD_STATIC)
    partout_install_link_file(
        "${PP_BUILD_OUTPUT}/partout/lib/${CMAKE_STATIC_LIBRARY_PREFIX}partout${CMAKE_STATIC_LIBRARY_SUFFIX}"
    )
else()
    if(WIN32)
        set(PARTOUT_RUNTIME_LIBRARY "${PP_BUILD_OUTPUT}/partout/bin/partout.dll")
    else()
        set(PARTOUT_RUNTIME_LIBRARY
            "${PP_BUILD_OUTPUT}/partout/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}")
    endif()
    partout_install_runtime_file("${PARTOUT_RUNTIME_LIBRARY}")
endif()
if(PP_BUILD_USE_WIREGUARD)
    if(NOT WGGO_RUNTIME_LIBRARY MATCHES "\\.(a|lib)$")
        partout_install_runtime_file("${WGGO_RUNTIME_LIBRARY}")
    endif()
    if(PP_BUILD_STATIC AND WGGO_DIR)
        partout_install_link_directory("${WGGO_DIR}/lib")
    endif()
endif()
if(PARTOUT_OPENSSL_IS_PREBUILT)
    partout_install_runtime_directory("${OPENSSL_DIR}/bin")
    partout_install_runtime_directory("${OPENSSL_DIR}/lib")
    if(PP_BUILD_STATIC)
        partout_install_link_directory("${OPENSSL_DIR}/lib")
    endif()
endif()
if(PARTOUT_MBEDTLS_IS_PREBUILT)
    partout_install_runtime_directory("${MBEDTLS_DIR}/bin")
    partout_install_runtime_directory("${MBEDTLS_DIR}/lib")
    if(PP_BUILD_STATIC)
        partout_install_link_directory("${MBEDTLS_DIR}/lib")
    endif()
endif()
