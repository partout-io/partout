# The Windows backend uses MSVC's C++ runtime and Windows SDK projections. Build this bridge
# separately from Zig's portable C sources; consumers opt in when needed.
if(NOT PP_BUILD_WINRT)
    return()
endif()

if(CMAKE_VERSION VERSION_LESS 4.0)
    message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
endif()
if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
endif()

# The native backend cannot include Partout headers. Keep it independently
# compilable; VpnChannelRuntime.cc and Platform.cc integrate with Partout's APIs.
set(partout_backend_type STATIC)
if(PP_BUILD_LIBRARY)
    set(partout_backend_type SHARED)
endif()
add_library(partout-winrt-backend ${partout_backend_type}
    runtimes/windows/winrt/backend/ABI.cc
    runtimes/windows/winrt/backend/TunnelController.cc
    runtimes/windows/winrt/backend/RuntimeLoop.cc
    runtimes/windows/winrt/backend/NetworkMonitor.cc
    runtimes/windows/winrt/backend/Socket.cc
    runtimes/windows/winrt/backend/Tun.cc
    runtimes/windows/winrt/backend/TunSettings.cc
    runtimes/windows/winrt/backend/Log.cc
)
target_include_directories(partout-winrt-backend PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/runtimes/windows/winrt/include>"
    "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
if(PP_BUILD_LIBRARY)
    set_target_properties(partout-winrt-backend PROPERTIES
        OUTPUT_NAME partout-winrt-backend
        WINDOWS_EXPORT_ALL_SYMBOLS OFF
        RUNTIME_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
        ARCHIVE_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
        PDB_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
    )
    target_compile_definitions(partout-winrt-backend PRIVATE
        PARTOUT_WINRT_BUILD_DLL PARTOUT_MODELS_BUILD_DLL)
endif()
target_link_libraries(partout-winrt-backend
    PUBLIC windowsapp runtimeobject ws2_32 iphlpapi
    PRIVATE "$<BUILD_INTERFACE:nlohmann_json::nlohmann_json>"
        "$<INSTALL_INTERFACE:nlohmann_json::nlohmann_json>" ole32
)

# Include every model implementation in the DLL exports and keep the standalone
# backend archive self-contained for Zig tests.
target_sources(partout-winrt-backend PRIVATE $<TARGET_OBJECTS:partout-models-impl>)
target_link_libraries(partout-winrt-backend PRIVATE "$<BUILD_INTERFACE:partout-models-impl>")
# Generated model implementations do not follow our warning policy.
target_compile_options(partout-models-impl PRIVATE /w)

foreach(target IN ITEMS partout-winrt-backend partout-models-impl)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
    target_compile_options(${target} PRIVATE /EHsc /permissive-)
    if(NOT target STREQUAL "partout-models-impl")
        target_compile_options(${target} PRIVATE /W4)
    endif()
    if(PP_BUILD_LIBRARY)
        # AppContainer DLLs use a CRT without the /RTC helpers. Static builds
        # inherit the caller's runtime and checks to match their final executable.
        set_target_properties(${target} PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL
            MSVC_RUNTIME_CHECKS ""
        )
    endif()
endforeach()
