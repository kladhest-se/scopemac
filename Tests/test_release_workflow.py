# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared profile, credentials and source workflow; no remote services are contacted."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
from unittest.mock import patch

from test_release import Fixture
import build_provenance as prov
import release
import release_credentials as creds
import release_source as source
import release_publish as pub


class SharedWorkflowTests(Fixture):
    def settings(self, value):
        path = self.root / 'work/settings.json'
        prov.atomic_json(path, value)
        return path

    def test_shared_profile_precedence_explicit_and_environment_override(self):
        shared = release.shared_config_path()
        prov.atomic_json(shared, {'source_branch': 'shared-main'})
        self.assertEqual(release.config_file(self.root)['source_branch'], 'shared-main')
        local = self.settings({'source_branch': 'other-main'})
        with patch.dict(os.environ, {'SCOPEMAC_RELEASE_CONFIG': str(local)}):
            self.assertEqual(release.config_file(self.root)['source_branch'], 'other-main')
            explicit = self.root / 'explicit.json'
            prov.atomic_json(explicit, {'source_branch': 'explicit-main'})
            self.assertEqual(release.config_file(self.root, explicit)['source_branch'], 'explicit-main')
        shared.unlink()
        prov.atomic_json(self.root / 'work/release-config.json', {'source_branch': 'local-main'})
        self.assertEqual(release.config_file(self.root)['source_branch'], 'local-main')

    def test_plan_uses_dedicated_python_without_commands_or_secret_lookup(self):
        path = self.settings({'source_branch': 'main',
            'env': {'SCOPEMAC_RELEASE_PYTHON': '/test/bin/python', 'PHP': '/test/bin/php'},
            'credentials': {'github': {'provider': '1password', 'reference': 'op://Private/github/project-rw'}}})
        with patch.object(release, 'ROOT', self.root), \
             patch.object(subprocess, 'run', side_effect=AssertionError('plan launched a process')), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(release.main(['plan', '--config', str(path)]), 0)
        self.assertIn('/test/bin/python -m unittest', output.getvalue())
        self.assertIn('/test/bin/php -l', output.getvalue())
        self.assertNotIn('op://', output.getvalue())
        self.assertFalse((self.root / 'build').exists())

    def test_build_environment_excludes_api_secrets_including_custom_variables(self):
        self.tool.config['credentials'] = {'github': {'provider': 'env', 'variable': 'CUSTOM_REPO_TOKEN'}}
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'secret-gh', 'GITLAB_TOKEN': 'secret-gl', 'CUSTOM_REPO_TOKEN': 'secret-custom'}):
            env = self.tool.environment()
        for name in ('GITHUB_TOKEN', 'GITLAB_TOKEN', 'CUSTOM_REPO_TOKEN'):
            self.assertNotIn(name, env)

    def test_environment_credentials_and_missing_or_unresolved_values(self):
        with patch.dict(os.environ, {'CUSTOM_REPO_TOKEN': 'fixture-token'}):
            self.assertEqual(creds.credential('github', {'credentials': {'github': {'variable': 'CUSTOM_REPO_TOKEN'}}}), 'fixture-token')
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(prov.ReleaseError):
            creds.credential('github', {})
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'op://Private/item/field'}), self.assertRaises(prov.ReleaseError):
            creds.credential('github', {})

    def test_1password_reference_and_field_lookup_never_print_secrets(self):
        token = 'fixture-private-api-token'
        config = {'credentials': {'github': {'provider': '1password', 'reference': 'op://Private/item/field', 'account': ''}}}
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=token)) as run, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(creds.credential('github', config), token)
        self.assertEqual(run.call_args.args[0], ['op', 'read', '--no-newline', 'op://Private/item/field'])
        self.assertNotIn(token, output.getvalue())
        spec = {'provider': '1password', 'vault': 'Private', 'item': 'github.com', 'field': 'group/scopemac-rw'}
        result = json.dumps({'label': spec['field'], 'value': token})
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=result)) as run:
            self.assertEqual(creds.credential('github', {'credentials': {'github': spec}}), token)
        self.assertIn('label=group/scopemac-rw', run.call_args.args[0])
        duplicate = json.dumps([{'label': spec['field'], 'value': token}] * 2)
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=duplicate)), self.assertRaises(prov.ReleaseError) as caught:
            creds.credential('github', {'credentials': {'github': spec}})
        self.assertNotIn(token, str(caught.exception))

    def test_secret_lookup_failure_and_invalid_descriptors_fail_closed(self):
        config = {'credentials': {'github': {'provider': '1password', 'reference': 'op://Private/item/field'}}}
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='never-log', stderr='never-log')), self.assertRaises(prov.ReleaseError) as caught:
            creds.credential('github', config)
        self.assertNotIn('never-log', str(caught.exception))
        for spec in ({'provider': '1password', 'reference': 'https://example.com'},
                     {'provider': '1password', 'vault': 'Private'}, {'provider': 'env', 'token': 'no'},
                     {'provider': 'env', 'variable': 'BAD\nNAME'}):
            with self.assertRaises(prov.ReleaseError):
                creds.validate_credentials({'github': spec})

    def test_credential_descriptors_are_not_published_in_manifest_or_source(self):
        self.tool.config['credentials'] = {'github': {'provider': '1password', 'reference': 'op://Private/item/fixture-field'}}
        self.settings(self.tool.config)
        _, manifest = self.prepared()
        self.assertNotIn('credentials', manifest)
        self.assertNotIn('op://', self.tool.manifest_path.read_text())
        self.assertNotIn('work/settings.json', prov.source_files(self.root))

    def test_source_confirmation_and_dry_run_never_initialize(self):
        with patch.object(source, 'git') as git:
            with self.assertRaises(prov.ReleaseError):
                source.push_source(self.root, self.config, ['github'])
            with self.assertRaises(prov.ReleaseError):
                source.push_source(self.root, self.config, ['github'], dry_run=True, initialize=True)
            git.assert_not_called()
        self.assertFalse((self.root / '.git').exists())

    def test_source_dry_run_and_confirmed_push_have_no_tags_or_builds(self):
        sha = self.init_git()
        real_git = source.git
        calls = []
        def git(root, *args, **kwargs):
            if args[0] == 'push':
                calls.append(args); return ''
            if args[:2] == ('ls-remote', '--heads'):
                return sha + '\trefs/heads/main'
            return real_git(root, *args, **kwargs)
        self.config['source_branch'] = 'main'
        with patch.object(source, 'git', side_effect=git):
            source.push_source(self.root, self.config, ['github', 'gitlab'], dry_run=True)
            self.assertEqual(len(calls), 2)
            self.assertTrue(all('--dry-run' in c for c in calls))
            calls.clear()
            source.push_source(self.root, self.config, ['github', 'gitlab'], confirmed=True)
        self.assertEqual(len(calls), 4)
        self.assertTrue(all('--no-follow-tags' in c and not any('refs/tags/' in a for a in c) for c in calls))
        self.assertFalse((self.root / 'outputs').exists())

    def test_all_source_preflights_pass_before_first_push(self):
        self.init_git()
        real_git = source.git; calls = []
        def git(root, *args, **kwargs):
            if args[0] == 'push':
                calls.append(args)
                if len(calls) == 2:
                    raise prov.ReleaseError('simulated non-fast-forward')
                return ''
            return real_git(root, *args, **kwargs)
        with patch.object(source, 'git', side_effect=git), self.assertRaises(prov.ReleaseError):
            source.push_source(self.root, self.config, ['github', 'gitlab'], confirmed=True)
        self.assertTrue(all('--dry-run' in c for c in calls))

    def test_initialization_refuses_nonempty_remote_without_creating_git(self):
        real_git = source.git
        def git(root, *args, **kwargs):
            if args[:2] == ('ls-remote', '--refs'):
                return 'a' * 40 + '\trefs/heads/main'
            return real_git(root, *args, **kwargs)
        with patch.object(source, 'git', side_effect=git), self.assertRaises(prov.ReleaseError):
            source.initialize_source(self.root, self.config, {'github': self.config['github_git']})
        self.assertFalse((self.root / '.git').exists())

    def test_first_commit_stages_public_inputs_but_not_local_configuration(self):
        local = self.settings({'credentials': {'github': {'variable': 'PRIVATE_TOKEN'}}})
        real_git = source.git
        def git(root, *args, **kwargs):
            if args[:2] == ('ls-remote', '--refs'):
                return ''
            return real_git(root, *args, **kwargs)
        identity = {'GIT_AUTHOR_NAME': 'Release Test', 'GIT_AUTHOR_EMAIL': 'test@example.invalid',
                    'GIT_COMMITTER_NAME': 'Release Test', 'GIT_COMMITTER_EMAIL': 'test@example.invalid'}
        with patch.dict(os.environ, identity), patch.object(source, 'git', side_effect=git):
            source.initialize_source(self.root, self.config, {'github': self.config['github_git']})
        tracked = prov.git(self.root, 'ls-files')
        self.assertIn('Sources/Version.swift', tracked)
        self.assertNotIn('settings.json', tracked)
        self.assertTrue(local.exists())
        prov.clean_checkout(self.root, prov.commit(self.root))

    def test_initialization_refuses_previously_staged_private_files(self):
        for args in (['init', '-q'], ['config', 'user.name', 'Release Test'],
                     ['config', 'user.email', 'test@example.invalid']):
            subprocess.run(['git', '-C', str(self.root), *args], check=True, capture_output=True)
        private = self.root / 'private.key'; private.write_text('fixture-private-key')
        subprocess.run(['git', '-C', str(self.root), 'add', 'private.key'], check=True)
        real_git = source.git
        def git(root, *args, **kwargs):
            if args[:2] == ('ls-remote', '--refs'):
                return ''
            return real_git(root, *args, **kwargs)
        with patch.object(source, 'git', side_effect=git), self.assertRaises(prov.ReleaseError):
            source.initialize_source(self.root, self.config, {'github': self.config['github_git']})
        self.assertIsNone(prov.git(self.root, 'rev-parse', '--verify', 'HEAD', optional=True))

    def test_custom_version_tag_and_reviewed_annotation_are_bound_to_manifest(self):
        self.tool = release.Release(self.root, self.config, tag='0.1', tag_message='ScopeMac 0.1 preview')
        self.prepared()
        plain = release.Release(self.root, self.config)
        with patch.object(plain, 'verify_native'):
            self.assertEqual(plain.check_manifest()['tag'], '0.1')
        wrong = release.Release(self.root, self.config, tag='v0.1')
        with patch.object(wrong, 'verify_native'), self.assertRaises(prov.ReleaseError):
            wrong.check_manifest()
        with self.assertRaises(prov.ReleaseError):
            release.Release(self.root, self.config, tag='v9.0')
        sha = self.init_git()
        pub.local_tag(self.root, '0.1', sha, create=True, message='ScopeMac 0.1 preview')
        pub.local_tag(self.root, '0.1', sha, message='ScopeMac 0.1 preview')
        with self.assertRaises(prov.ReleaseError):
            pub.local_tag(self.root, '0.1', sha, message='Different annotation')

    def test_combined_release_requires_confirmation_and_resumes_manifest(self):
        with patch.object(release, 'ROOT', self.root), patch.object(release.Release, 'prepare') as prepare, \
             patch.object(release.Release, 'publish') as publish, contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(release.main(['release']), 1)
            prepare.assert_not_called(); publish.assert_not_called()
        self.prepared()
        with patch.object(release, 'ROOT', self.root), patch.object(release.Release, 'prepare') as prepare, \
             patch.object(release.Release, 'publish') as publish:
            self.assertEqual(release.main(['release', '--confirm-publish', '--to', 'github']), 0)
            prepare.assert_not_called(); publish.assert_called_once_with(['github'], True)


