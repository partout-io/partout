set(WGGO_DIR ${PP_BUILD_OUTPUT}/wg-go)

# Add some flags if -DANDROID (requires NDK tools in the PATH)
if(ANDROID)
    set(WGGO_ANDROID 1)
else()
    set(WGGO_ANDROID "")
endif()

if(WIN32)
    set(WGGO_CMD
        make-windows.bat ${WGGO_DIR}
    )
else()
    set(WGGO_CMD
        make -C ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
        DESTDIR=${WGGO_DIR}
        ANDROID=${WGGO_ANDROID})
endif()

ExternalProject_Add(
    WireGuardGoProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${WGGO_CMD}
    INSTALL_COMMAND ""
    BUILD_IN_SOURCE 1
)
