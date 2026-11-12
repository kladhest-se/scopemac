# ScopeMac 0.1

A native macOS app for the **Hantek DSO2D15** oscilloscope. Requires an Apple Silicon Mac with macOS 14 or later.

[Website](https://scopemac.kladhest.se) · [GitHub](https://github.com/kladhest-se/scopemac) · [Releases](https://github.com/kladhest-se/scopemac/releases) · [Report an issue](https://github.com/kladhest-se/scopemac/issues)

## Features

- Two-channel waveform capture and instrument controls.
- Measurements, FFT, cursors and reference traces.
- Snapshot recording, offline playback and trends.
- PNG chart and CSV sample export.
- Offline demo mode and three display themes.

## Connect

1. Download the DMG or ZIP from [Releases](https://github.com/kladhest-se/scopemac/releases), open/extract it, then move `ScopeMac.app` to Applications.
2. Power on the scope and connect its **rear USB-B port** to your Mac with a USB data cable. Use a USB-C adapter if needed.
3. Close other scope apps, click **Connect USB**, then choose **Live view** or **Capture**.

Choose **Demo** to explore without hardware. Captures are separate snapshots with gaps between them. **Pause view** pauses Mac downloads; **Run/Stop** controls the instrument. Use **Disconnect** when finished.

Version 0.1 is experimental and tested with DSO2D15 firmware `2.0.0(220831.00)`. Other models and firmware are unverified. ScopeMac is independent software and is not affiliated with Hantek.

## Build from source

With Xcode or Apple's Command Line Tools installed:

```sh
make package
open build/ScopeMac.app
```

Run `make test` for app/USB tests or `make release-tests` for release-tool tests. Local packages are ad-hoc signed.

See [Build and signing](BUILD-AND-SIGN.md), [Release guide](RELEASING.md), [Website setup](public-web/README.md) and [Changelog](CHANGELOG.md).

## License

Developed by Tommy Frossman. Licensed under [GPL-3.0-or-later](LICENSE). See [third-party notices](NOTICE.md) for OpenHantek6022, libusb and release-tool attribution.
