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
  <meta name="description" content="ScopeMac captures and explores oscilloscope waveforms on Apple Silicon Macs running macOS 14 or later.">
  <meta name="theme-color" content="#101315">
  <meta property="og:title" content="ScopeMac <?= $version ?> — Oscilloscope software for Mac">
  <meta property="og:description" content="A native, open-source macOS app for capturing and exploring oscilloscope waveforms.">
  <meta property="og:image" content="<?= $site ?>/assets/screenshots/waveform.png">
  <meta property="og:image:alt" content="ScopeMac waveform view with two synthetic demo channels">
  <meta property="og:type" content="website">
  <meta property="og:url" content="<?= $site ?>/">
  <link rel="canonical" href="<?= $site ?>/">
  <link rel="icon" type="image/svg+xml" href="assets/icon.svg">
  <link rel="stylesheet" href="assets/site.css?v=<?= substr(hash_file('sha256', __DIR__ . '/assets/site.css'), 0, 12) ?>">
  <title>ScopeMac <?= $version ?> — Oscilloscope software for Mac</title>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="shell">
<header class="header">
  <a class="brand" href="./" aria-label="ScopeMac home"><img src="assets/icon.svg" width="30" height="30" alt=""><span>ScopeMac</span></a>
  <nav aria-label="Main navigation"><a href="#screenshots">Screenshots</a><a href="#source">Source</a><a href="#connect">Connect your scope</a><a class="nav-download" href="#get">Get ScopeMac <span aria-hidden="true">↓</span></a></nav>
</header>
<main id="main">
<section class="hero" aria-labelledby="hero-title">
  <div class="eyebrow"><span class="status-dot"></span> SCOPEMAC <?= $version ?></div>
  <h1 id="hero-title">A clearer view<br>of your <em>signal.</em></h1>
  <p class="intro">Your oscilloscope. Your Mac. A native workspace for capturing, exploring and saving waveforms.</p>
  <div class="actions"><a class="button primary" href="#get">Download ScopeMac <span aria-hidden="true">↓</span></a><a class="button secondary" href="#source">Build it yourself <span aria-hidden="true">↗</span></a></div>
  <p class="requirements">Apple Silicon <span>·</span> macOS 14+ <span>·</span> Free & open source</p>
