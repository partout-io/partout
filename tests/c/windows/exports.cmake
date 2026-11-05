# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

execute_process(COMMAND "${LINKER}" /dump /exports "${LIBRARY}"
    OUTPUT_VARIABLE exports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect DLL exports: ${error}")
endif()
# MSVC template instantiations start with ??$. Exporting them pulls private STL
# implementation code and long decorated names into the public export table.
if(exports MATCHES "\\?\\?\\$")
    message(FATAL_ERROR "The DLL exports private template instantiations")
endif()
if(NOT exports MATCHES "partout_version" OR exports MATCHES "\\?")
    message(FATAL_ERROR "The core DLL must export only its C API")
endif()
execute_process(COMMAND "${LINKER}" /dump /exports "${BACKEND}"
    OUTPUT_VARIABLE exports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect Windows DLL exports: ${error}")
endif()
if(exports MATCHES "\\?\\?\\$" OR exports MATCHES "partout_version")
    message(FATAL_ERROR "The Windows DLL exports private templates or the core API")
endif()
if(NOT exports MATCHES "FromJson@TaggedProfile" OR NOT exports MATCHES "windows_loop_current")
    message(FATAL_ERROR "The Windows DLL is missing its model or I/O API exports")
endif()
