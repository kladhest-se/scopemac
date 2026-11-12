#!/bin/zsh
set -eu
cd "$(dirname "$0")"
RELEASE_PYTHON="${SCOPEMAC_RELEASE_PYTHON:-python3}"
DEPENDENCIES="${SCOPEMAC_DEPENDENCIES:-$PWD/Dependencies}"
MARKETING_VERSION=$("$RELEASE_PYTHON" scripts/release_version.py marketing)
BUILD_NUMBER=$("$RELEASE_PYTHON" scripts/release_version.py build)
DESTINATION="${1:-$PWD/build/ScopeMac.app}"
mkdir -p "$DESTINATION/Contents/MacOS" "$DESTINATION/Contents/Frameworks" "$DESTINATION/Contents/Resources"
cp build/ScopeMac "$DESTINATION/Contents/MacOS/ScopeMac"
cp "$DEPENDENCIES/lib/libusb-1.0.dylib" "$DESTINATION/Contents/Frameworks/"
cp Resources/AppIcon.icns "$DESTINATION/Contents/Resources/"
cp LICENSE NOTICE.md README.md CHANGELOG.md "$DESTINATION/Contents/Resources/"
cp -R ThirdParty "$DESTINATION/Contents/Resources/"
cat > "$DESTINATION/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleExecutable</key><string>ScopeMac</string>
<key>CFBundleIdentifier</key><string>local.scopemac.dso2d15</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>ScopeMac</string>
<key>CFBundleDisplayName</key><string>ScopeMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Tommy Frossman and contributors. GPL-3.0-or-later.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
echo "$DESTINATION"
