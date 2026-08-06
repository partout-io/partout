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

if(WIN32)
    set(PARTOUT_RUNTIME_LIBRARY "${PP_BUILD_PREFIX}/bin/partout.dll")
    if(WINTUN_DIR)
        partout_install_runtime_file("${PP_BUILD_PREFIX}/bin/wintun.dll")
    endif()
else()
    set(PARTOUT_RUNTIME_LIBRARY
        "${PP_BUILD_PREFIX}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()
partout_install_runtime_file("${PARTOUT_RUNTIME_LIBRARY}")
if(PP_BUILD_USE_WIREGUARD)
    partout_install_runtime_file("${WGGO_RUNTIME_LIBRARY}")
endif()
if(PARTOUT_OPENSSL_IS_PREBUILT)
    partout_install_runtime_directory("${OPENSSL_DIR}/bin")
    partout_install_runtime_directory("${OPENSSL_DIR}/lib")
endif()
if(PARTOUT_MBEDTLS_IS_PREBUILT)
    partout_install_runtime_directory("${MBEDTLS_DIR}/bin")
    partout_install_runtime_directory("${MBEDTLS_DIR}/lib")
endif()
