# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline release checks. All publication APIs and tag pushes are mocked."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import release
import release_publish as pub
import build_provenance as prov
from release_version import version


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        external = patch.object(release, 'shared_config_path', return_value=self.root / 'machine/scopemac.json')
        external.start(); self.addCleanup(external.stop)
        for name in prov.REQUIRED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture\n')
        (self.root / 'Sources/Version.swift').write_text('static let marketing = "0.1"\nstatic let build = "1"\n')
        (self.root / 'CHANGELOG.md').write_text('# Changes\n\n## [0.1] — test\n\nRelease notes.\n')
        (self.root / '.gitignore').write_text('/build/\n/outputs/\n/work/\n__pycache__/\n')
        self.config = {**release.DEFAULTS, 'gitlab': 'https://gitlab.example.com/team/sub/scopemac',
                       'gitlab_git': 'git@gitlab.example.com:team/sub/scopemac.git', 'env': {}}
        self.tool = release.Release(self.root, self.config)

    def init_git(self):
        for args in (['init', '-q'], ['config', 'user.email', 'test@example.invalid'],
                     ['config', 'user.name', 'Release Test'], ['add', '.'], ['commit', '-qm', 'fixture']):
            subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True)
        return prov.commit(self.root)

    def mock_build(self):
        record = {'schema': 2, 'target': 'macos-arm64', 'status': 'experimental',
                  'version': '0.1', 'build': '1', 'commit': prov.commit(self.root),
                  'source_sha256': prov.source_state(self.root)['sha256'], 'archive_sha256': '',
                  'tools': {}, 'app_files': {}, 'notarization_sha256': '', 'verification_sha256': '', 'dmg_sha256': '', 'dmg_notarization_sha256': '',
                  'validation': {'automated_tests': 'passed', 'signing_notarization': 'passed',
                                 'physical_instrument_and_second_mac': 'manual'}}
        archive = self.root / 'build' / self.tool.names['app']
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b'verified-zip')
        record['archive_sha256'] = prov.digest(archive)
        dmg = self.root / 'build' / self.tool.names['dmg']; dmg.write_bytes(b'verified-dmg')
        record['dmg_sha256'] = prov.digest(dmg)
        for path in (archive, dmg):
            path.with_name(path.name + '.sha256').write_text(prov.digest(path) + '  ' + path.name + '\n')
        prov.atomic_json(self.tool.record_path, record)
        return record

    def prepared(self):
        record = self.mock_build()
        with patch.object(self.tool, 'verify_native'):
            self.tool.prepare()
        return record, prov.read_json(self.tool.manifest_path)


