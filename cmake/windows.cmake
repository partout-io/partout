# The Windows backend uses MSVC's C++ runtime and Windows SDK projections. Build this bridge
# separately from Zig's portable C sources; consumers opt in when needed.
option(PP_BUILD_WINDOWS "Build the Windows VPN channel bridge" OFF)
if(NOT PP_BUILD_WINDOWS)
    return()
endif()

if(CMAKE_VERSION VERSION_LESS 4.0)
    message(FATAL_ERROR "PP_BUILD_WINDOWS requires CMake 4.0 or newer")
endif()
if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "PP_BUILD_WINDOWS requires MSVC and the Windows SDK")
endif()

include(FetchContent)
enable_language(CXX)
FetchContent_Declare(json
    URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
    URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
)
FetchContent_MakeAvailable(json)
include("${CMAKE_CURRENT_LIST_DIR}/models.cmake")

# The native backend cannot include Partout headers. Keep it independently
# compilable; runtime.cc and platform.cc integrate with Partout's APIs.
set(partout_backend_type STATIC)
if(PP_BUILD_LIBRARY)
    set(partout_backend_type SHARED)
endif()
add_library(partout-windows-backend ${partout_backend_type}
    cross/windows/src/abi.cc
    cross/windows/src/controller.cc
    cross/windows/src/loop.cc
    cross/windows/src/network.cc
    cross/windows/src/socket.cc
    cross/windows/src/tun.cc
    cross/windows/src/tun_settings.cc
    cross/windows/src/log.cc
)
target_include_directories(partout-windows-backend PUBLIC cross/windows/include)
if(PP_BUILD_LIBRARY)
    set_target_properties(partout-windows-backend PROPERTIES
        OUTPUT_NAME partout-runtime
        WINDOWS_EXPORT_ALL_SYMBOLS OFF
        RUNTIME_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
        ARCHIVE_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
        PDB_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
    )
    target_compile_definitions(partout-windows-backend PRIVATE
        PARTOUT_WINDOWS_BUILD_DLL PARTOUT_MODELS_BUILD_DLL)
endif()
target_link_libraries(partout-windows-backend
    PUBLIC windowsapp runtimeobject ws2_32 iphlpapi
    PRIVATE nlohmann_json::nlohmann_json ole32
)

# Keep the standalone backend archive self-contained for Zig tests.
target_sources(partout-windows-backend PRIVATE $<TARGET_OBJECTS:partout-models-impl>)
target_link_libraries(partout-windows-backend PRIVATE partout-models-impl)
# Generated model implementations do not follow our warning policy.
target_compile_options(partout-models-impl PRIVATE /w)

foreach(target IN ITEMS partout-windows-backend partout-models-impl)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
    target_compile_options(${target} PRIVATE /EHsc /permissive-)
    if(NOT target STREQUAL "partout-models-impl")
        target_compile_options(${target} PRIVATE /W4)
    endif()
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(${target} PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
endforeach()
