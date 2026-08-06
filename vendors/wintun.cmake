set(WINTUN_VERSION 0.14.1)
set(WINTUN_DIR "${PP_BUILD_OUTPUT}/wintun")

if(PP_USE_PREBUILT_VENDORS)
    if(NOT EXISTS "${WINTUN_DIR}/wintun.dll" OR NOT EXISTS "${WINTUN_DIR}/wintun.h")
        message(FATAL_ERROR "Prebuilt vendors output does not contain wintun in ${WINTUN_DIR}")
    endif()
    return()
endif()

FetchContent_Declare(wintun
    URL "https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip"
)
FetchContent_MakeAvailable(wintun)
file(COPY
    "${wintun_SOURCE_DIR}/include/wintun.h"
    "${wintun_SOURCE_DIR}/bin/${ARCH_NAME}/wintun.dll"
    DESTINATION "${WINTUN_DIR}"
)
