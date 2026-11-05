# Portable generated models, independent of the Windows bridge.
# The caller supplies nlohmann_json::nlohmann_json.
include_guard(GLOBAL)
get_filename_component(PARTOUT_MODELS_ROOT "${CMAKE_CURRENT_LIST_DIR}/../cross/cpp" ABSOLUTE)
set(PARTOUT_MODELS_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/partout-models/include")
file(GLOB partout_model_headers CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.h")
foreach(header IN LISTS partout_model_headers)
    get_filename_component(name "${header}" NAME)
    configure_file("${header}" "${PARTOUT_MODELS_INCLUDE}/partout/models/${name}" COPYONLY)
endforeach()
configure_file("${PARTOUT_MODELS_ROOT}/json.h" "${PARTOUT_MODELS_INCLUDE}/partout/json.h" COPYONLY)

file(GLOB partout_model_sources CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.cpp")
add_library(partout-models-impl STATIC ${partout_model_sources})
target_compile_features(partout-models-impl PUBLIC cxx_std_17)
target_compile_definitions(partout-models-impl PUBLIC NOMINMAX)
target_include_directories(partout-models-impl SYSTEM PUBLIC "${PARTOUT_MODELS_INCLUDE}")
target_link_libraries(partout-models-impl PUBLIC nlohmann_json::nlohmann_json)

# Windows SDK consumers use the DLL's model exports. The implementation archive
# is only a build input; linking it into consumers would duplicate those symbols.
if(WIN32 AND PP_BUILD_WINDOWS AND PP_BUILD_LIBRARY)
    add_library(partout-models-interface INTERFACE)
    add_library(Partout::Models ALIAS partout-models-interface)
    target_compile_features(partout-models-interface INTERFACE cxx_std_17)
    target_compile_definitions(partout-models-interface INTERFACE NOMINMAX)
    target_include_directories(partout-models-interface SYSTEM INTERFACE "${PARTOUT_MODELS_INCLUDE}")
    target_link_libraries(partout-models-interface INTERFACE Partout::Partout nlohmann_json::nlohmann_json)
else()
    add_library(Partout::Models ALIAS partout-models-impl)
endif()
