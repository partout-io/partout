#!/bin/bash
if [[ $(uname -s) == "Darwin" ]]; then
    exec swiftly run swiftc "$@"
else
    ~/.local/share/swiftly/bin/swiftc "$@"
fi
