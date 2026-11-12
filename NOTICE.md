# ScopeMac third-party notices

ScopeMac is a new SwiftUI/Metal macOS application distributed under GPL-3.0-or-later; see LICENSE. USBTMC framing, DSO2D15 packet assembly, calibration, and control behavior were adapted from the experimental DSO2D15 additions developed in a local OpenHantek6022 checkout during this project. Those additions are not a claim of upstream OpenHantek6022 DSO2D15 support. ScopeMac does not use the OpenHantek Qt GUI or its FFTW runtime. This is not an official Hantek product.

OpenHantek6022: https://github.com/OpenHantek/OpenHantek6022 (GPL-3.0-or-later). Original project attribution and license are retained in the source distribution under ThirdParty/OpenHantek6022.

libusb 1.0.30 is bundled as an arm64 dynamic library. License: LGPL-2.1-or-later; copyright libusb contributors. https://libusb.info / source https://github.com/libusb/libusb/releases/tag/v1.0.30. The header includes the license notice. The library was copied from the libusb-package arm64 distribution; its install name was changed to @rpath/libusb-1.0.dylib for relocatable loading. There are no Qt or FFTW dependencies. Source is also available at https://github.com/libusb/libusb/tree/v1.0.30.

The app uses Apple's system SwiftUI, AppKit, Metal, MetalKit, Foundation and Swift runtime frameworks. These are not redistributed in this source package.

ScopeMac developer: Tommy Frossman. Project website: https://scopemac.kladhest.se . Repository: https://github.com/kladhest-se/scopemac .

Release credential lookup and source-push workflow are adapted from BitSkim’s MIT-licensed release tooling. Copyright (c) 2026 BitSkim contributors; see ThirdParty/BitSkim/LICENSE.
