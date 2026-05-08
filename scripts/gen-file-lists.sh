#!/bin/bash
partout=partout.cmake
partout_c=partout_c.cmake

set -e
cd Sources

echo 'set(PARTOUT_SOURCES' >${partout}
find . -name "*.swift" >>${partout}
echo ')' >>${partout}

echo 'set(PARTOUT_C_SOURCES' >${partout_c}
find . -name "*.c" >>${partout_c}
echo ')' >>${partout_c}