class IntegrityTests(Fixture):
    def test_plan_has_no_build_network_or_filesystem_writes(self):
        before = prov.source_state(self.root)
        with patch.object(release, 'ROOT', self.root), patch.object(release.subprocess, 'run', side_effect=AssertionError('ran command')):
            self.assertEqual(release.main(['plan']), 0)
        self.assertEqual(before, prov.source_state(self.root))
        self.assertFalse((self.root / 'build').exists())
        self.assertFalse((self.root / 'outputs').exists())
        self.assertEqual(self.tool.commands()[-1], ['./release.sh'])
        native = (Path(__file__).resolve().parents[1] / 'release.sh').read_text()
        for step in ('./build.sh', './package.sh', '--self-test', './test-usb.sh', 'notarytool submit', 'stapler validate'):
            self.assertIn(step, native)

    def test_single_version_source(self):
        self.assertEqual(version(self.root), ('0.1', '1'))
        text = (self.root / 'Sources/Version.swift').read_text()
        (self.root / 'Sources/Version.swift').write_text(text + text)
        with self.assertRaises(ValueError):
            version(self.root)

    def test_extract_can_prepare_but_cannot_publish(self):
        _, manifest = self.prepared()
        self.assertIsNone(manifest['commit'])
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_manifest(publish=True)

    def test_source_or_website_change_stales_build(self):
        self.mock_build()
        (self.root / 'public-web/index.php').write_text('caption changed')
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_build()

    def test_untracked_dirty_and_ignored_inputs_block(self):
        sha = self.init_git()
        prov.clean_checkout(self.root, sha)
        (self.root / 'untracked.txt').write_text('x')
        with self.assertRaises(prov.ReleaseError):
            prov.clean_checkout(self.root, sha)
        (self.root / 'untracked.txt').unlink()
        (self.root / 'README.md').write_text('changed')
        with self.assertRaises(prov.ReleaseError):
            prov.clean_checkout(self.root, sha)
        subprocess.run(['git', '-C', str(self.root), 'checkout', '--', 'README.md'], check=True)
        (self.root / '.git/info/exclude').write_text('Sources/ignored.swift\n')
        (self.root / 'Sources/ignored.swift').write_text('ignored build input')
        with self.assertRaises(prov.ReleaseError):
            prov.clean_checkout(self.root, sha)

    def test_prepared_release_contains_exactly_four_requested_files(self):
        record, manifest = self.prepared()
        with patch.object(self.tool, 'verify_native'):
            self.tool.check_manifest()
        expected = {'ScopeMac-0.1.dmg', 'ScopeMac-0.1.dmg.sha256',
                    'ScopeMac-0.1.zip', 'ScopeMac-0.1.zip.sha256'}
        self.assertEqual(set(manifest['files']), expected)
        self.assertEqual({p.name for p in self.tool.artifacts.iterdir()}, expected)
        self.assertIn('Release notes.', manifest['notes'])
        self.assertEqual(manifest['tag'], '0.1')
        for key in ('app', 'dmg'):
            path = self.tool.artifacts / self.tool.names[key]
            self.assertEqual(path.with_name(path.name + '.sha256').read_text(), prov.digest(path) + '  ' + path.name + '\n')

    def test_inventory_corrupt_missing_extra_symlink_and_duplicates(self):
        _, manifest = self.prepared()
        prov.verify_inventory(self.tool.artifacts, manifest['files'])
        asset = self.tool.artifacts / self.tool.names['app']
        original = asset.read_bytes()
        asset.write_bytes(b'changed')
        with self.assertRaises(prov.ReleaseError):
            prov.verify_inventory(self.tool.artifacts, manifest['files'])
        asset.unlink()
        with self.assertRaises(prov.ReleaseError):
            prov.verify_inventory(self.tool.artifacts, manifest['files'])
        asset.symlink_to(self.root / 'README.md')
        with self.assertRaises(prov.ReleaseError):
            prov.verify_inventory(self.tool.artifacts, manifest['files'])
        asset.unlink(); asset.write_bytes(original)
        extra = self.tool.artifacts / 'unexpected.zip'; extra.write_bytes(b'x')
        with self.assertRaises(prov.ReleaseError):
            prov.verify_inventory(self.tool.artifacts, manifest['files'])
        extra.unlink()
        sums = self.tool.artifacts / self.tool.names['app_checksum']
        sums.write_text(sums.read_text() * 2)
        hashes = {p.name: prov.digest(p) for p in self.tool.artifacts.iterdir()}
        with self.assertRaises(prov.ReleaseError):
            prov.verify_inventory(self.tool.artifacts, hashes)

    def test_modified_binary_and_bundle_are_rejected(self):
        record = self.mock_build()
        app = self.tool.app / 'Contents/MacOS/ScopeMac'
        app.parent.mkdir(parents=True)
        app.write_bytes(b'original')
        record.update(schema=2, version='0.1', build='1', target='macos-arm64', app_files=prov.tree_hashes(self.tool.app))
        app.write_bytes(b'modified')
        with self.assertRaises(prov.ReleaseError):
            self.tool.verify_native(record)
        app.write_bytes(b'original')
        (self.root / 'build' / self.tool.names['app']).write_bytes(b'changed zip')
        with self.assertRaises(prov.ReleaseError):
            self.tool.verify_native(record)

    def test_receipt_binds_exact_manifest(self):
        self.prepared()
        receipt = pub.receipt_for(self.tool.receipt_path, self.tool.manifest_path)
        prov.atomic_json(self.tool.receipt_path, receipt)
        self.tool.manifest_path.write_text('{}')
        with self.assertRaises(prov.ReleaseError):
            pub.receipt_for(self.tool.receipt_path, self.tool.manifest_path)

    def test_prepare_does_not_replace_active_receipt(self):
        self.prepared()
        prov.atomic_json(self.tool.receipt_path, {})
        with self.assertRaises(prov.ReleaseError):
            self.tool.prepare()

    def test_confirm_and_only_supported_destinations(self):
        with self.assertRaises(prov.ReleaseError):
            self.tool.publish(['github'], False)
        for bad in ('github,github', '', 'other', 'gitlab,'):
            with self.assertRaises(prov.ReleaseError):
                pub.destinations(bad)

    def test_secrets_and_local_settings_excluded(self):
        (self.root / 'work').mkdir()
        (self.root / 'work/release-config.json').write_text('secret')
        (self.root / '.env').write_text('SECRET=never-package-this')
        self.assertNotIn('work/release-config.json', prov.source_files(self.root))
        self.assertNotIn('.env', prov.source_files(self.root))
        (self.root / 'Sources/private.key').write_text('private')
        with self.assertRaises(prov.ReleaseError):
            prov.source_files(self.root)

    def test_configs_reject_tokens_and_mismatched_urls(self):
        config = self.root / 'local.json'
        for value in ({'token': 'never-log'}, {'env': {'GITHUB_TOKEN': 'never-log'}},
                      {'github': 'https://user:password@github.com/a/b'},
                      {'github_git': 'git@github.com:other/project.git'}):
            config.write_text(json.dumps(value))
            with self.assertRaises(prov.ReleaseError):
                release.config_file(self.root, config)
        for url in ('http://github.com/a/b', 'https://github.com/a/../b', 'https://github.com/a/b?q=token',
                    'https://github.com/a/%2e%2e/b', 'https://evil.example/a/b', 'https://github.com/a/b#fragment'):
            with self.assertRaises(prov.ReleaseError):
                pub.repository(url, 'github')
        self.assertEqual(pub.repository(self.config['gitlab'], 'gitlab')[1], 'team/sub/scopemac')

    def test_clean_commit_changed_manifest_destination(self):
        self.init_git()
        self.prepared()
        self.tool.config['github'] = 'https://github.com/other/project'
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_manifest()

    def test_archive_bundle_and_notarization_evidence_are_cross_checked(self):
        import plistlib
        record = self.mock_build()
        contents = self.tool.app / 'Contents'; contents.mkdir(parents=True)
        (contents / 'ScopeMac').write_bytes(b'compiled executable fixture')
        (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1', 'CFBundleVersion': '1'}))
        notarization = self.root / 'build/notarization-result.json'
        prov.atomic_json(notarization, {'status': 'Accepted'})
        evidence = self.root / 'build/ScopeMac-distribution-verified.txt'; evidence.write_text('fixture evidence')
        record['app_files'] = prov.tree_hashes(self.tool.app)
        record['notarization_sha256'] = prov.digest(notarization)
        dmg_notary = self.root / 'build/dmg-notarization-result.json'
        prov.atomic_json(dmg_notary, {'status': 'Accepted'})
        record['dmg_notarization_sha256'] = prov.digest(dmg_notary)
        record['verification_sha256'] = prov.digest(evidence)
        archive = self.root / 'build' / self.tool.names['app']
        with zipfile.ZipFile(archive, 'w') as zipped:
            for name in record['app_files']:
                zipped.write(self.tool.app / name, 'ScopeMac.app/' + name)
        record['archive_sha256'] = prov.digest(archive)
        archive.with_name(archive.name + '.sha256').write_text(record['archive_sha256'] + '  ' + archive.name + '\n')
        with patch.object(release, 'verify_dmg'), patch.object(self.tool, 'run') as native:
            self.tool.verify_native(record)
            self.assertEqual(native.call_count, 3)
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('ScopeMac.app/Contents/ScopeMac', b'wrong bytes')
        record['archive_sha256'] = prov.digest(archive)
        archive.with_name(archive.name + '.sha256').write_text(record['archive_sha256'] + '  ' + archive.name + '\n')
        with patch.object(self.tool, 'run') as native, self.assertRaises(prov.ReleaseError):
            self.tool.verify_native(record)
        native.assert_not_called()

    def test_changed_commit_requires_rebuild(self):
        self.init_git(); self.mock_build()
        subprocess.run(['git', '-C', str(self.root), 'commit', '--allow-empty', '-qm', 'new commit'], check=True)
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_build()

    def test_extra_source_or_website_attachment_blocks_publication(self):
        _, manifest = self.prepared()
        extra = self.tool.artifacts / 'website.zip'; extra.write_bytes(b'not allowed')
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_manifest()
        extra.unlink()
        manifest['files']['website.zip'] = '0' * 64
        prov.atomic_json(self.tool.manifest_path, manifest)
        with patch.object(self.tool, 'verify_native'), self.assertRaises(prov.ReleaseError):
            self.tool.check_manifest()

    def test_source_symlinks_and_duplicate_json_refused(self):
        link = self.root / 'Sources/link.swift'; link.symlink_to(self.root / 'README.md')
        with self.assertRaises(prov.ReleaseError):
            prov.source_state(self.root)
        path = self.root / 'record.json'; path.write_text('{"files":{},"files":{}}')
        with self.assertRaises(prov.ReleaseError):
            prov.read_json(path)

    def test_build_records_nothing_after_failed_or_mutating_build(self):
        config = {**self.config, 'env': {'SCOPEMAC_SIGN_IDENTITY': 'test identity'}, 'notary_profile': 'test profile'}
        tool = release.Release(self.root, config)
        with patch.object(tool, 'run', side_effect=prov.ReleaseError('build failed')):
            with self.assertRaises(prov.ReleaseError):
                tool.build()
        self.assertFalse(tool.record_path.exists())
        def mutate(command, capture=False):
            (self.root / 'README.md').write_text('changed during build')
        with patch.object(tool, 'run', side_effect=mutate):
            with self.assertRaises(prov.ReleaseError):
                tool.build()
        self.assertFalse(tool.record_path.exists())


class FakeGitHubHTTP:
    def __init__(self, m, existing=None, bad_upload=False):
        self.m = m; self.release = existing; self.items = []; self.events = []; self.bad_upload = bad_upload

    def json(self, method, url, value=None, missing=False):
        self.events.append((method, url))
        if '/assets?' in url:
            return self.items[:]
        if '/releases?' in url:
            return [self.release] if self.release else []
        if method == 'GET':
            return {'html_url': self.m['github'], 'permissions': {'push': True}}
        if method == 'POST':
            self.release = {**value, 'id': 7}
            return self.release
        if method == 'PATCH':
            if len(self.items) != len(self.m['files']):
                raise AssertionError('published before assets')
            self.release.update(value)
            return self.release
        raise AssertionError('unexpected API request')

    def upload(self, method, url, path):
        name = Path(path).name
        asset = {'name': name, 'state': 'uploaded',
                 'digest': None if self.bad_upload else 'sha256:' + self.m['files'][name]}
        self.items.append(asset)
        self.events.append(('upload', name))
        return asset


class FakeGitLabHTTP:
    def __init__(self, m):
        self.m = m; self.stored = {}; self.events = []; self.release = None; self.bad = False

    def json(self, method, url, value=None, missing=False):
        self.events.append((method, url))
        if '/releases/' in url:
            return self.release
        if method == 'POST':
            if len(self.stored) != len(self.m['files']):
                raise AssertionError('release advertised before verification')
            self.release = {'name': value['name'], 'description': value['description'],
                            'assets': value['assets'], 'commit': {'id': self.m['commit']}}
            return self.release
        return {'web_url': self.m['gitlab'], 'permissions': {'group_access': {'access_level': 40}}}

    def download_digest(self, url, missing=False):
        self.events.append(('download', url))
        return self.stored.get(url)

    def upload(self, method, url, path):
        self.events.append(('upload', url))
        self.stored[url] = 'bad' if self.bad else prov.digest(path)
        return {'message': '201 Created'}


class PublicationTests(Fixture):
    def manifest(self):
        self.tool.artifacts.mkdir(parents=True)
        (self.tool.artifacts / 'asset.zip').write_bytes(b'release')
        return {'version': '0.1', 'tag': 'v0.1', 'commit': 'a' * 40, 'notes': 'Notes',
                'files': {'asset.zip': prov.digest(self.tool.artifacts / 'asset.zip')},
                **{k: self.config[k] for k in ('github', 'github_git', 'gitlab', 'gitlab_git')}}

    def test_github_draft_verified_then_published_and_reused(self):
        m = self.manifest(); http = FakeGitHubHTTP(m)
        adapter = pub.GitHub(self.config, m, self.tool.artifacts, http)
        adapter.preflight(); adapter.publish()
        self.assertTrue(any(event[0] == 'upload' for event in http.events))
        self.assertFalse(http.release['draft'])
        http.events.clear(); adapter.preflight(); adapter.publish()
        self.assertFalse(any(event[0] == 'upload' for event in http.events))

    def test_unknown_or_conflicting_github_digest_never_publishes(self):
        m = self.manifest(); http = FakeGitHubHTTP(m, bad_upload=True)
        adapter = pub.GitHub(self.config, m, self.tool.artifacts, http)
        adapter.preflight()
        with self.assertRaises(prov.ReleaseError):
            adapter.publish()
        self.assertTrue(http.release['draft'])
        for sha in (None, 'sha256:bad'):
            http.items[0]['digest'] = sha
            with self.assertRaises(prov.ReleaseError):
                adapter.preflight()

    def test_github_conflicting_notes_and_extra_assets_block(self):
        m = self.manifest(); http = FakeGitHubHTTP(m, existing={'id': 1, 'tag_name': 'v0.1', 'name': 'v0.1',
                                  'body': 'Other notes', 'draft': True, 'prerelease': True})
        adapter = pub.GitHub(self.config, m, self.tool.artifacts, http)
        with self.assertRaises(prov.ReleaseError):
            adapter.preflight()
        http.release['body'] = 'Notes'; http.items = [{'name': 'extra'}]
        with self.assertRaises(prov.ReleaseError):
            adapter.preflight()

    def test_gitlab_downloads_verify_before_release_and_reuse(self):
        m = self.manifest(); http = FakeGitLabHTTP(m)
        adapter = pub.GitLab(self.config, m, self.tool.artifacts, http)
        adapter.preflight(); adapter.publish()
        self.assertTrue(http.release)
        upload_index = next(i for i, e in enumerate(http.events) if e[0] == 'upload')
        publish_index = next(i for i, e in enumerate(http.events) if e[0] == 'POST')
        self.assertTrue(any(e[0] == 'download' for e in http.events[upload_index + 1:publish_index]))
        http.events.clear(); adapter.preflight(); adapter.publish()
        self.assertFalse(any(e[0] == 'upload' for e in http.events))

    def test_gitlab_corrupt_upload_and_existing_conflict_block(self):
        m = self.manifest(); http = FakeGitLabHTTP(m); http.bad = True
        adapter = pub.GitLab(self.config, m, self.tool.artifacts, http)
        adapter.preflight()
        with self.assertRaises(prov.ReleaseError):
            adapter.publish()
        self.assertIsNone(http.release)
        with self.assertRaises(prov.ReleaseError):
            adapter.preflight()

    def test_tag_conflicts_and_annotated_resolution(self):
        with patch.object(pub, 'git', return_value='b' * 40 + '\trefs/tags/v0.1\n' + 'a' * 40 + '\trefs/tags/v0.1^{}'):
            self.assertTrue(pub.remote_tag(self.root, 'remote', 'v0.1', 'a' * 40))
        with patch.object(pub, 'git', return_value='b' * 40 + '\trefs/tags/v0.1'):
            with self.assertRaises(prov.ReleaseError):
                pub.remote_tag(self.root, 'remote', 'v0.1', 'a' * 40)
        with patch.object(pub, 'git', side_effect=['a' * 40, 'commit']):
            with self.assertRaises(prov.ReleaseError):
                pub.local_tag(self.root, 'v0.1', 'a' * 40)

    def test_all_preflights_before_push_and_receipt_survives_failure(self):
        m = self.manifest(); prov.atomic_json(self.tool.manifest_path, m)
        class Adapter:
            release = {'draft': False}
            def __init__(self, *args, **kwargs): pass
            def preflight(self): pass
            def publish(self): return {'url': 'verified'}
        class Fails(Adapter):
            def publish(self): raise prov.ReleaseError('simulated interruption')
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'test-token', 'GITLAB_TOKEN': 'test-token'}), \
             patch.object(pub, 'GitHub', Adapter), patch.object(pub, 'GitLab', Fails), \
             patch.object(pub, 'local_tag'), patch.object(pub, 'remote_tag', return_value=True), patch.object(pub, 'push_tag') as push:
            with self.assertRaises(prov.ReleaseError):
                pub.publish_all(self.root, self.config, m, self.tool.artifacts, self.tool.manifest_path,
                                self.tool.receipt_path, ['github', 'gitlab'], lambda: None)
            receipt = prov.read_json(self.tool.receipt_path)
            self.assertEqual(set(receipt['completed']), {'github'})
            self.assertEqual(receipt['current'], 'gitlab')
            push.reset_mock()
            with patch.object(pub, 'GitLab', Adapter):
                pub.publish_all(self.root, self.config, m, self.tool.artifacts, self.tool.manifest_path,
                                self.tool.receipt_path, ['github', 'gitlab'], lambda: None)
            self.assertEqual(push.call_count, 1)
        self.assertEqual(set(prov.read_json(self.tool.receipt_path)['completed']), {'github', 'gitlab'})

    def test_missing_tokens_and_preflight_failure_cannot_mutate(self):
        m = self.manifest(); prov.atomic_json(self.tool.manifest_path, m)
        with patch.dict(os.environ, {}, clear=True), patch.object(pub, 'push_tag') as push:
            with self.assertRaises(prov.ReleaseError):
                pub.publish_all(self.root, self.config, m, self.tool.artifacts, self.tool.manifest_path,
                                self.tool.receipt_path, ['github'], lambda: None)
            push.assert_not_called()
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'test', 'GITLAB_TOKEN': 'test'}), \
             patch.object(pub, 'local_tag') as local, patch.object(pub, 'remote_tag'), \
             patch.object(pub.GitHub, 'preflight'), patch.object(pub.GitLab, 'preflight', side_effect=prov.ReleaseError('conflict')), \
             patch.object(pub, 'push_tag') as push:
            with self.assertRaises(prov.ReleaseError):
                pub.publish_all(self.root, self.config, m, self.tool.artifacts, self.tool.manifest_path,
                                self.tool.receipt_path, ['github', 'gitlab'], lambda: None)
            push.assert_not_called()
            self.assertFalse(any(c.kwargs.get('create') for c in local.call_args_list))

    def test_http_never_sends_token_to_unexpected_host(self):
        http = pub.HTTP('gitlab.example.com', 'do-not-expose')
        with self.assertRaises(prov.ReleaseError) as caught:
            http.open('GET', 'https://other.example.com/api')
        self.assertNotIn('do-not-expose', str(caught.exception))
        self.assertNotIn('do-not-expose', json.dumps(self.config))

    def test_real_local_and_remote_annotated_tags_push_only_tag(self):
        sha = self.init_git()
        remote = self.root / 'bare.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        subprocess.run(['git', '-C', str(self.root), 'config', 'push.followTags', 'true'], check=True)
        pub.local_tag(self.root, 'unrelated-tag', sha, create=True)
        pub.local_tag(self.root, 'v0.1', sha, create=True)
        pub.push_tag(self.root, str(remote), {'tag': 'v0.1', 'commit': sha})
        self.assertTrue(pub.remote_tag(self.root, str(remote), 'v0.1', sha))
        unrelated = subprocess.run(['git', 'ls-remote', '--tags', str(remote), 'refs/tags/unrelated-tag'], check=True, capture_output=True).stdout
        self.assertEqual(unrelated, b'')
        heads = subprocess.run(['git', 'ls-remote', '--heads', str(remote)], check=True, capture_output=True).stdout
        self.assertEqual(heads, b'')
        with self.assertRaises(prov.ReleaseError):
            pub.remote_tag(self.root, str(remote), 'v0.1', 'b' * 40)

    def test_github_interrupted_draft_resumes_without_reupload(self):
        m = self.manifest()
        class Interrupt(FakeGitHubHTTP):
            fail = True
            def json(self, method, url, value=None, missing=False):
                if method == 'PATCH' and self.fail:
                    self.fail = False
                    raise prov.ReleaseError('network interruption')
                return super().json(method, url, value, missing)
        http = Interrupt(m); adapter = pub.GitHub(self.config, m, self.tool.artifacts, http)
        adapter.preflight()
        with self.assertRaises(prov.ReleaseError):
            adapter.publish()
        self.assertTrue(http.release['draft'])
        http.events.clear(); adapter.preflight(); adapter.publish()
        self.assertFalse(http.release['draft'])
        self.assertFalse(any(event[0] == 'upload' for event in http.events))

    def test_redirects_drop_credentials_and_errors_hide_response_bodies(self):
        import urllib.error
        http = pub.HTTP('gitlab.example.com', 'never-expose-this-token')
        class Response(io.BytesIO):
            def __init__(self, code, headers=None, data=b''):
                super().__init__(data); self.code = code; self.headers = headers or {}
        responses = [Response(302, {'Location': 'https://storage.example.com/signed?key=private'}), Response(200, data=b'file')]
        with patch.object(http, 'open', side_effect=responses) as requests:
            self.assertEqual(http.download_digest('https://gitlab.example.com/package'), hashlib.sha256(b'file').hexdigest())
            self.assertTrue(requests.call_args_list[0].kwargs['authenticated'])
            self.assertFalse(requests.call_args_list[1].kwargs['authenticated'])
        error = urllib.error.HTTPError('https://gitlab.example.com', 403, 'private response', {}, io.BytesIO(b'never-expose-this-token'))
        with patch.object(http.opener, 'open', side_effect=error), self.assertRaises(prov.ReleaseError) as caught:
            http.json('GET', 'https://gitlab.example.com/api')
        self.assertNotIn('never-expose-this-token', str(caught.exception))
        self.assertNotIn('private response', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
