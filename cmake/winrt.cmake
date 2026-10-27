# WinRT uses MSVC's C++ runtime and Windows SDK projections. Build this bridge
# separately from Zig's portable C sources; consumers opt in when needed.
option(PP_BUILD_WINRT "Build the WinRT VPN channel bridge" OFF)
if(PP_BUILD_WINRT)
    if(CMAKE_VERSION VERSION_LESS 4.0)
        message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
    endif()
    if(NOT WIN32 OR NOT MSVC)
        message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
    endif()
    enable_language(CXX)
    find_package(nlohmann_json CONFIG REQUIRED)
    # The native backend cannot include Partout headers. Keep it independently
    # compilable; runtime.cc and platform.cc integrate with Partout's APIs.
    add_library(partout-winrt-backend OBJECT
        cross/windows/src/abi.cc
        cross/windows/src/loop.cc
        cross/windows/src/network.cc
        cross/windows/src/socket.cc
        cross/windows/src/tun.cc
        cross/windows/src/tun_settings.cc
        cross/windows/src/log.cc
    )
    target_include_directories(partout-winrt-backend PUBLIC cross/windows/include)
    target_link_libraries(partout-winrt-backend PUBLIC windowsapp runtimeobject ws2_32 iphlpapi)

    # Preserve a single archive for Zig and existing consumers.
    add_library(partout-winrt STATIC cross/windows/src/runtime.cc cross/windows/src/platform.cc)
    file(GLOB partout_model_sources CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/src/models/*.cpp")
    target_sources(partout-winrt PRIVATE ${partout_model_sources})
    target_include_directories(partout-winrt PRIVATE src src/c/portable/include)
    target_compile_definitions(partout-winrt PRIVATE PARTOUT_WINRT_EXPORTS)
    target_link_libraries(partout-winrt PRIVATE partout-winrt-backend nlohmann_json::nlohmann_json)

    foreach(target IN ITEMS partout-winrt-backend partout-winrt)
        target_compile_features(${target} PRIVATE cxx_std_20)
        target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
        target_compile_options(${target} PRIVATE /EHsc /permissive- /W4)
        # AppContainer consumers use a CRT without the /RTC helpers.
        set_target_properties(${target} PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL
            MSVC_RUNTIME_CHECKS ""
        )
    endforeach()
endif()