class GitDiagnosticTests(Fixture):
    def test_missing_remote_error_names_service_and_does_not_initialize(self):
        from unittest.mock import patch
        real_git = source.git
        def fail(root, *args, **kwargs):
            if args[:2] == ('ls-remote', '--refs'):
                raise prov.ReleaseError('Repository not found or not visible to your Git account.')
            return real_git(root, *args, **kwargs)
        with patch.object(source, 'git', side_effect=fail), self.assertRaises(prov.ReleaseError) as caught:
            source.initialize_source(self.root, self.config, {'gitlab': self.config['gitlab_git']})
        self.assertIn('gitlab:', str(caught.exception))
        self.assertFalse((self.root / '.git').exists())

    def test_git_diagnostic_classification_never_echoes_secret_output(self):
        from types import SimpleNamespace
        for raw, expected in (
            (b'remote: The project you were looking for could not be found or you do not have permission. private-token', 'Repository not found'),
            (b'Permission denied (publickey). private-token', 'SSH key'),
            (b'Could not resolve hostname private.example: private-token', 'DNS'),
            (b'Host key verification failed. private-token', 'fingerprint'),
            (b'non-fast-forward private-token', 'history differs')):
            with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=128, stdout=b'', stderr=raw)), self.assertRaises(prov.ReleaseError) as caught:
                prov.git(self.root, 'ls-remote', '--refs', self.config['gitlab_git'])
            self.assertIn(expected, str(caught.exception))
            self.assertNotIn('private-token', str(caught.exception))
