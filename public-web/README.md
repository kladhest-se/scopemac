# ScopeMac public website

Framework-free PHP website for https://scopemac.kladhest.se. Licensed under GPL-3.0-or-later; see the repository LICENSE.

## Run locally

Requires PHP 8.0 or newer:

```sh
php -S 127.0.0.1:8080 -t public-web
```

Open http://127.0.0.1:8080. No database, Composer, JavaScript, analytics, cookies or external font service is required.

## Screenshots

`assets/screenshots/` contains screenshots from ScopeMac 0.1:

- `waveform.png`: two channels, time cursors and measurement summaries.
- `fft.png`: frequency spectrum, selectable range and peak markers.
- `insights.png`: measurement trends and capture information.

All three show the actual app using synthetic Demo signals, not instrument captures. Each image links to its full-size version. Update screenshots when the corresponding interface changes; keep captions and alternative text consistent with the images.

## Hardware and connection guide

The compatibility table lists the DSO2D15 and tested firmware. Other models remain unverified. `assets/hardware/hantek-dso2d15.webp` is the product photo. `assets/hardware/scope-to-mac.png` illustrates the rear USB-B port, a USB data cable and an Apple Silicon Mac. It is a schematic product illustration, not a photograph of a connected instrument.

Connection instructions cover direct USB-C-to-USB-B cables and USB-A-to-USB-B cables used with a data-capable USB-C adapter or hub. The rear Type-B connection is documented in the linked Hantek DSO2000 series manual, Remote Control section.

## Deploy

Set the PHP host's document root to **public-web/**, or upload this directory's contents to the web root for scopemac.kladhest.se. Include the screenshot assets. Keep the rest of the repository outside the public document root and serve through HTTPS.

`index.php` sets security and content-type headers. Ensure the server executes PHP rather than serving it as a download. GitHub Pages does not execute PHP; use PHP-capable hosting. Download links point to GitHub Releases. Update repository links if the default branch changes from `main`.
