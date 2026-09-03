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

if(PP_BUILD_LIBRARY)
    if(PP_BUILD_STATIC)
        partout_install_link_file(
            "${PP_BUILD_OUTPUT}/partout/lib/${CMAKE_STATIC_LIBRARY_PREFIX}partout${CMAKE_STATIC_LIBRARY_SUFFIX}"
        )
    else()
        install(IMPORTED_RUNTIME_ARTIFACTS partout_runtime
            LIBRARY DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
            RUNTIME DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        )
    endif()
endif()
if(PARTOUT_RUNTIME_LIBRARIES)
    install(IMPORTED_RUNTIME_ARTIFACTS ${PARTOUT_RUNTIME_LIBRARIES}
        LIBRARY DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        RUNTIME DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
    )
endif()
if(PP_BUILD_STATIC AND WGGO_DIR)
    partout_install_link_directory("${WGGO_DIR}/lib")
endif()
if(PP_BUILD_STATIC AND PARTOUT_OPENSSL_IS_PREBUILT)
    partout_install_link_directory("${OPENSSL_DIR}/lib")
endif()
if(PP_BUILD_STATIC AND PARTOUT_MBEDTLS_IS_PREBUILT)
    partout_install_link_directory("${MBEDTLS_DIR}/lib")
endif()
