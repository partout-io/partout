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
add_library(partout-windows-backend STATIC
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
target_link_libraries(partout-windows-backend
    PUBLIC windowsapp runtimeobject ws2_32 iphlpapi
    PRIVATE nlohmann_json::nlohmann_json
)

# Keep the standalone backend archive self-contained for Zig tests.
target_sources(partout-windows-backend PRIVATE $<TARGET_OBJECTS:partout-models>)
target_link_libraries(partout-windows-backend PRIVATE Partout::Models)
# Generated model implementations do not follow our warning policy.
target_compile_options(partout-models PRIVATE /w)

foreach(target IN ITEMS partout-windows-backend partout-models)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
    target_compile_options(${target} PRIVATE /EHsc /permissive-)
    if(NOT target STREQUAL "partout-models")
        target_compile_options(${target} PRIVATE /W4)
    endif()
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(${target} PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
endforeach()
