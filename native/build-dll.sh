#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
mkdir -p bin
i686-w64-mingw32-g++ -D_WIN32_WINNT=0x0601 -std=c++17 -O2 -Wall -Wextra -shared -static-libgcc -static-libstdc++ dodge_native.cpp -o bin/IsaacDodgeNative.dll -Wl,--dynamicbase -Wl,--nxcompat
