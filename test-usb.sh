#!/bin/zsh
set -eu
cd "$(dirname "$0")"
DEPENDENCIES="${SCOPEMAC_DEPENDENCIES:-$PWD/Dependencies}"
if [[ ! -f build/ScopeMac.app/Contents/Frameworks/libusb-1.0.dylib ]]; then
    print -u2 "Package the app first (make package), or run make test."
    exit 1
fi
mkdir -p build
xcrun clang++ -std=c++17 -O1 -g -fsanitize=address,undefined -I "$DEPENDENCIES/include" Tests/USBTransportTest.cpp -L "$DEPENDENCIES/lib" -lusb-1.0 -o build/USBTransportTest
DYLD_LIBRARY_PATH="$PWD/build/ScopeMac.app/Contents/Frameworks" ./build/USBTransportTest
