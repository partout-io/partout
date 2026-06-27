set(WGGO_DIR ${PP_BUILD_OUTPUT}/wg-go)

if(WIN32)
    set(WGGO_RUNTIME_LIBRARY ${WGGO_DIR}/lib/wg-go.dll)
    set(WGGO_IMPORT_LIBRARY ${WGGO_DIR}/lib/wg-go${CMAKE_IMPORT_LIBRARY_SUFFIX})
    set(WGGO_BUILD_BYPRODUCTS ${WGGO_RUNTIME_LIBRARY} ${WGGO_IMPORT_LIBRARY})
    set(WGGO_CMD
        make-windows.bat ${WGGO_DIR}
    )
else()
    set(WGGO_RUNTIME_LIBRARY ${WGGO_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}wg-go${CMAKE_SHARED_LIBRARY_SUFFIX})
    set(WGGO_BUILD_BYPRODUCTS ${WGGO_RUNTIME_LIBRARY})
    set(WGGO_CMD
        make -C ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
        DESTDIR=${WGGO_DIR}
    )
    if(ANDROID)
        set(CLANG ${SWIFT_ANDROID_ARCH}-linux-android${ANDROID_NATIVE_API_LEVEL}-clang)
        set(WGGO_CMD ${WGGO_CMD} ANDROID=1 CC=${CLANG})
    endif()
endif()

if(PP_USE_PREBUILT_VENDORS)
    partout_fetch_prebuilt_vendor(wg-go WGGO_DIR)
else()
    if(APPLE)
        set(WGGO_INSTALL_COMMAND
            INSTALL_COMMAND
            install_name_tool -id "@rpath/libwg-go.dylib" "${WGGO_RUNTIME_LIBRARY}"
        )
    elseif(WIN32)
        set(WGGO_INSTALL_COMMAND
            INSTALL_COMMAND
            gendef "${WGGO_RUNTIME_LIBRARY}"
            COMMAND dlltool -d wg-go.def -l "${WGGO_IMPORT_LIBRARY}"
        )
    else()
        set(WGGO_INSTALL_COMMAND
            INSTALL_COMMAND ""
        )
    endif()

    ExternalProject_Add(WireGuardGoProject
        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
        CONFIGURE_COMMAND ""
        BUILD_COMMAND ${VENDOR_ENV} ${WGGO_CMD}
        ${WGGO_INSTALL_COMMAND}
        BUILD_IN_SOURCE 1
        BUILD_BYPRODUCTS ${WGGO_BUILD_BYPRODUCTS}
    )
endif()

add_library(WireGuardGo::wg-go SHARED IMPORTED GLOBAL)
set_target_properties(WireGuardGo::wg-go PROPERTIES
    IMPORTED_LOCATION ${WGGO_RUNTIME_LIBRARY}
)
if(UNIX AND NOT APPLE)
    set_target_properties(WireGuardGo::wg-go PROPERTIES
        IMPORTED_NO_SONAME TRUE
    )
endif()
if(WIN32)
    set_target_properties(WireGuardGo::wg-go PROPERTIES
        IMPORTED_IMPLIB ${WGGO_IMPORT_LIBRARY}
    )
endif()

add_library(WireGuardGoInterface INTERFACE)
target_include_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/include)
target_link_libraries(WireGuardGoInterface INTERFACE WireGuardGo::wg-go)
if(NOT PP_USE_PREBUILT_VENDORS)
    add_dependencies(WireGuardGo::wg-go WireGuardGoProject)
    add_dependencies(WireGuardGoInterface WireGuardGoProject)
endif()
