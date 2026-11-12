# SPDX-License-Identifier: GPL-3.0-or-later
"""Public distribution names and read-only disk-image payload verification."""
from pathlib import Path
import tempfile

from build_provenance import require, tree_hashes


def names(version):
    base = 'ScopeMac-' + version
    return {'app': base + '.zip', 'app_checksum': base + '.zip.sha256',
            'dmg': base + '.dmg', 'dmg_checksum': base + '.dmg.sha256'}


def verify_dmg(dmg, expected_app_files, run):
    run(['hdiutil', 'verify', str(dmg)], capture=True)
    run(['codesign', '--verify', '--strict', str(dmg)], capture=True)
    run(['xcrun', 'stapler', 'validate', str(dmg)], capture=True)
    with tempfile.TemporaryDirectory(prefix='ScopeMac-dmg-check-') as temporary:
        mount = Path(temporary) / 'volume'
        mount.mkdir()
        run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(dmg)], capture=True)
        try:
            allowed = {'ScopeMac.app', 'Applications', '.DS_Store', '.fseventsd', '.Trashes',
                       '.Spotlight-V100', '.HFS+ Private Directory Data\r'}
            require({p.name for p in mount.iterdir()} <= allowed, 'Unexpected disk-image content')
            require(tree_hashes(mount / 'ScopeMac.app') == expected_app_files,
                    'DMG app differs from the verified ZIP/app bundle')
            applications = mount / 'Applications'
            require(applications.is_symlink() and str(applications.readlink()) == '/Applications',
                    'DMG is missing its Applications shortcut')
        finally:
            run(['hdiutil', 'detach', str(mount)], capture=True)
