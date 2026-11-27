# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

# Desktop consumers can use the models without the portable C++ runtime.
if(NOT ANDROID AND NOT APPLE)
    enable_language(CXX)
    if(NOT TARGET nlohmann_json::nlohmann_json)
        include(FetchContent)
        FetchContent_Declare(json
            URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
            URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
        )
        set(JSON_Install OFF)
        if(partout_install_sdk AND partout_export_cpp_abi)
            set(JSON_Install ON)
        endif()
        FetchContent_MakeAvailable(json)
    endif()
    set(PARTOUT_CPP_ROOT "${CMAKE_CURRENT_LIST_DIR}/../runtimes/cpp")
    set(PARTOUT_CPP_INCLUDE "${PARTOUT_CPP_ROOT}/include")
    file(GLOB model_sources CONFIGURE_DEPENDS "${PARTOUT_CPP_ROOT}/models/*.cc")
    # Model implementations belong to consumers, not the DLL export surface.
    # Keep one object per model so each link pulls only the models it needs.
    add_library(partout-models STATIC ${model_sources})
    add_library(Partout::Models ALIAS partout-models)
    set_target_properties(partout-models PROPERTIES
        UNITY_BUILD OFF
        POSITION_INDEPENDENT_CODE ON
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON)
    target_compile_features(partout-models PUBLIC cxx_std_17)
    target_compile_definitions(partout-models PUBLIC NOMINMAX)
    target_include_directories(partout-models SYSTEM PUBLIC
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>")
    target_link_libraries(partout-models PUBLIC nlohmann_json::nlohmann_json)
    target_precompile_headers(partout-models PRIVATE <partout/Json.h>)
    if(MSVC)
        target_compile_options(partout-models PRIVATE /EHsc /permissive- /W4)
        set_target_properties(partout-models PROPERTIES
            MSVC_RUNTIME_LIBRARY MultiThreadedDLL MSVC_RUNTIME_CHECKS "")
    endif()
endif()
