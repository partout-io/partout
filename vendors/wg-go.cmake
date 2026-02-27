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

ExternalProject_Add(WireGuardGoProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ${WGGO_CMD}
    INSTALL_COMMAND ""
    BUILD_IN_SOURCE 1
)

if(APPLE)
    add_custom_command(
        TARGET WireGuardGoProject
        POST_BUILD
        COMMAND install_name_tool -id "@rpath/libwg-go.dylib" "${WGGO_DIR}/lib/libwg-go.dylib"
    )
elseif(WIN32)
    add_custom_command(
        TARGET WireGuardGoProject
        POST_BUILD
        COMMAND gendef "${WGGO_DIR}/lib/wg-go.dll"
        COMMAND dlltool -d wg-go.def -l "${WGGO_DIR}/lib/wg-go.lib"
    )
endif()

add_library(WireGuardGoInterface INTERFACE)
add_dependencies(WireGuardGoInterface WireGuardGoProject)
target_include_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/include)
target_link_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/lib)
target_link_libraries(WireGuardGoInterface INTERFACE wg-go)
