#! /bin/bash
set -e

git submodule update --recursive --init
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
ln -sf build/compile_commands.json $(pwd)/compile_commands.json
# ------

# gather informations
PROJECT_VERSION=$(cmake --system-information | awk -F= '$1~/CMAKE_PROJECT_VERSION:STATIC/{print$2}')

# modules development
cmake -B build-sdk -G Ninja -DCMAKE_BUILD_TYPE=Debug -DGPGFRONTEND_BUILD_TYPE_ONLY_SDK=On -DCMAKE_INSTALL_PREFIX=$(pwd)/modules/sdk/$PROJECT_VERSION
# Line 12 is dead weight, fails everywhere -- cannot be built standalone: toolchains, SDK headers, Qt setup, and output paths all come from the superproject's CMake.
# cmake -B modules/build -S modules -G Ninja -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX=$(pwd)/build/artifacts