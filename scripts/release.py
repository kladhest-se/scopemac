#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare once; publish the reviewed, verified bytes to GitHub and GitLab."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

from build_provenance import (ReleaseError, atomic_json, canonical, clean_checkout, commit, digest,
                              read_json, require, source_state, tree_hashes, verify_inventory)
from release_version import version
from release_artifacts import names, verify_dmg
from release_credentials import validate_credentials
from release_source import branch_name, push_source
from release_publish import destinations, publish_all, receipt_for, repository, validate_git_url

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {'github': 'https://github.com/kladhest-se/scopemac',
            'github_git': 'git@github.com:kladhest-se/scopemac.git',
            'gitlab': None, 'gitlab_git': None, 'notary_profile': None, 'env': {},
            'credentials': {}, 'source_branch': ''}
ALLOWED_ENV = {'SCOPEMAC_SIGN_IDENTITY', 'SCOPEMAC_RELEASE_PYTHON', 'PHP'}


def shared_config_path():
    return Path.home() / 'Development/tools/git-release/projects/scopemac.json'


def config_file(root, path=None):
    override = path or os.environ.get('SCOPEMAC_RELEASE_CONFIG')
    shared = shared_config_path()
    candidate = Path(override).expanduser() if override else (shared if shared.exists() else Path(root) / 'work/release-config.json')
    config = dict(DEFAULTS)
    if override or candidate.exists():
        supplied = read_json(candidate)
        require(set(supplied) <= set(DEFAULTS), 'Unknown configuration key; do not store credentials in configuration')
        config.update(supplied)
    env = config.get('env')
    require(isinstance(env, dict) and set(env) <= ALLOWED_ENV and
            all(isinstance(v, str) and '\n' not in v and '\r' not in v for v in env.values()),
            'Only documented ScopeMac signing, release Python and PHP settings are allowed in config.env')
    require(not config.get('notary_profile') or (isinstance(config['notary_profile'], str)
            and '\n' not in config['notary_profile'] and '\r' not in config['notary_profile']), 'Invalid notary profile')
    validate_credentials(config.get('credentials'))
    require(isinstance(config.get('source_branch'), str), 'Invalid source branch configuration')
    if config['source_branch']:
        branch_name(root, config['source_branch'])
    if env.get('SCOPEMAC_RELEASE_PYTHON'):
        require(Path(env['SCOPEMAC_RELEASE_PYTHON']).is_absolute(), 'Release Python must be an absolute executable path')
    for name in ('github', 'gitlab'):
        require(bool(config.get(name)) == bool(config.get(name + '_git')), 'Configure both repository URLs for ' + name)
        if config.get(name):
            validate_git_url(config[name], config[name + '_git'], name)
    return config



