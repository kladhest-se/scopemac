#!/bin/zsh
set -eu
cd "$(dirname "$0")"
DEPENDENCIES="${SCOPEMAC_DEPENDENCIES:-$PWD/Dependencies}"
mkdir -p build
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 -I "$DEPENDENCIES/include" -c Bridge/ScopeUSB.cpp -o build/ScopeUSB.o
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path build/ModuleCache -import-objc-header Bridge/ScopeUSB.h Sources/*.swift Tests/*.swift build/ScopeUSB.o -L "$DEPENDENCIES/lib" -lusb-1.0 -lc++ -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o build/ScopeMac
