# SPDX-FileCopyrightText: 2026 Davide De Rosa
#
# SPDX-License-Identifier: MIT

#!/bin/bash
if [[ $(uname -s) == "Darwin" ]]; then
    if ! command -v swiftly >/dev/null 2>&1; then
        echo "swiftly must be installed and available in PATH" >&2
        exit 1
    fi
    exec swiftly run swiftc "$@"
else
    swiftc_path="${HOME}/.local/share/swiftly/bin/swiftc"
    if [[ ! -x "${swiftc_path}" ]]; then
        echo "swiftc must exist and be executable at ${swiftc_path}" >&2
        exit 1
    fi
    exec "${swiftc_path}" "$@"
fi