class Release:
    def __init__(self, root, config, tag=None, tag_message=None):
        self.root = Path(root)
        self.config = config
        self.ver, self.build_number = version(root)
        self.requested_tag = tag
        self.requested_tag_message = tag_message
        self.tag = tag if tag is not None else self.ver
        require(self.tag in {self.ver, 'v' + self.ver}, 'Tag must match the current version, with optional v prefix')
        self.tag_message = tag_message if tag_message is not None else 'ScopeMac ' + self.tag
        require(isinstance(self.tag_message, str) and self.tag_message.strip() == self.tag_message and
                self.tag_message and '\x00' not in self.tag_message and len(self.tag_message) <= 16384, 'Invalid tag annotation')
        self.names = names(self.ver)
        self.output = self.root / 'outputs'
        self.artifacts = self.output / 'artifacts'
        self.record_path = self.root / 'build/provenance/macos.json'
        self.manifest_path = self.output / 'release/manifest.json'
        self.receipt_path = self.output / 'release/receipt.json'
        self.app = self.root / 'build/ScopeMac.app'

    def environment(self):
        require(not os.environ.get('SCOPEMAC_DEPENDENCIES'),
                'Unified releases use tracked Dependencies; external dependency overrides are unsupported')
        env = dict(os.environ)
        env.update(self.config['env'])
        # Builds do not need repository secrets, including custom token variable names.
        secret_variables = {'GITHUB_TOKEN', 'GITLAB_TOKEN'}
        secret_variables.update(spec.get('variable', service.upper() + '_TOKEN')
                                for service, spec in self.config.get('credentials', {}).items()
                                if spec.get('provider', 'env') == 'env')
        for key in secret_variables:
            env.pop(key, None)
        if self.config.get('notary_profile'):
            env['SCOPEMAC_NOTARY_PROFILE'] = self.config['notary_profile']
        return env

    def commands(self):
        php = self.config['env'].get('PHP', 'php')
        python = self.config['env'].get('SCOPEMAC_RELEASE_PYTHON') or os.environ.get('SCOPEMAC_RELEASE_PYTHON') or sys.executable
        return [[python, '-m', 'unittest', 'discover', '-s', 'tests', '-v'],
                [php, '-l', 'public-web/index.php'], ['./release.sh']]

    def run(self, command, capture=False):
        result = subprocess.run(command, cwd=self.root, env=self.environment(),
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
        require(result.returncode == 0, 'Command failed: ' + command[0] + '; no publication performed')
        return result.stdout.decode().strip() if capture else None

    def safe_outputs(self):
        for name in ('build', 'build/provenance', 'outputs', 'outputs/artifacts', 'outputs/release'):
            require(not (self.root / name).is_symlink(), 'Symlinked output directory: ' + name)

    def build(self):
        self.safe_outputs()
        require(not self.receipt_path.exists(), 'Existing publication receipt: preserve it; use a fresh checkout for a new release')
        env = self.environment()
        require(env.get('SCOPEMAC_SIGN_IDENTITY') and env.get('SCOPEMAC_NOTARY_PROFILE'),
                'Set SCOPEMAC_SIGN_IDENTITY and SCOPEMAC_NOTARY_PROFILE or local configuration')
        self.record_path.unlink(missing_ok=True)
        state = source_state(self.root)
        initial_commit = commit(self.root)
        if initial_commit:
            clean_checkout(self.root, initial_commit)
        for command in self.commands():
            self.run(command)
        require(source_state(self.root) == state and commit(self.root) == initial_commit,
                'Source or commit changed during the build; rebuild from stable inputs')
        tools = {}
        for tool in ('swiftc', 'clang++'):
            executable = Path(self.run(['xcrun', '--find', tool], capture=True)).resolve()
            tools[tool] = {'executable': executable.name, 'sha256': digest(executable),
                           'version': self.run(['xcrun', tool, '--version'], capture=True)}
        tools['macos_build'] = self.run(['sw_vers', '-buildVersion'], capture=True)
        tools['sdk_version'] = self.run(['xcrun', '--show-sdk-version'], capture=True)
        record = {'schema': 2, 'target': 'macos-arm64', 'status': 'experimental',
                  'version': self.ver, 'build': self.build_number, 'commit': commit(self.root),
                  'source_sha256': state['sha256'], 'tools': tools,
                  'app_files': tree_hashes(self.app),
                  'archive_sha256': digest(self.root / 'build' / self.names['app']),
                  'dmg_sha256': digest(self.root / 'build' / self.names['dmg']),
                  'dmg_notarization_sha256': digest(self.root / 'build/dmg-notarization-result.json'),
                  'notarization_sha256': digest(self.root / 'build/notarization-result.json'),
                  'verification_sha256': digest(self.root / 'build/ScopeMac-distribution-verified.txt'),
                  'validation': {'automated_tests': 'passed', 'signing_notarization': 'passed',
                                 'physical_instrument_and_second_mac': 'manual; not established by this build'}}
        self.verify_native(record)
        require(source_state(self.root) == state, 'Source changed during validation')
        atomic_json(self.record_path, record)
        print('Built experimental macOS arm64 target; physical runtime validation remains separate.')

    def verify_native(self, record):
        require(set(record) == {'schema', 'target', 'status', 'version', 'build', 'commit',
                'source_sha256', 'tools', 'app_files', 'archive_sha256', 'notarization_sha256',
                'verification_sha256', 'validation', 'dmg_sha256', 'dmg_notarization_sha256'}, 'Build record fields differ')
        require(record.get('status') == 'experimental' and
                record.get('validation', {}).get('automated_tests') == 'passed' and
                record.get('validation', {}).get('signing_notarization') == 'passed', 'Unverified build record')
        require(record.get('schema') == 2 and record.get('version') == self.ver and record.get('build') == self.build_number
                and record.get('target') == 'macos-arm64', 'Invalid build record/version')
        require(tree_hashes(self.app) == record['app_files'], 'Built app changed since signing')
        archive = self.root / 'build' / self.names['app']
        require(digest(archive) == record['archive_sha256'], 'Distribution ZIP changed since build')
        dmg = self.root / 'build' / self.names['dmg']
        require(digest(dmg) == record['dmg_sha256'], 'Distribution DMG changed since build')
        for kind, key in [('app', 'archive_sha256'), ('dmg', 'dmg_sha256')]:
            filename = self.names[kind]
            require((self.root / 'build' / (filename + '.sha256')).read_text() == record[key] + '  ' + filename + '\n',
                    'Distribution checksum file differs')
        for relative, key in [('build/notarization-result.json', 'notarization_sha256'),
                              ('build/dmg-notarization-result.json', 'dmg_notarization_sha256'),
                              ('build/ScopeMac-distribution-verified.txt', 'verification_sha256')]:
            require(digest(self.root / relative) == record[key], 'Release verification evidence changed')
        require(read_json(self.root / 'build/notarization-result.json').get('status') == 'Accepted',
                'Notarization was not accepted')
        require(read_json(self.root / 'build/dmg-notarization-result.json').get('status') == 'Accepted',
                'DMG notarization was not accepted')
        with open(self.app / 'Contents/Info.plist', 'rb') as stream:
            info = plistlib.load(stream)
        require(info['CFBundleShortVersionString'] == self.ver and info['CFBundleVersion'] == self.build_number,
                'App bundle version differs')
        # The ZIP must contain precisely the same app files checked by codesign.
        with zipfile.ZipFile(archive) as zipped:
            listed = zipped.namelist()
            require(len(listed) == len(set(listed)), 'Duplicate distribution ZIP entries')
            actual = {}
            for entry in zipped.infolist():
                path = Path(entry.filename)
                require(not path.is_absolute() and '..' not in path.parts, 'Unsafe distribution ZIP path')
                require((entry.external_attr >> 16) & 0o170000 != 0o120000, 'Symlinked ZIP asset')
                if entry.is_dir() or entry.filename.startswith('__MACOSX/'):
                    continue
                require(entry.filename.startswith('ScopeMac.app/'), 'Unexpected distribution ZIP content')
                with zipped.open(entry) as stream:
                    from build_provenance import stream_digest
                    actual[entry.filename[len('ScopeMac.app/'):]] = stream_digest(stream)
            require(actual == record['app_files'], 'ZIP app bytes differ from verified bundle')
        for command in (['codesign', '--verify', '--deep', '--strict', str(self.app)],
                        ['xcrun', 'stapler', 'validate', str(self.app)],
                        ['spctl', '--assess', '--type', 'execute', str(self.app)]):
            self.run(command, capture=True)
        verify_dmg(dmg, record['app_files'], self.run)
        # Gatekeeper above requires a distribution identity; ad-hoc local builds fail.

    def check_build(self):
        self.safe_outputs()
        record = read_json(self.record_path)
        require(record.get('commit') == commit(self.root), 'Build commit changed; rebuild before preparation')
        state = source_state(self.root)
        require(record.get('source_sha256') == state['sha256'], 'Stale source fingerprint; rebuild first')
        self.verify_native(record)
        require(source_state(self.root) == state, 'Source changed during verification')
        return state, record

    def notes(self, path=None):
        if path:
            candidate = Path(path).resolve()
            require(candidate.is_relative_to(self.root.resolve()), 'Release notes must be a release source input')
            relative = candidate.relative_to(self.root.resolve()).as_posix()
            require(relative in source_state(self.root)['files'], 'Release notes must be part of fingerprinted source')
            text = candidate.read_text().strip()
        else:
            text = (self.root / 'CHANGELOG.md').read_text()
            match = re.search(r'^## \[' + re.escape(self.ver) + r'\][^\n]*\n(.*?)(?=^## |^\[' + re.escape(self.ver) + r'\]:|\Z)',
                              text, flags=re.M | re.S)
            require(match is not None, 'No changelog section for current version')
            text = match.group(1).strip()
        require(text, 'Release notes cannot be empty')
        return 'ScopeMac ' + self.ver + ' — experimental macOS arm64 prerelease.\n\n' + text

    def prepare(self, notes=None):
        require(not self.receipt_path.exists(), 'Existing publication receipt: do not replace its prepared manifest')
        state, record = self.check_build()
        current = commit(self.root)
        if current:
            clean_checkout(self.root, current)
        text = self.notes(notes)
        if self.artifacts.exists():
            require(all(p.is_file() and not p.is_symlink() for p in self.artifacts.iterdir()), 'Unsafe previous artifact directory')
            shutil.rmtree(self.artifacts)
        self.artifacts.mkdir(parents=True)
        for name in self.names.values():
            shutil.copyfile(self.root / 'build' / name, self.artifacts / name)
        hashes = {p.name: digest(p) for p in sorted(self.artifacts.iterdir())}
        manifest = {'schema': 2, 'project': 'ScopeMac', 'version': self.ver, 'tag': self.tag, 'tag_message': self.tag_message,
                    'source_sha256': state['sha256'], 'commit': current,
                    'provenance_sha256': digest(self.record_path), 'notes': text, 'files': hashes,
                    'targets': {'macos-arm64': 'experimental'}, 'prerelease': True,
                    **{key: self.config[key] for key in ('github', 'github_git', 'gitlab', 'gitlab_git')}}
        require(source_state(self.root) == state, 'Source changed during preparation')
        verify_inventory(self.artifacts, hashes)
        atomic_json(self.manifest_path, manifest)
        self.check_manifest()
        print('Prepared outputs/release/manifest.json; review notes, hashes and destinations before publishing.')

    def check_manifest(self, publish=False):
        state, record = self.check_build()
        manifest = read_json(self.manifest_path)
        require(set(manifest) == {'schema', 'project', 'version', 'tag', 'tag_message', 'source_sha256', 'commit',
                'provenance_sha256', 'notes', 'files', 'targets', 'prerelease', 'github', 'github_git',
                'gitlab', 'gitlab_git'}, 'Unexpected or missing manifest fields')
        require(manifest.get('schema') == 2 and manifest.get('project') == 'ScopeMac' and
                manifest.get('version') == self.ver and manifest.get('tag') in {self.ver, 'v' + self.ver} and
                (self.requested_tag is None or manifest['tag'] == self.requested_tag) and
                manifest.get('source_sha256') == state['sha256'] and manifest.get('prerelease') is True and
                manifest.get('targets') == {'macos-arm64': 'experimental'}, 'Manifest no longer matches release')
        message = manifest.get('tag_message')
        require(isinstance(message, str) and message.strip() == message and message and '\x00' not in message,
                'Invalid prepared tag annotation')
        require(self.requested_tag_message is None or message == self.requested_tag_message,
                'Tag annotation differs from the prepared manifest')
        require(manifest.get('provenance_sha256') == digest(self.record_path), 'Build provenance changed')
        require(set(manifest['files']) == set(self.names.values()),
                'Manifest required artifact inventory differs')
        verify_inventory(self.artifacts, manifest['files'])
        require(digest(self.artifacts / self.names['app']) == record['archive_sha256'], 'Prepared ZIP differs from notarized ZIP')
        require(digest(self.artifacts / self.names['dmg']) == record['dmg_sha256'], 'Prepared DMG differs from notarized DMG')
        for key in ('github', 'github_git', 'gitlab', 'gitlab_git'):
            require(manifest.get(key) == self.config.get(key), 'Configuration destinations changed; prepare again')
        if publish:
            clean_checkout(self.root, manifest.get('commit'))
        if self.receipt_path.exists():
            receipt_for(self.receipt_path, self.manifest_path)
        require(source_state(self.root) == state, 'Source changed during manifest verification')
        return manifest

    def publish(self, selected, confirmed):
        require(confirmed, 'Publication requires --confirm-publish')
        manifest = self.check_manifest(publish=True)
        prepared_hash = digest(self.manifest_path)
        def revalidate():
            require(digest(self.manifest_path) == prepared_hash, 'Prepared manifest changed during publication')
            self.check_manifest(publish=True)
        publish_all(self.root, self.config, manifest, self.artifacts, self.manifest_path,
                    self.receipt_path, selected, revalidate)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['source', 'plan', 'build', 'check', 'prepare', 'publish', 'release'])
    parser.add_argument('--config', help='Non-secret JSON settings; defaults to SCOPEMAC_RELEASE_CONFIG, shared projects/scopemac.json, then work/release-config.json')
    parser.add_argument('--notes', help='Fingerprint-covered release notes file (prepare only)')
    parser.add_argument('--to', default='gitlab,github', help='Distinct comma-separated publication destinations')
    parser.add_argument('--confirm-publish', action='store_true')
    parser.add_argument('--confirm-push', action='store_true', help='Explicitly allow source branch uploads')
    parser.add_argument('--dry-run', action='store_true', help='Source push preflight only')
    parser.add_argument('--init', dest='initialize', action='store_true', help='Initialize source only after selected remotes are verified empty')
    parser.add_argument('--commit-message', help='First source commit message with source --init')
    parser.add_argument('--tag', help='Current version tag with optional v prefix (default: <version>)')
    parser.add_argument('--tag-message', help='Reviewed annotation for a newly created release tag')
    args = parser.parse_args(argv)
    try:
        require(not args.notes or args.command in {'prepare', 'release'}, '--notes applies only to prepare/release')
        require(not (args.confirm_push or args.dry_run or args.initialize or args.commit_message) or args.command == 'source',
                'Source push options apply only to source')
        require(not args.commit_message or args.initialize, '--commit-message requires --init')
        require(not args.confirm_publish or args.command in {'publish', 'release'}, '--confirm-publish applies only to publish/release')
        if args.command in {'publish', 'release'}:
            require(args.confirm_publish, 'Publication requires --confirm-publish')
        require(not (args.tag or args.tag_message) or args.command in {'plan', 'check', 'prepare', 'publish', 'release'},
                'Tag options apply to plan/check/prepare/publish/release')
        selected = destinations(args.to)
        release = Release(ROOT, config_file(ROOT, args.config), args.tag, args.tag_message)
        if args.command == 'plan':
            print('Target: macos-arm64 (experimental); tag: ' + release.tag)
            for command in release.commands():
                print(' '.join(command))
            print('Then verify notarized DMG/ZIP and prepare exactly those two files plus their .sha256 files.')
            print('Runtime checks on hardware/another Mac remain manual. No publication in plan/build/check/prepare.')
            return 0
        release.safe_outputs()
        # One operator per checkout. Never replace the lock inode during a run.
        lock = ROOT / 'build/release.lock'
        lock.parent.mkdir(exist_ok=True)
        require(not lock.is_symlink(), 'Symlinked release lock')
        with open(lock, 'a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.command == 'source':
                push_source(ROOT, release.config, selected, args.confirm_push, args.dry_run, args.initialize, args.commit_message)
            elif args.command == 'build':
                release.build()
            elif args.command == 'check':
                if release.manifest_path.exists():
                    release.check_manifest()
                else:
                    release.check_build()
                print('Release checks passed; hardware runtime testing is separate.')
            elif args.command == 'prepare':
                release.prepare(args.notes)
            else:
                # A combined release resumes an existing reviewed manifest/receipt unchanged.
                if args.command == 'release' and not release.manifest_path.exists():
                    release.prepare(args.notes)
                elif args.command == 'release' and args.notes:
                    require(release.check_manifest()['notes'] == release.notes(args.notes),
                            'Release notes differ from the prepared manifest')
                release.publish(selected, args.confirm_publish)
        return 0
    except (ReleaseError, ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile) as error:
        # Only local validation errors are descriptive; remote response bodies never enter logs.
        if isinstance(error, ReleaseError):
            print('Release refused: ' + str(error), file=sys.stderr)
        else:
            print('Release failed: invalid local input, unavailable tool or concurrent operator; inspect local files.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