</section>
<section class="release-section" id="get" aria-labelledby="release-title">
  <span id="download" aria-hidden="true"></span>
  <span class="eyebrow">READY FOR YOUR WORKBENCH</span>
  <h2 id="release-title">Get ScopeMac.</h2>

  <div class="release-meta"><span>macOS 14+</span><span>Apple Silicon</span><span>Free · GPL v3 or later</span></div>
  <div class="download-panel">
  <?php if ($latestRelease): ?>
    <div class="download-heading"><img src="assets/icon.svg" width="64" height="64" alt=""><div><span class="eyebrow">NATIVE MAC APP</span><h3>ScopeMac <?= webEscape($latestRelease['tag']) ?><?= $latestRelease['prerelease'] ? ' · Prerelease' : '' ?></h3><?php if ($latestRelease['date']): ?><p>Published <time datetime="<?= webEscape($latestRelease['date']) ?>"><?= webEscape($latestRelease['date']) ?></time></p><?php endif; ?></div></div>
    <div class="download-options">
    <?php foreach (['dmg' => 'Download for macOS', 'zip' => 'Download ZIP'] as $extension => $label): ?>
      <?php foreach ($latestRelease['assets'] as $name => $url): if (!str_ends_with($name, '.' . $extension)) continue; ?>
      <div class="download-action"><a class="button <?= $extension === 'dmg' ? 'primary' : 'secondary' ?>" href="<?= webEscape($url) ?>"><?= $label ?> <span aria-hidden="true">↓</span></a><span class="download-filename"><?= webEscape($name) ?></span><?php if (isset($latestRelease['assets'][$name . '.sha256'])): ?><a class="checksum-link" href="<?= webEscape($latestRelease['assets'][$name . '.sha256']) ?>">SHA-256 checksum</a><?php endif; ?></div>
      <?php endforeach; ?>
    <?php endforeach; ?>
    </div>
    <?php if (!$latestRelease['assets']): ?><p>Downloads are being prepared. Check the release notes for availability.</p><?php endif; ?>
    <p>Open the DMG and drag ScopeMac into Applications. For ZIP, extract the app and move it into Applications.</p>
    <div class="release-links"><a href="<?= webEscape($latestRelease['url']) ?>">Release notes ↗</a><a href="<?= $repo ?>/archive/refs/tags/<?= rawurlencode($latestRelease['tag']) ?>.zip">Source ZIP</a><a href="<?= $repo ?>/releases">All releases ↗</a></div>
  <?php else: ?>
    <div class="download-heading"><img src="assets/icon.svg" width="64" height="64" alt=""><div><h3>ScopeMac for Mac</h3><p>Release information is currently unavailable.</p></div></div>
    <a class="button primary" href="<?= $repo ?>/releases">View latest release ↗</a>
  <?php endif; ?>
  </div>

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
  <div class="section-heading connection-heading"><div><span class="eyebrow">FROM THE BENCH TO YOUR MAC</span><h2 id="connect-title">One USB cable. Start at the back.</h2></div></div>
  <figure class="connection-figure"><a href="assets/hardware/scope-to-mac.png" aria-label="Open full-size scope-to-Mac connection illustration"><img src="assets/hardware/scope-to-mac.png" width="1536" height="1024" alt="Illustrated oscilloscope rear with a mains power cord and highlighted USB-B data connection to an Apple Silicon iMac displaying ScopeMac"></a></figure>
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
<section class="source-section" id="source" aria-labelledby="source-title">
  <span class="eyebrow">OPEN SOURCE · GPL v3 OR LATER</span>
  <h2 id="source-title">Build and run from source.</h2>
  <p>Use an Apple Silicon Mac running macOS 14 or later, with Xcode or Apple’s Command Line Tools and Python 3 installed. The USB library is included.</p>
  <details class="source-instructions" open>
    <summary>Get the code and build the app</summary>
    <div class="source-steps">
      <div><h3>1. Set up your Mac</h3><p>If you don’t already have Xcode or Command Line Tools, install the tools from Terminal:</p><pre><code>xcode-select --install</code></pre><p>Complete the installer before continuing. Check that Python 3 is available with <code>python3 --version</code>.</p></div>
      <div><h3>2. Get, build and run</h3><p>Clone the repository, then build and open the app:</p><pre><code>git clone https://github.com/kladhest-se/scopemac.git
cd scopemac
make package
open build/ScopeMac.app</code></pre><p>Choose <strong>Demo</strong> to explore without hardware, or connect your scope and choose <strong>Connect USB</strong>.</p></div>
    </div>
  </details>
  <p>To build a released version, check out its tag before running <code>make package</code>, for example <code>git switch --detach 0.1</code>. You can also download and extract the release’s Source ZIP, then open Terminal in the extracted folder.</p>
  <p>Local builds are ad-hoc signed; no Apple Developer account is required. Run <code>make test</code> to check the app and USB transport.</p>
  <div class="release-links"><a href="<?= $repo ?>">Browse source ↗</a><?php if ($latestRelease): ?><a href="<?= $repo ?>/archive/refs/tags/<?= rawurlencode($latestRelease['tag']) ?>.zip">Release source ZIP</a><?php endif; ?><a href="<?= $repo ?>/blob/main/BUILD-AND-SIGN.md">Build and signing guide ↗</a></div>
</section>
<section class="closing" aria-labelledby="closing-title"><div><span class="eyebrow">OPEN TO EXPLORATION</span><h2 id="closing-title">A small app.<br>A useful addition to your bench.</h2></div><div><a class="text-link" href="<?= $repo ?>">View the source on GitHub <span aria-hidden="true">↗</span></a></div></section>
</main>
<footer><a class="brand" href="./"><img src="assets/icon.svg" width="23" height="23" alt=""><span>ScopeMac</span></a><p>© <?= htmlspecialchars($year, ENT_QUOTES, 'UTF-8') ?> Tommy Frossman</p><div><a href="<?= $repo ?>/blob/main/LICENSE">GPL v3 or later</a><a href="<?= $repo ?>/issues">Feedback ↗</a></div><small>Independent project. Not affiliated with Hantek.</small></footer>
</div>
</body>
</html>
