<?php
// SPDX-License-Identifier: GPL-3.0-or-later
// Public GitHub metadata only. Never put publishing credentials on the web server.
function scopemacRelease(?array $data): ?array
{
    $repo = 'https://github.com/kladhest-se/scopemac';
    if (!$data || ($data['draft'] ?? true) !== false
        || !is_string($data['tag_name'] ?? null) || $data['tag_name'] === '') {
        return null;
    }
    $tag = $data['tag_name'];
    $url = $repo . '/releases/tag/' . rawurlencode($tag);
    $assets = [];
    foreach (($data['assets'] ?? []) as $asset) {
        $name = $asset['name'] ?? '';
        $download = $asset['browser_download_url'] ?? '';
        if (is_string($name) && preg_match('/^ScopeMac-[0-9][A-Za-z0-9.+_-]*\.(?:dmg|zip)(?:\.sha256)?$/D', $name)
            && $download === $repo . '/releases/download/' . rawurlencode($tag) . '/' . rawurlencode($name)) {
            $assets[$name] = $download;
        }
    }
    ksort($assets);
    $date = is_string($data['published_at'] ?? null) ? strtotime($data['published_at']) : false;
    return ['tag' => $tag, 'url' => $url, 'date' => $date ? gmdate('Y-m-d', $date) : '', 'assets' => $assets, 'prerelease' => ($data['prerelease'] ?? false) === true];
}

function scopemacLatestRelease(): ?array
{
    $cache = sys_get_temp_dir() . '/scopemac-github-release-v2-' . substr(hash('sha256', __DIR__), 0, 16) . '.json';
    $cached = @file_get_contents($cache);
    $entry = $cached === false ? null : json_decode($cached, true);
    $release = scopemacRelease(is_array($entry['release'] ?? null) ? $entry['release'] : null);
    if (is_array($entry) && is_int($entry['checked'] ?? null) && time() - $entry['checked'] < 600) {
        return $release;
    }
    $endpoint = 'https://api.github.com/repos/kladhest-se/scopemac/releases?per_page=100';
    $headers = ['Accept: application/vnd.github+json', 'User-Agent: ScopeMac-website', 'X-GitHub-Api-Version: 2022-11-28'];
    $body = false;
    $status = 0;
    if (function_exists('curl_init')) {
        $curl = curl_init($endpoint);
        curl_setopt_array($curl, [CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $headers,
            CURLOPT_CONNECTTIMEOUT => 2, CURLOPT_TIMEOUT => 4, CURLOPT_FOLLOWLOCATION => false]);
        $body = curl_exec($curl);
        $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        curl_close($curl);
    } elseif (filter_var(ini_get('allow_url_fopen'), FILTER_VALIDATE_BOOLEAN)) {
        $context = stream_context_create(['http' => ['header' => implode("\r\n", $headers),
            'timeout' => 4, 'follow_location' => 0, 'ignore_errors' => true]]);
        $body = @file_get_contents($endpoint, false, $context, 0, 1048576);
        if (preg_match('/^HTTP\/\S+ (\d{3})/', $http_response_header[0] ?? '', $match)) {
            $status = (int)$match[1];
        }
    }
    $data = is_string($body) ? json_decode($body, true) : null;
    $selected = null;
    if (is_array($data)) {
        foreach ($data as $candidate) {
            if (is_array($candidate) && scopemacRelease($candidate)
                && ($selected === null || strcmp($candidate['published_at'] ?? '', $selected['published_at'] ?? '') > 0)) {
                $selected = $candidate;
            }
        }
    }
    $fresh = scopemacRelease($selected);
    if ($status === 200 && $fresh) {
        $release = $fresh;
    } elseif (($status === 404 || ($status === 200 && !$fresh))) {
        $release = null;
    }
    // Keep the last verified release during outages; cache failures to avoid repeated slow requests.
    $stored = ($status === 200 && $fresh) ? $selected : (($status === 404 || ($status === 200 && !$fresh)) ? null : ($entry['release'] ?? null));
    @file_put_contents($cache, json_encode(['checked' => time(), 'release' => $stored]), LOCK_EX);
    return $release;
}
