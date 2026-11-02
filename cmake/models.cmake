# Portable generated models, independent of the Windows bridge.
# The caller supplies nlohmann_json::nlohmann_json.
include_guard(GLOBAL)
get_filename_component(PARTOUT_MODELS_ROOT "${CMAKE_CURRENT_LIST_DIR}/../cross/windows/src" ABSOLUTE)
set(PARTOUT_MODELS_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/partout-models/include")
file(GLOB partout_model_headers CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.h")
foreach(header IN LISTS partout_model_headers)
    get_filename_component(name "${header}" NAME)
    configure_file("${header}" "${PARTOUT_MODELS_INCLUDE}/partout/models/${name}" COPYONLY)
endforeach()
configure_file("${PARTOUT_MODELS_ROOT}/json.h" "${PARTOUT_MODELS_INCLUDE}/partout/json.h" COPYONLY)

file(GLOB partout_model_sources CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.cpp")
add_library(partout-models OBJECT ${partout_model_sources})
add_library(Partout::Models ALIAS partout-models)
target_compile_features(partout-models PUBLIC cxx_std_17)
target_compile_definitions(partout-models PUBLIC NOMINMAX)
target_include_directories(partout-models SYSTEM PUBLIC "${PARTOUT_MODELS_INCLUDE}")
target_link_libraries(partout-models PUBLIC nlohmann_json::nlohmann_json)
