#!/bin/bash
submodule="vendors/core"
git submodule init $submodule
git submodule update --depth 1 $submodule
$submodule/scripts/create-framework.sh
