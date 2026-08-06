include_guard(GLOBAL)
include(FetchContent)

set(WINTUN_VERSION 0.14.1)
set(WINTUN_DIR "${PP_BUILD_OUTPUT}/wintun")

FetchContent_Declare(wintun
    URL "https://www.wintun.net/builds/wintun-${WINTUN_VERSION}.zip"
    URL_HASH "SHA256=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
    DOWNLOAD_EXTRACT_TIMESTAMP FALSE
)
FetchContent_MakeAvailable(wintun)

file(MAKE_DIRECTORY "${WINTUN_DIR}")
file(COPY_FILE
    "${wintun_SOURCE_DIR}/include/wintun.h"
    "${WINTUN_DIR}/wintun.h"
    ONLY_IF_DIFFERENT
)
file(COPY_FILE
    "${wintun_SOURCE_DIR}/bin/${ARCH_NAME}/wintun.dll"
    "${WINTUN_DIR}/wintun.dll"
    ONLY_IF_DIFFERENT
)
