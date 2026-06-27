set(WINTUN_DIR ${PP_BUILD_OUTPUT}/wintun)
set(WINTUN_URL "https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip")
FetchContent_Declare(wintun
    URL ${WINTUN_URL}
)
FetchContent_MakeAvailable(wintun)
file(MAKE_DIRECTORY ${WINTUN_DIR})
file(COPY_FILE
    ${wintun_SOURCE_DIR}/include/wintun.h
    ${WINTUN_DIR}/wintun.h
    ONLY_IF_DIFFERENT
)
file(COPY_FILE
    ${wintun_SOURCE_DIR}/bin/${ARCH_NAME}/wintun.dll
    ${WINTUN_DIR}/wintun.dll
    ONLY_IF_DIFFERENT
)

add_library(Wintun::Wintun SHARED IMPORTED GLOBAL)
set_target_properties(Wintun::Wintun PROPERTIES
    IMPORTED_LOCATION "${WINTUN_DIR}/wintun.dll"
)
