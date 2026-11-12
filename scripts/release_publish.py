# SPDX-License-Identifier: GPL-3.0-or-later
"""GitHub/GitLab publication with read-only preflight and verified uploads."""
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

from release_credentials import credential
from build_provenance import ReleaseError, atomic_json, canonical, digest, git, read_json, require, stream_digest


def repository(url, kind):
    require(isinstance(url, str), 'Repository URL is required for ' + kind)
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password
            and not parsed.query and not parsed.fragment and parsed.port is None,
            'Use a credential-free HTTPS repository URL without query, fragment or port')
    host = parsed.hostname
    require(re.fullmatch(r'[A-Za-z0-9.-]+', host) is not None and parsed.netloc == host,
            'Invalid repository host')
    parts = parsed.path.strip('/').split('/')
    require(all(re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', p) and p not in {'.', '..'} for p in parts),
            'Invalid repository path')
    require(not parsed.path.endswith('/') and not parsed.path.endswith('.git'), 'Use the repository web URL')
    if kind == 'github':
        require(host == 'github.com' and len(parts) == 2, 'GitHub destination must be github.com/owner/repo')
    else:
        require(host not in {'github.com', 'api.github.com', 'uploads.github.com'} and len(parts) >= 2,
                'Invalid GitLab destination')
    require(url == 'https://' + host + '/' + '/'.join(parts), 'Repository URL must be canonical')
    return host, '/'.join(parts)


def validate_git_url(web, remote, kind):
    host, path = repository(web, kind)
    allowed = {'git@' + host + ':' + path + '.git', 'ssh://git@' + host + '/' + path + '.git', web + '.git'}
    require(remote in allowed, 'HTTPS repository and Git push destination must match exactly')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class HTTP:
    def __init__(self, host, token, github=False):
        require(token and '\n' not in token and '\r' not in token, 'Missing or invalid API token')
        self.host = host
        self.token = token
        self.github = github
        self.opener = urllib.request.build_opener(NoRedirect())

    def headers(self, authenticated=True):
        result = {'User-Agent': 'ScopeMac-release', 'Accept': 'application/json'}
        if authenticated:
            result.update({'Authorization': 'Bearer ' + self.token, 'X-GitHub-Api-Version': '2026-03-10'}
                          if self.github else {'PRIVATE-TOKEN': self.token})
        return result

    def open(self, method, url, data=None, headers=None, missing=False, authenticated=True, redirects=False):
        p = urllib.parse.urlsplit(url)
        allowed = {'api.github.com', 'uploads.github.com'} if self.github else {self.host}
        require(p.scheme == 'https' and not p.username and not p.password and not p.fragment,
                'Unsafe API URL')
        require(not authenticated or p.hostname in allowed, 'Refusing to forward credentials to another host')
        try:
            return self.opener.open(urllib.request.Request(url, data=data, method=method,
                                   headers={**self.headers(authenticated), **(headers or {})}), timeout=120)
        except urllib.error.HTTPError as error:
            if redirects and error.code in {301, 302, 303, 307, 308}:
                return error
            if missing and error.code == 404:
                error.close()
                return None
            # Never print response bodies, authorization headers or signed download URLs.
            code = error.code
            error.close()
            raise ReleaseError('Remote request failed (HTTP ' + str(code) + '); inspect service permissions/state') from None
        except (OSError, urllib.error.URLError):
            raise ReleaseError('Network request failed; inspect remote state before resuming') from None

    def json(self, method, url, value=None, missing=False):
        data = None if value is None else canonical(value)
        with_response = self.open(method, url, data, {'Content-Type': 'application/json'}, missing)
        if with_response is None:
            return None
        with with_response as response:
            return json.load(response)

    def upload(self, method, url, path):
        with open(path, 'rb') as stream:
            with self.open(method, url, stream, {'Content-Type': 'application/octet-stream',
                                               'Content-Length': str(Path(path).stat().st_size)}) as response:
                return json.load(response)

    def download_digest(self, url, missing=False):
        # Generic package downloads can redirect to signed object-storage URLs. Follow
        # only HTTPS redirects, stripping authentication permanently on origin change.
        authenticated = True
        for _ in range(4):
            response = self.open('GET', url, headers={'Accept': 'application/octet-stream'},
                                 missing=missing, authenticated=authenticated, redirects=True)
            if response is None:
                return None
            if response.code in {301, 302, 303, 307, 308}:
                target = urllib.parse.urljoin(url, response.headers.get('Location', ''))
                response.close()
                parsed = urllib.parse.urlsplit(target)
                require(parsed.scheme == 'https' and parsed.hostname and not parsed.username
                        and not parsed.password and not parsed.fragment, 'Unsafe package redirect')
                if urllib.parse.urlsplit(url).netloc != parsed.netloc:
                    authenticated = False
                url = target
                continue
            with response:
                return stream_digest(response)
        raise ReleaseError('Too many package redirects')


class GitHub:
    def __init__(self, config, manifest, directory, http=None, token=None):
        self.m = manifest
        self.directory = Path(directory)
        host, path = repository(config['github'], 'github')
        self.base = 'https://api.github.com/repos/' + path
        self.upload_base = 'https://uploads.github.com/repos/' + path
        self.http = http or HTTP(host, token if token is not None else credential('github', config), github=True)
        self.release = None
        self.revalidate = lambda: None

    def find(self):
        # Listing includes drafts visible to the token, unlike relying on public tag lookup.
        found = []
        for page in range(1, 101):
            entries = self.http.json('GET', self.base + '/releases?per_page=100&page=' + str(page))
            found.extend(r for r in entries if r['tag_name'] == self.m['tag'])
            if len(entries) < 100:
                break
        else:
            raise ReleaseError('Too many GitHub releases to preflight safely')
        require(len(found) <= 1, 'Multiple GitHub releases have this tag')
        return found[0] if found else None

    def assets(self, release):
        assets = []
        for page in range(1, 101):
            entries = self.http.json('GET', self.base + '/releases/' + str(release['id']) + '/assets?per_page=100&page=' + str(page))
            assets.extend(entries)
            if len(entries) < 100:
                break
        else:
            raise ReleaseError('Too many GitHub assets')
        names = [a['name'] for a in assets]
        require(len(names) == len(set(names)), 'Duplicate GitHub assets')
        require(set(names) <= set(self.m['files']), 'Unexpected GitHub release assets')
        for asset in assets:
            self.verify_asset(asset)
        return {a['name']: a for a in assets}

    def verify_asset(self, asset):
        require(asset.get('name') in self.m['files'] and asset.get('state') == 'uploaded' and
                asset.get('digest') == 'sha256:' + self.m['files'].get(asset['name'], ''),
                'Unknown or conflicting GitHub asset digest: ' + asset['name'])

    def preflight(self):
        repo = self.http.json('GET', self.base)
        require(repo.get('html_url', '').lower() == self.m['github'].lower(), 'GitHub API repository differs')
        require(repo.get('permissions', {}).get('push') is True and not repo.get('archived'),
                'GitHub token needs repository write access')
        self.release = self.find()
        if self.release:
            require(self.release.get('body', '') == self.m['notes'] and
                    self.release.get('name') == self.m['tag'] and self.release.get('prerelease') is True,
                    'Existing GitHub release notes/name/prerelease differ')
            assets = self.assets(self.release)
            require(self.release.get('draft') or set(assets) == set(self.m['files']),
                    'Refusing to add missing assets to an already public release')

    def publish(self):
        release = self.release
        if release is None:
            release = self.http.json('POST', self.base + '/releases', {
                'tag_name': self.m['tag'], 'target_commitish': self.m['commit'],
                'name': self.m['tag'], 'body': self.m['notes'], 'draft': True, 'prerelease': True})
        present = self.assets(release)
        for name in self.m['files']:
            if name not in present:
                asset = self.http.upload('POST', self.upload_base + '/releases/' + str(release['id']) +
                                         '/assets?name=' + urllib.parse.quote(name, safe=''), self.directory / name)
                self.verify_asset(asset)
        require(set(self.assets(release)) == set(self.m['files']), 'GitHub asset inventory incomplete')
        self.revalidate()
        if release.get('draft'):
            result = self.http.json('PATCH', self.base + '/releases/' + str(release['id']), {'draft': False})
            require(result.get('draft') is False, 'GitHub draft publication was not confirmed')
        return {'url': self.m['github'] + '/releases/tag/' + self.m['tag']}


class GitLab:
    def __init__(self, config, manifest, directory, http=None, token=None):
        self.m = manifest
        self.directory = Path(directory)
        host, path = repository(config['gitlab'], 'gitlab')
        self.base = 'https://' + host + '/api/v4/projects/' + urllib.parse.quote(path, safe='')
        self.packages = self.base + '/packages/generic/scopemac/' + manifest['version'] + '/'
        self.http = http or HTTP(host, token if token is not None else credential('gitlab', config))
        self.release_url = self.base + '/releases/' + urllib.parse.quote(manifest['tag'], safe='')
        self.release = None
        self.revalidate = lambda: None

    def links(self):
        return [{'name': name, 'url': self.packages + urllib.parse.quote(name, safe=''), 'link_type': 'package'}
                for name in self.m['files']]

    def verify_release(self, release):
        require(release.get('description', '') == self.m['notes'] and release.get('name') == self.m['tag'],
                'Existing GitLab release notes/name differ')
        actual = release.get('assets', {}).get('links', [])
        names = [link['name'] for link in actual]
        require(len(names) == len(set(names)), 'Duplicate GitLab release links')
        require({(link['name'], link['url']) for link in actual} ==
                {(link['name'], link['url']) for link in self.links()}, 'Existing GitLab release links differ')
        require(release.get('commit', {}).get('id') == self.m['commit'], 'GitLab release commit differs')

    def preflight(self):
        project = self.http.json('GET', self.base)
        require(project.get('web_url') == self.m['gitlab'] and not project.get('archived'), 'GitLab repository differs or is archived')
        permissions = project.get('permissions') or {}
        access = max(((permissions.get(k) or {}).get('access_level', 0) for k in ('project_access', 'group_access')), default=0)
        require(access >= 30, 'GitLab token needs Developer or greater project/group access')
        require(project.get('packages_enabled', True) is True, 'GitLab packages are disabled')
        self.release = self.http.json('GET', self.release_url, missing=True)
        if self.release:
            self.verify_release(self.release)
        for name, expected in self.m['files'].items():
            actual = self.http.download_digest(self.packages + urllib.parse.quote(name, safe=''), missing=True)
            require(actual is None or actual == expected, 'Conflicting existing GitLab package: ' + name)
            require(not self.release or actual == expected, 'Existing GitLab release has missing package bytes')

    def publish(self):
        for name, expected in self.m['files'].items():
            url = self.packages + urllib.parse.quote(name, safe='')
            actual = self.http.download_digest(url, missing=True)
            require(actual is None or actual == expected, 'Conflicting GitLab package: ' + name)
            if actual is None:
                self.http.upload('PUT', url, self.directory / name)
            require(self.http.download_digest(url) == expected, 'GitLab upload failed checksum verification: ' + name)
        self.revalidate()
        if not self.release:
            self.http.json('POST', self.base + '/releases', {
                'tag_name': self.m['tag'], 'name': self.m['tag'], 'description': self.m['notes'],
                'assets': {'links': self.links()}})
        result = self.http.json('GET', self.release_url)
        self.verify_release(result)
        return {'url': self.m['gitlab'] + '/-/releases/' + self.m['tag']}


def remote_tag(root, remote, tag, expected):
    output = git(root, 'ls-remote', '--tags', remote, 'refs/tags/' + tag, 'refs/tags/' + tag + '^{}')
    refs = dict(line.split('\t')[::-1] for line in output.splitlines())
    if not refs:
        return False
    require(refs.get('refs/tags/' + tag + '^{}') == expected,
            'Remote tag differs or is not annotated; never move it')
    return True


def local_tag(root, tag, expected, create=False, message=None):
    ref = 'refs/tags/' + tag
    value = git(root, 'rev-parse', '--verify', ref, optional=True)
    if value is None:
        if create:
            git(root, 'tag', '-a', tag, expected, '-m', message or 'ScopeMac ' + tag)
        return
    require(git(root, 'cat-file', '-t', ref) == 'tag' and git(root, 'rev-parse', ref + '^{}') == expected,
            'Local tag differs or is not annotated; never move it')
    if message is not None:
        require(git(root, 'for-each-ref', '--format=%(contents)', ref) == message,
                'Local tag annotation differs from the reviewed manifest')


def push_tag(root, remote, manifest):
    tag, expected = manifest['tag'], manifest['commit']
    if not remote_tag(root, remote, tag, expected):
        git(root, 'push', '--no-follow-tags', '--', remote, 'refs/tags/' + tag + ':refs/tags/' + tag)
    require(remote_tag(root, remote, tag, expected), 'Remote tag verification failed')


def destinations(value):
    result = value.split(',')
    require(result and len(set(result)) == len(result) and all(k in {'github', 'gitlab'} for k in result),
            'Choose distinct destinations from gitlab,github')
    return result


def receipt_for(path, manifest_path):
    sha = digest(manifest_path)
    if Path(path).exists():
        receipt = read_json(path)
        require(receipt.get('manifest_sha256') == sha, 'Receipt belongs to another manifest; retain evidence and use a new release')
        require(isinstance(receipt.get('completed'), dict) and set(receipt['completed']) <= {'github', 'gitlab'},
                'Invalid publication receipt')
        return receipt
    return {'manifest_sha256': sha, 'current': None, 'completed': {}}


def publish_all(root, config, manifest, directory, manifest_path, receipt_path, selected, revalidate):
    receipt = receipt_for(receipt_path, manifest_path)
    require(not receipt.get('current') or receipt['current'] in {'github', 'gitlab'}, 'Invalid receipt destination')
    tokens = {}
    for name in selected:
        require(config.get(name) and config.get(name + '_git'), 'Configure the selected destination: ' + name)
        validate_git_url(config[name], config[name + '_git'], name)
        require(config[name] == manifest[name] and config[name + '_git'] == manifest[name + '_git'],
                'Destination changed since preparation')
        tokens[name] = credential(name, config)
    local_tag(root, manifest['tag'], manifest['commit'], message=manifest.get('tag_message'))
    adapters = {}
    # Every selected destination passes read-only preflight before any tag or upload.
    for name in selected:
        tag_exists = remote_tag(root, config[name + '_git'], manifest['tag'], manifest['commit'])
        adapter = (GitHub if name == 'github' else GitLab)(config, manifest, directory, token=tokens[name])
        adapter.preflight()
        adapter.revalidate = revalidate
        if name in receipt['completed']:
            require(tag_exists and adapter.release is not None and
                    (name != 'github' or not adapter.release.get('draft')),
                    'Completed receipt disagrees with remote tag/release state')
        adapters[name] = adapter
    revalidate()
    local_tag(root, manifest['tag'], manifest['commit'], create=True, message=manifest.get('tag_message'))
    for name in selected:
        if name in receipt['completed']:
            adapter = adapters[name]
            require(adapter.release is not None and (name != 'github' or not adapter.release.get('draft')),
                    'Completed receipt disagrees with remote release state')
            continue
        revalidate()
        receipt['current'] = name
        atomic_json(receipt_path, receipt)
        push_tag(root, config[name + '_git'], manifest)
        result = adapters[name].publish()
        receipt['completed'][name] = result
        receipt['current'] = None
        atomic_json(receipt_path, receipt)
        print('Completed ' + name)
    return receipt
