# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

execute_process(COMMAND "${LINKER}" /dump /imports "${EXECUTABLE}"
    OUTPUT_VARIABLE imports RESULT_VARIABLE result ERROR_VARIABLE error)
if(NOT result EQUAL 0)
    message(FATAL_ERROR "Cannot inspect model test imports: ${error}")
endif()
if(imports MATCHES "partout[.]dll")
    message(FATAL_ERROR "Partout::Models must work without the Partout DLL")
endif()
