# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only DMG verification tests using simulated mounts; no system mounts or uploads."""
from pathlib import Path
import shutil
from unittest.mock import patch

from test_release import Fixture
import build_provenance as prov
from release_artifacts import verify_dmg


class DiskImageTests(Fixture):
    def payload(self):
        app = self.root / 'ScopeMac.app'; app.mkdir()
        (app / 'payload').write_bytes(b'verified-app')
        return app, prov.tree_hashes(app)

    def runner(self, app, events, corrupt=False, extra=False):
        def run(command, capture=False):
            events.append(command)
            if command[:2] == ['hdiutil', 'attach']:
                mount = Path(command[command.index('-mountpoint') + 1])
                self.assertIn('-readonly', command)
                self.assertIn('-nobrowse', command)
                shutil.copytree(app, mount / 'ScopeMac.app')
                (mount / 'Applications').symlink_to('/Applications')
                if corrupt:
                    (mount / 'ScopeMac.app/payload').write_bytes(b'wrong-app')
                if extra:
                    (mount / 'extra-file').write_bytes(b'unexpected')
            return ''
        return run

    def test_dmg_verifies_same_app_and_detaches(self):
        app, expected = self.payload(); events = []
        verify_dmg(self.root / 'ScopeMac-0.1.dmg', expected, self.runner(app, events))
        self.assertEqual(events[-1][:2], ['hdiutil', 'detach'])
        self.assertTrue(any(c[:2] == ['codesign', '--verify'] for c in events))
        self.assertTrue(any(c[:3] == ['xcrun', 'stapler', 'validate'] for c in events))

    def test_wrong_payload_or_extra_file_refused_and_detached(self):
        app, expected = self.payload()
        for corrupt, extra in ((True, False), (False, True)):
            events = []
            with self.assertRaises(prov.ReleaseError):
                verify_dmg(self.root / 'bad.dmg', expected, self.runner(app, events, corrupt, extra))
            self.assertEqual(events[-1][:2], ['hdiutil', 'detach'])

    def test_changed_dmg_blocks_native_verification(self):
        record = self.mock_build()
        (self.tool.app).mkdir(parents=True)
        record['app_files'] = prov.tree_hashes(self.tool.app)
        (self.root / 'build' / self.tool.names['dmg']).write_bytes(b'changed')
        with self.assertRaises(prov.ReleaseError):
            self.tool.verify_native(record)
