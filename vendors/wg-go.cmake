set(WGGO_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/${PP_BUILD_OUTPUT}/wg-go)

# Add some flags if -DANDROID (requires NDK tools in the PATH)
if(PP_BUILD_FOR_ANDROID)
    set(WGGO_ANDROID 1)
else()
    set(WGGO_ANDROID "")
endif()
set(BUILD_CMD
    make -C ${CMAKE_SOURCE_DIR}/vendors/wg-go
    DESTDIR=${WGGO_OUTPUT_DIR}
    ANDROID=${WGGO_ANDROID})

ExternalProject_Add(
    WireGuardGoProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/wg-go
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${BUILD_CMD}
    INSTALL_COMMAND ""
)
