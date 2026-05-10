set(WGGO_DIR ${PP_BUILD_OUTPUT}/wg-go)

if(WIN32)
    set(WGGO_BYPRODUCTS
        ${WGGO_DIR}/lib/wg-go.dll
        ${WGGO_DIR}/lib/wg-go.lib
    )
    set(WGGO_CMD
        make-windows.bat ${WGGO_DIR}
    )
else()
    set(WGGO_BYPRODUCTS ${WGGO_DIR}/lib/libwg-go${LIBEXT})
    set(WGGO_CMD
        make -C ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
        DESTDIR=${WGGO_DIR}
    )
    if(ANDROID)
        set(CLANG $ENV{SWIFT_ANDROID_ARCH}-linux-android${ANDROID_NATIVE_API_LEVEL}-clang)
        set(WGGO_CMD ${WGGO_CMD} ANDROID=1 CC=${CLANG})
    endif()
endif()

if(APPLE)
    set(WGGO_INSTALL_COMMAND
        install_name_tool -id "@rpath/libwg-go.dylib" "${WGGO_DIR}/lib/libwg-go.dylib"
    )
elseif(WIN32)
    set(WGGO_INSTALL_COMMAND
        gendef "${WGGO_DIR}/lib/wg-go.dll"
        COMMAND dlltool -d wg-go.def -l "${WGGO_DIR}/lib/wg-go.lib"
    )
else()
    set(WGGO_INSTALL_COMMAND "")
endif()

ExternalProject_Add(WireGuardGoProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${VENDOR_ENV} ${WGGO_CMD}
    INSTALL_COMMAND ${WGGO_INSTALL_COMMAND}
    BUILD_IN_SOURCE 1
    BUILD_BYPRODUCTS ${WGGO_BYPRODUCTS}
)

add_library(WireGuardGoInterface INTERFACE)
add_dependencies(WireGuardGoInterface WireGuardGoProject)
target_include_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/include)
target_link_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/lib)
target_link_libraries(WireGuardGoInterface INTERFACE wg-go)
