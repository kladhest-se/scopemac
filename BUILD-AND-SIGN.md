# Build and sign ScopeMac with Apple's command-line tools

Run these commands in Terminal on the release Mac, where Xcode utilities can access the Developer ID private key. These native build/signing commands do not publish repository releases. For the unified GitHub/GitLab workflow, see [docs/RELEASING.md](docs/RELEASING.md).

## 1. Install/select the tools

Use an Apple Silicon Mac running macOS 14 or later. The project was built with Swift 6.1.2, compiling in Swift 5 language mode. Install Xcode or Apple's Command Line Tools:

```sh
xcode-select --install
```

If using full Xcode instead, select it (adjust the path if needed):

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

Open Xcode once and complete its first-launch setup/license prompts. Check the selected tools:

```sh
xcode-select -p
xcrun --find swiftc
xcrun swiftc --version
xcrun --find clang++
xcrun --find notarytool
```

## 2. Open the source directory

Clone the repository or extract a release source archive:

```sh
git clone https://github.com/kladhest-se/scopemac.git
cd scopemac
```

When building a published release, check out its tag (`git checkout v0.1`). For a source archive, `cd` into the extracted source directory instead. Do not run the following commands from `public-web/`.

## 3. Compile and package locally

```sh
./build.sh
./package.sh
open build/ScopeMac.app
```

`build.sh` invokes Apple's tools directly. The core commands are:

```sh
mkdir -p build
xcrun clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -I Dependencies/include -c Bridge/ScopeUSB.cpp -o build/ScopeUSB.o

xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -module-cache-path build/ModuleCache \
  -import-objc-header Bridge/ScopeUSB.h \
  Sources/*.swift Tests/*.swift build/ScopeUSB.o \
  -L Dependencies/lib -lusb-1.0 -lc++ \
  -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o build/ScopeMac
```

The bundled arm64 libusb header and dynamic library are used. `package.sh` assembles the app's Info.plist, executable, framework, icon, README, changelog and license resources, then applies an **ad-hoc local signature**. This step alone is not a Developer ID/notarized release. There is no `.xcodeproj` requirement; the scripts use the selected Xcode SDK and toolchain.

## 4. Run the tests

```sh
make test
```

Quit the running app before replacing its build. The tests do not replace checking the native interface and actual instrument.

## 5. Check your Developer ID certificate

```sh
security find-identity -v -p codesigning
```

Use a Developer ID Application identity matching your signing certificate, for example:

```text
Developer ID Application: Your Name (TEAMID)
```

It must include its private key in the local keychain. An Apple Development certificate or Developer ID Installer certificate is not the identity used to sign this app. Do not export or share private keys just to run these steps.

## 6. Store notarization credentials securely

If you already have a working profile, use that profile name. Otherwise run:

```sh
xcrun notarytool store-credentials ScopeMac-notary
```

Follow the local prompts for your developer Apple ID, Team ID and an Apple ID **app-specific password**, or use your App Store Connect API-key authentication. The command validates and saves credentials in Keychain. Keep credentials out of scripts and the repository.

## 7. Recommended: create the verified release with the script

From the source root:

```sh
export SCOPEMAC_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SCOPEMAC_NOTARY_PROFILE='ScopeMac-notary'
./release.sh
```

Use your existing profile name if different. Approve the legitimate macOS keychain prompt locally if shown. The script rebuilds/tests, signs and notarizes the app, creates ZIP/DMG packages, and independently signs, notarizes and staples the DMG. Both submissions must be `Accepted`. Only after successful verification does it produce:

```text
build/ScopeMac-0.1.dmg
build/ScopeMac-0.1.dmg.sha256
build/ScopeMac-0.1.zip
build/ScopeMac-0.1.zip.sha256
```

Apple submission results and `ScopeMac-distribution-verified.txt` remain private build evidence. They are not release attachments.

## 8. Verify the packages

The native script implements the app and disk-image signing sequence. Verify the final files locally:

```sh
codesign --verify --deep --strict build/ScopeMac.app
xcrun stapler validate build/ScopeMac.app
spctl --assess --type execute --verbose=2 build/ScopeMac.app
codesign --verify --strict build/ScopeMac-0.1.dmg
xcrun stapler validate build/ScopeMac-0.1.dmg
hdiutil verify build/ScopeMac-0.1.dmg
cd build
shasum -a 256 -c ScopeMac-0.1.dmg.sha256
shasum -a 256 -c ScopeMac-0.1.zip.sha256
cd ..
```

Install/test each format on a second Mac/account and test a real DSO2D15 before publishing. The coordinator also mounts the DMG read-only and checks the embedded app matches the verified app/ZIP. Do not modify a signed bundle or final package after verification.

## 9. Publish matching release bytes

Use `python3 scripts/release.py build`, `check` and `prepare` to create provenance and the exact four-file DMG/ZIP inventory, then review the manifest before explicitly publishing. See [docs/RELEASING.md](docs/RELEASING.md) for destination configuration, credentials, preflight and retry behavior. The standalone native commands above do not create the coordinator's provenance record or manifest.
