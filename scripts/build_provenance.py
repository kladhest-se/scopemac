# SPDX-License-Identifier: GPL-3.0-or-later
"""Explicit release inputs, immutable file inventories and source archives."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import zipfile


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def digest(path):
    require(Path(path).is_file() and not Path(path).is_symlink(), 'Missing or symlinked file: ' + str(path))
    with open(path, 'rb') as stream:
        return stream_digest(stream)


def stream_digest(stream):
    h = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        h.update(block)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def atomic_json(path, value):
    path = Path(path)
    require(not path.is_symlink() and not path.parent.is_symlink(), 'Symlinked output')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    require(not temporary.is_symlink(), 'Symlinked temporary output')
    with open(temporary, 'wb') as stream:
        stream.write(canonical(value) + b'\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def read_json(path):
    require(Path(path).is_file() and not Path(path).is_symlink(), 'Missing or symlinked record: ' + str(path))
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON field: ' + key)
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=unique)


INPUT_DIRS = ('Sources', 'Bridge', 'Dependencies', 'Fixtures', 'Resources', 'ThirdParty',
              'Tools', 'public-web', 'scripts', 'tests', 'Tests', 'examples', 'docs')
REQUIRED = ('Sources/Version.swift', 'build.sh', 'package.sh', 'release.sh', 'test-usb.sh',
            'LICENSE', 'NOTICE.md', 'README.md', 'CHANGELOG.md', 'public-web/index.php')


def source_files(root):
    root = Path(root)
    files = []
    def add(path):
        require(not path.is_symlink(), 'Symlinked release input: ' + str(path.relative_to(root)))
        if path.name in {'.DS_Store', '__pycache__'} or path.suffix == '.pyc':
            return
        if path.is_dir():
            for child in sorted(path.iterdir()):
                add(child)
        else:
            require(path.is_file(), 'Non-regular release input')
            require(not re.search(r'(^\.env($|\.)|\.(p12|p8|pem|key|mobileprovision)$)', path.name, re.I),
                    'Credential-shaped file in release inputs')
            files.append(path.relative_to(root).as_posix())
    for path in sorted(root.iterdir()):
        if path.name in INPUT_DIRS or (path.is_file() and
                (path.suffix in {'.md', '.sh'} or path.name in {'Makefile', 'LICENSE', '.gitignore'})):
            add(path)
    require(all(name in files for name in REQUIRED), 'Required release source is missing')
    return sorted(files)


def source_state(root):
    entries = {name: {'sha256': digest(Path(root) / name),
                      'executable': bool((Path(root) / name).stat().st_mode & 0o111)}
               for name in source_files(root)}
    return {'sha256': hashlib.sha256(canonical(entries)).hexdigest(), 'files': entries}


def git(root, *args, optional=False):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    if result.returncode and not optional:
        detail = result.stderr.decode(errors='replace').lower()
        # Classify known failures without echoing URLs, credential-helper output or secrets.
        if 'could not resolve hostname' in detail or 'could not resolve host' in detail:
            hint = 'Cannot resolve the repository hostname; check DNS, VPN and the configured host.'
        elif 'host key verification failed' in detail:
            hint = 'SSH host key verification failed; verify the server fingerprint before connecting in Terminal.'
        elif 'permission denied (publickey' in detail:
            hint = 'The server rejected the SSH key; check which SSH account/key has repository access.'
        elif any(text in detail for text in ('repository not found', 'could not be found', "project you were looking for", 'does not appear to be a git repository')):
            hint = 'Repository not found or not visible to your Git account. Create the empty project or grant access; API tokens do not replace Git SSH access.'
        elif 'authentication failed' in detail or 'could not read username' in detail:
            hint = 'Git HTTPS authentication failed; check the Git credential helper and repository access.'
        elif 'timed out' in detail or 'connection refused' in detail:
            hint = 'Repository connection failed; check the host, SSH port, VPN and network.'
        elif 'non-fast-forward' in detail or 'fetch first' in detail:
            hint = 'Remote history differs; clone/import or reconcile it without force-pushing.'
        else:
            hint = 'Check repository access and tag state in Terminal; remote output is hidden to protect credentials.'
        raise ReleaseError('Git ' + args[0] + ' failed. ' + hint)
    return None if result.returncode else result.stdout.decode().strip()


def commit(root):
    if not (Path(root) / '.git').exists():
        return None
    require(Path(git(root, 'rev-parse', '--show-toplevel')).resolve() == Path(root).resolve(),
            'Release must run from the repository root')
    return git(root, 'rev-parse', 'HEAD')


def clean_checkout(root, expected):
    current = commit(root)
    require(current and current == expected, 'Publication requires the exact prepared Git commit')
    require(not git(root, 'status', '--porcelain', '--untracked-files=all'), 'Dirty or untracked files block publication')
    tracked = set(git(root, 'ls-files', '-z').split('\0'))
    require(set(source_files(root)) <= tracked, 'Every release input must be tracked, including ignored inputs')
    stages = git(root, 'ls-files', '--stage').splitlines()
    require(all(line.startswith(('100644 ', '100755 ')) for line in stages), 'Submodules and symlinked tracked inputs are unsupported')


def tree_hashes(root):
    root = Path(root)
    require(root.is_dir() and not root.is_symlink(), 'Missing or symlinked app bundle')
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'Symlinked app bundle entry')
        if path.is_file():
            result[path.relative_to(root).as_posix()] = digest(path)
    return result


def write_source(root, destination, state, record, version):
    prefix = 'scopemac-' + version + '/'
    with open(destination, 'wb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w') as archive:
            for name, entry in state['files'].items():
                data = (Path(root) / name).read_bytes()
                info = tarfile.TarInfo(prefix + name)
                info.size = len(data)
                info.mode = 0o755 if entry['executable'] else 0o644
                archive.addfile(info, io.BytesIO(data))
            data = canonical(record) + b'\n'
            info = tarfile.TarInfo(prefix + 'release-provenance.json')
            info.size = len(data)
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))


def verify_source(path, state, record, version):
    prefix = 'scopemac-' + version + '/'
    with tarfile.open(path, 'r:gz') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        expected = {prefix + name for name in state['files']} | {prefix + 'release-provenance.json'}
        require(len(names) == len(set(names)) and set(names) == expected, 'Source archive inventory differs')
        for member in members:
            require(member.isfile(), 'Non-regular source archive entry')
            name = member.name[len(prefix):]
            data = archive.extractfile(member)
            if name == 'release-provenance.json':
                require(data.read() == canonical(record) + b'\n', 'Source provenance differs')
            else:
                require(stream_digest(data) == state['files'][name]['sha256'], 'Source archive bytes differ')
                require(bool(member.mode & 0o111) == state['files'][name]['executable'], 'Source mode differs')


def write_website(root, destination, state):
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in state['files']:
            if name.startswith('public-web/'):
                info = zipfile.ZipInfo(name)
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, (Path(root) / name).read_bytes())


def verify_website(path, state):
    expected = {name for name in state['files'] if name.startswith('public-web/')}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and set(names) == expected, 'Website archive inventory differs')
        for info in archive.infolist():
            require((info.external_attr >> 16) & 0o170000 != 0o120000, 'Symlinked website asset')
            with archive.open(info) as stream:
                require(stream_digest(stream) == state['files'][info.filename]['sha256'], 'Website bytes differ')


def verify_inventory(directory, expected):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'Missing artifact directory')
    require({p.name for p in directory.iterdir()} == set(expected), 'Missing or unexpected release artifacts')
    for name, sha in expected.items():
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name), 'Unsafe artifact name')
        require(digest(directory / name) == sha, 'Changed release artifact: ' + name)
    for name in expected:
        if name.endswith('.sha256'):
            asset = name[:-7]
            require(asset in expected, 'Checksum has no matching release file')
            require((directory / name).read_text() == expected[asset] + '  ' + asset + '\n',
                    'Malformed or mismatched checksum file: ' + name)
