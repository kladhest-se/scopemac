# SPDX-License-Identifier: GPL-3.0-or-later
# Source workflow adapted from BitSkim; see ThirdParty/BitSkim/LICENSE.
"""Separately confirmed source pushes; never build, tag, force or publish assets."""
from pathlib import Path
import re

from build_provenance import ReleaseError, clean_checkout, commit, git, require, source_files, source_state
from release_publish import validate_git_url


def repositories(config, selected):
    require(selected and len(set(selected)) == len(selected) and set(selected) <= {'github', 'gitlab'},
            'Choose distinct source destinations from gitlab,github')
    result = {}
    for service in selected:
        require(config.get(service) and config.get(service + '_git'), 'Configure source destination: ' + service)
        validate_git_url(config[service], config[service + '_git'], service)
        result[service] = config[service + '_git']
    return result


def remote_git(root, service, *args):
    try:
        return git(root, *args)
    except ReleaseError as error:
        raise ReleaseError(service + ': ' + str(error)) from None


def branch_name(root, name):
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9._/-]*', name)
            and not any(piece.startswith('.') or piece.endswith('.lock') for piece in name.split('/'))
            and not any(value in name for value in ('..', '//')) and not name.endswith(('/', '.')),
            'Invalid source branch')
    return name


def initialize_source(root, config, remotes, message=None):
    root = Path(root)
    metadata = root / '.git'
    detected = git(root, 'rev-parse', '--show-toplevel', optional=True)
    if detected:
        require(Path(detected).resolve() == root.resolve(), 'Refusing initialization inside another Git repository')
        if git(root, 'rev-parse', '--verify', 'HEAD', optional=True):
            require(message is None, '--commit-message is only for a new repository')
            return
    else:
        require(not metadata.exists() and not metadata.is_symlink(), 'Invalid existing .git metadata; inspect it first')
    require((root / '.gitignore').is_file(), 'Review .gitignore before initialization')
    snapshot = source_state(root)
    for service, remote in remotes.items():
        require(not remote_git(root, service, 'ls-remote', '--refs', remote),
                service + ' has existing Git history; clone it and import the source instead')
    for identity in ('GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT'):
        git(root, 'var', identity)
    branch = branch_name(root, config.get('source_branch') or 'main')
    if not detected:
        git(root, 'init', '--initial-branch', branch)
    # Stage the explicit public release inputs, rather than arbitrary workspace files.
    inputs = source_files(root)
    git(root, 'add', '--', *inputs)
    staged = set(git(root, 'ls-files', '-z').split('\0')) - {''}
    require(staged == set(inputs), 'Previously staged files outside public release inputs; inspect the index before committing')
    require(not git(root, 'ls-files', '--others', '--exclude-standard'),
            'Untracked files outside the public release inputs; review before the first commit')
    require(source_state(root) == snapshot, 'Source changed during initialization')
    git(root, 'commit', '-m', message or 'Initial ScopeMac source')


def push_source(root, config, selected, confirmed=False, dry_run=False, initialize=False, message=None):
    require(dry_run or confirmed, 'Source upload requires --confirm-push; inspect --dry-run first')
    require(not (dry_run and initialize), '--dry-run cannot initialize or commit; use --init --confirm-push explicitly')
    require(message is None or initialize, '--commit-message requires --init')
    remotes = repositories(config, selected)
    if initialize:
        initialize_source(root, config, remotes, message)
    sha = commit(root)
    clean_checkout(root, sha)
    local = git(root, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    target = branch_name(root, config.get('source_branch') or local)
    refspec = 'refs/heads/' + local + ':refs/heads/' + target
    # Preflight every selected remote before the first actual push.
    for service, remote in remotes.items():
        remote_git(root, service, 'push', '--dry-run', '--no-follow-tags', '--', remote, refspec)
        print('Source preflight passed: ' + service + ' (' + local + ' -> ' + target + ')')
    if dry_run:
        print('No source, tags or release assets uploaded.')
        return
    for service, remote in remotes.items():
        clean_checkout(root, sha)
        remote_git(root, service, 'push', '--no-follow-tags', '--', remote, refspec)
        current = remote_git(root, service, 'ls-remote', '--heads', remote, 'refs/heads/' + target)
        require(current and current.split()[0] == sha, 'Remote source branch verification failed: ' + service)
        print(service + ': source branch verified')
