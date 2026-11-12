#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Distribution artifacts are accepted only after app and DMG notarization succeed.
set -eu
cd "$(dirname "$0")"
RELEASE_PYTHON="${SCOPEMAC_RELEASE_PYTHON:-python3}"
: "${SCOPEMAC_SIGN_IDENTITY:?Set the Developer ID Application identity name or SHA-1}"
: "${SCOPEMAC_NOTARY_PROFILE:?Set the authenticated notarytool keychain profile name}"
rm -f "$PWD/build/ScopeMac-distribution-verified.txt"
./build.sh
./package.sh
./build/ScopeMac.app/Contents/MacOS/ScopeMac --self-test --fixtures "$PWD/Fixtures"
./test-usb.sh
RELEASE_APP="$PWD/build/ScopeMac.app"
VERSION=$("$RELEASE_PYTHON" scripts/release_version.py marketing)
BUILD=$("$RELEASE_PYTHON" scripts/release_version.py build)
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_APP/Contents/Info.plist")" != "$VERSION" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE_APP/Contents/Info.plist")" != "$BUILD" ]]; then
    print -u2 'App bundle version differs from Sources/Version.swift'
    exit 1
fi
RELEASE_ZIP="$PWD/build/ScopeMac-${VERSION}.zip"
RELEASE_DMG="$PWD/build/ScopeMac-${VERSION}.dmg"
SUBMISSION_ZIP="$PWD/build/ScopeMac-notary-submission.zip"
check_notarization() {
    "$RELEASE_PYTHON" - "$1" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Inspect the private Apple submission result/log.')
PY
}
codesign --force --timestamp --options runtime --sign "$SCOPEMAC_SIGN_IDENTITY" "$RELEASE_APP/Contents/Frameworks/libusb-1.0.dylib"
codesign --force --timestamp --options runtime --sign "$SCOPEMAC_SIGN_IDENTITY" "$RELEASE_APP"
codesign --verify --deep --strict "$RELEASE_APP"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$SCOPEMAC_NOTARY_PROFILE" --wait --output-format json > build/notarization-result.json
check_notarization build/notarization-result.json
xcrun stapler staple "$RELEASE_APP"
xcrun stapler validate "$RELEASE_APP"
spctl --assess --type execute --verbose=2 "$RELEASE_APP"
ditto -c -k --sequesterRsrc --keepParent "$RELEASE_APP" "$RELEASE_ZIP"
# Package the very same stapled app with a drag-to-Applications shortcut.
DMG_STAGE=$(mktemp -d "$PWD/build/ScopeMac-dmg.XXXXXX")
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$RELEASE_APP" "$DMG_STAGE/ScopeMac.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -ov -fs HFS+ -format UDZO -volname "ScopeMac ${VERSION}" -srcfolder "$DMG_STAGE" "$RELEASE_DMG"
codesign --force --timestamp --sign "$SCOPEMAC_SIGN_IDENTITY" "$RELEASE_DMG"
codesign --verify --strict "$RELEASE_DMG"
xcrun notarytool submit "$RELEASE_DMG" --keychain-profile "$SCOPEMAC_NOTARY_PROFILE" --wait --output-format json > build/dmg-notarization-result.json
check_notarization build/dmg-notarization-result.json
xcrun stapler staple "$RELEASE_DMG"
xcrun stapler validate "$RELEASE_DMG"
hdiutil verify "$RELEASE_DMG"
(cd build; shasum -a 256 "${RELEASE_ZIP:t}" > "${RELEASE_ZIP:t}.sha256")
(cd build; shasum -a 256 "${RELEASE_DMG:t}" > "${RELEASE_DMG:t}.sha256")
{
    codesign --display --verbose=4 "$RELEASE_APP" 2>&1
    xcrun stapler validate "$RELEASE_APP"
    spctl --assess --type execute --verbose=2 "$RELEASE_APP"
    codesign --verify --strict "$RELEASE_DMG"
    xcrun stapler validate "$RELEASE_DMG"
    hdiutil verify "$RELEASE_DMG"
} > build/ScopeMac-distribution-verified.txt
printf '%s\n' "Verified distribution: $RELEASE_DMG" "Verified distribution: $RELEASE_ZIP"
