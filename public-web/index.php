<?php
// SPDX-License-Identifier: GPL-3.0-or-later
// PHP 8.0+. Public release metadata is cached server-side; no credentials required.
header('Content-Type: text/html; charset=UTF-8');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: strict-origin-when-cross-origin');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
$site = 'https://scopemac.kladhest.se';
$repo = 'https://github.com/kladhest-se/scopemac';
require_once __DIR__ . '/releases.php';
$latestRelease = scopemacLatestRelease();
function webEscape(string $value): string { return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
$version = $latestRelease ? webEscape($latestRelease['tag']) : '0.1';
$year = date('Y');
$supportedScopes = [
    ['model' => 'Hantek DSO2D15', 'status' => 'Supported · experimental', 'firmware' => '2.0.0(220831.00)'],
];
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="ScopeMac captures and explores Hantek DSO2D15 waveforms on Apple Silicon Macs running macOS 14 or later.">
  <meta name="theme-color" content="#101315">
  <meta property="og:title" content="ScopeMac <?= $version ?> — Hantek DSO2D15 for Mac">
  <meta property="og:description" content="A native, open-source macOS app for the Hantek DSO2D15.">
  <meta property="og:image" content="<?= $site ?>/assets/screenshots/waveform.png">
  <meta property="og:image:alt" content="ScopeMac waveform view with two synthetic demo channels">
  <meta property="og:type" content="website">
  <meta property="og:url" content="<?= $site ?>/">
  <link rel="canonical" href="<?= $site ?>/">
  <link rel="icon" type="image/svg+xml" href="assets/icon.svg">
  <link rel="stylesheet" href="assets/site.css">
  <title>ScopeMac <?= $version ?> — Hantek DSO2D15 for Mac</title>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="shell">
<header class="header">
  <a class="brand" href="./" aria-label="ScopeMac home"><img src="assets/icon.svg" width="30" height="30" alt=""><span>ScopeMac</span></a>
  <nav aria-label="Main navigation"><a href="#screenshots">Screenshots</a><a href="#details">Features</a><a href="#connect">Connect your scope</a><a class="nav-download" href="<?= $repo ?>/releases">Releases <span aria-hidden="true">↓</span></a></nav>
</header>
<main id="main">
<section class="hero" aria-labelledby="hero-title">
  <div class="eyebrow"><span class="status-dot"></span> SCOPEMAC <?= $version ?> · HANTEK DSO2D15</div>
  <h1 id="hero-title">A clearer view<br>of your <em>signal.</em></h1>
  <p class="intro">Your oscilloscope. Your Mac. A native workspace for capturing, exploring and saving waveforms.</p>
  <div class="actions"><a class="button primary" href="#download">Download ScopeMac <span aria-hidden="true">↓</span></a><a class="button secondary" href="<?= $repo ?>#build-from-source">Build it yourself <span aria-hidden="true">↗</span></a></div>
  <p class="requirements">Apple Silicon <span>·</span> macOS 14+ <span>·</span> Free & open source</p>
</section>
<section class="release-section" id="download" aria-labelledby="release-title">
  <span class="eyebrow">DOWNLOAD FOR MAC</span>
  <?php if ($latestRelease): ?>
  <h2 id="release-title">Latest release · <?= webEscape($latestRelease['tag']) ?></h2>
  <?php if ($latestRelease['date']): ?><p>Published <time datetime="<?= webEscape($latestRelease['date']) ?>"><?= webEscape($latestRelease['date']) ?></time> · Apple Silicon · macOS 14+</p><?php endif; ?>
  <ul class="release-assets">
  <?php foreach ($latestRelease['assets'] as $name => $url): ?>
    <li><a href="<?= webEscape($url) ?>"><?= webEscape($name) ?> <span aria-hidden="true">↓</span></a></li>
  <?php endforeach; ?>
  </ul>
  <a class="text-link" href="<?= webEscape($latestRelease['url']) ?>">Release notes and installation details ↗</a>
  <?php else: ?>
  <h2 id="release-title">ScopeMac releases</h2>
  <p>See GitHub for available builds and installation details.</p>
  <?php endif; ?>
  <p><a href="<?= $repo ?>/releases">All releases on GitHub ↗</a></p>
</section>
<section class="screenshots" id="screenshots" aria-labelledby="screenshots-title">
  <div class="preview-caption"><span>INSIDE SCOPEMAC 0.1</span><span class="capture-label">Real app · synthetic demo signals</span></div>
  <h2 id="screenshots-title" class="visually-hidden">See the app in action</h2>
  <figure class="screenshot-feature">
    <a href="assets/screenshots/waveform.png" aria-label="Open full-size waveform screenshot"><img src="assets/screenshots/waveform.png" width="2826" height="1626" alt="ScopeMac showing yellow CH1 pulses and a green CH2 sine wave, time cursors and channel measurements" fetchpriority="high"></a>
    <figcaption><strong>Two channels. One clear view.</strong><span>Two channels, time cursors and clear measurements.</span></figcaption>
  </figure>
  <div class="screenshot-grid">
    <figure>
      <a href="assets/screenshots/fft.png" aria-label="Open full-size FFT screenshot"><img src="assets/screenshots/fft.png" width="2826" height="1626" alt="ScopeMac FFT view with frequency peaks and a selectable 10 kHz range"></a>
      <figcaption><strong>Find the frequency story.</strong><span>Inspect either channel with FFT and peak markers.</span></figcaption>
    </figure>
    <figure>
      <a href="assets/screenshots/insights.png" aria-label="Open full-size capture insights screenshot"><img src="assets/screenshots/insights.png" width="2826" height="1626" alt="ScopeMac Capture Insights with measurement trends and detailed capture information"></a>
      <figcaption><strong>Follow changes over time.</strong><span>Track measurement trends and inspect capture details.</span></figcaption>
    </figure>
  </div>
  <p class="screenshot-note">ScopeMac 0.1 in Demo mode with synthetic signals. Select an image to enlarge.</p>
</section>
<section class="details" id="details" aria-label="Features">
  <article><span class="feature-number">01 / NATIVE</span><h2>Made for the Mac.</h2><p>Native Apple Silicon app with three display themes.</p></article>
  <article><span class="feature-number">02 / EXPLORE</span><h2>Look a little closer.</h2><p>Measurements, FFT, cursors and reference traces.</p></article>
  <article><span class="feature-number">03 / KEEP</span><h2>Capture. Revisit. Share.</h2><p>Record snapshots, replay sessions and export PNG or CSV.</p></article>
</section>
<section class="hardware-section" id="supported-scopes" aria-labelledby="hardware-title">
  <div class="hardware-photo"><img src="assets/hardware/hantek-dso2d15.webp" width="1000" height="1000" alt="Hantek DSO2D15 two-channel oscilloscope, front view with display, controls and probe inputs"><span>Hantek DSO2D15</span></div>
  <div class="hardware-copy"><span class="eyebrow">SUPPORTED HARDWARE</span><h2 id="hardware-title">Built around the DSO2D15.</h2><p>Supported hardware and tested firmware for ScopeMac 0.1.</p>
    <div class="support-table-wrap"><table class="support-table"><caption class="visually-hidden">ScopeMac 0.1 oscilloscope compatibility</caption><thead><tr><th scope="col">Oscilloscope</th><th scope="col">Status</th><th scope="col">Tested firmware</th></tr></thead><tbody>
    <?php foreach ($supportedScopes as $scope): ?>
      <tr><th scope="row"><?= htmlspecialchars($scope['model'], ENT_QUOTES, 'UTF-8') ?></th><td><?= htmlspecialchars($scope['status'], ENT_QUOTES, 'UTF-8') ?></td><td><code><?= htmlspecialchars($scope['firmware'], ENT_QUOTES, 'UTF-8') ?></code></td></tr>
    <?php endforeach; ?>
    </tbody></table></div>
    <p class="hardware-note">Other models and firmware versions are unverified.</p><a class="text-link" href="#connect">See how to connect <span aria-hidden="true">↓</span></a>
  </div>
</section>
<section class="connect-section" id="connect" aria-labelledby="connect-title">
  <div class="section-heading"><div><span class="eyebrow">FROM THE BENCH TO YOUR MAC</span><h2 id="connect-title">One USB cable. Start at the back.</h2></div><p>Use the square USB-B device socket on the lower rear panel of the scope. The rectangular USB-A port on the front is for USB storage.</p></div>
  <figure class="connection-figure"><a href="assets/hardware/scope-to-mac.png" aria-label="Open full-size scope-to-Mac connection illustration"><img src="assets/hardware/scope-to-mac.png" width="1536" height="1024" alt="Illustrated DSO2D15 rear with a mains power cord and highlighted USB-B data connection to an Apple Silicon iMac displaying ScopeMac"></a><figcaption>Connection illustration: rear USB-B on the scope to rear USB-C on the iMac.</figcaption></figure>
  <div class="cable-grid">
    <article><span class="feature-number">OPTION 01 / DIRECT</span><h3>USB-C → USB-B</h3><p>Use a USB-C-to-USB-B <strong>data cable</strong>. USB-B connects to the scope; USB-C connects to a rear iMac port.</p></article>
    <article><span class="feature-number">OPTION 02 / EXISTING CABLE</span><h3>USB-A → USB-B + adapter</h3><p>Use a USB-A-to-USB-B data cable with a data-capable USB-C adapter or hub. Macs with USB-A can connect directly.</p></article>
  </div>
  <ol class="connect-steps">
    <li><h3>Power on the scope</h3><p>Connect mains power and switch on the scope. USB carries data, not power for the instrument.</p></li>
    <li><h3>Connect the rear USB-B port</h3><p>Use the square socket low on the back, left of the mains inlet. Connect the other end to your Mac.</p></li>
    <li><h3>Open ScopeMac</h3><p>Close other scope apps and click <strong>Connect USB</strong>. The app includes its USB library.</p></li>
    <li><h3>Choose your view</h3><p>Choose <strong>Live view</strong> or <strong>Capture</strong>. Use <strong>Disconnect</strong> when finished.</p></li>
  </ol>
  <p class="connection-source">Connector reference: <a href="https://www.hantek.com/uploadpic/hantek/files/20210903/DSO2000%20Series%20Digital%20Storage%20Oscilloscope%20User%20Manual.pdf#page=57">Hantek DSO2000 series manual, Remote Control</a>. ScopeMac uses separate snapshots with gaps between captures.</p>
</section>
<section class="demo-section" aria-labelledby="demo-title">
  <div><span class="eyebrow">NO HARDWARE NEEDED</span><h2 id="demo-title">Try it without a scope.</h2></div>
  <div><p>Demo mode provides changing signals for measurements, FFT and recording. Instrument and trigger controls require a connected scope.</p></div>
</section>
<section class="closing" aria-labelledby="closing-title"><div><span class="eyebrow">OPEN TO EXPLORATION</span><h2 id="closing-title">A small app.<br>A useful addition to your bench.</h2></div><div><p>Connect the DSO2D15 through its rear USB port. ScopeMac downloads individual captures, with gaps between them.</p><a class="text-link" href="<?= $repo ?>">View the source on GitHub <span aria-hidden="true">↗</span></a><p class="preview-note">ScopeMac is experimental. See the latest release for builds and installation details.</p></div></section>
</main>
<footer><a class="brand" href="./"><img src="assets/icon.svg" width="23" height="23" alt=""><span>ScopeMac</span></a><p>© <?= htmlspecialchars($year, ENT_QUOTES, 'UTF-8') ?> Tommy Frossman</p><div><a href="<?= $repo ?>/blob/main/LICENSE">GPL v3 or later</a><a href="<?= $repo ?>/issues">Feedback ↗</a></div><small>Independent project. Not affiliated with Hantek.</small></footer>
</div>
</body>
</html>
