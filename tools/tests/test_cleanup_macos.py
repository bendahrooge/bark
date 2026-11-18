import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cleanup_macos as cleanup


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve() / 'checkout'
        self.root.mkdir()
        self.trash = self.root.parent / 'Trash'

    def app(self, relative, version='0.1.0', build='1', bundle_id='app.bark.browser'):
        app = self.root / relative
        executable = app / 'Contents/MacOS/Bark'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'browser fixture')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id,
            'CFBundleExecutable': 'Bark',
            'CFBundleShortVersionString': version,
            'CFBundleVersion': build,
        }))
        return app

    def removals(self, **kwargs):
        return {entry.app for entry in cleanup.plan_cleanup(self.root, **kwargs) if entry.remove}

    def test_versions_sort_numerically_and_retention_is_configurable(self):
        oldest = self.app('release/v0.1.2/Bark.app', '0.1.2', '3')
        middle = self.app('release/v0.1.9/Bark.app', '0.1.9', '10')
        self.app('release/v0.1.10/Bark.app', '0.1.10', '11')
        self.assertEqual(self.removals(), {oldest, middle})
        self.assertEqual(self.removals(keep_releases=2), {oldest})

    def test_duplicate_release_prefers_final_bundle(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.0-final/Bark.app')
        self.assertEqual(self.removals(), {old})

    def test_legacy_version_does_not_displace_current_chromium_release(self):
        legacy = self.app('release/macos-arm64/Bark.app', '0.2.7', '9')
        self.app('release/v0.1.3/Bark.app', '0.1.3', '4')
        self.assertEqual(self.removals(), {legacy})

    def test_legacy_copies_are_kept_without_a_current_build(self):
        self.app('release/macos-arm64/Bark.app', '0.2.7', '9')
        self.app('release/chromium-development/Bark Chromium.app')
        self.app(cleanup.BUILD_DIR / 'Bark.app')
        self.assertEqual(self.removals(), set())

    def test_current_development_builds_replace_only_known_legacy_copies(self):
        self.app(cleanup.DEV_APP, bundle_id='app.bark.browser.chromium-development')
        self.app(cleanup.BUILD_DIR / 'Bark-dev.app', bundle_id='app.bark.browser.chromium-development')
        obsolete = {self.app(relative) for relative in cleanup.LEGACY_APPS}
        obsolete.add(self.app('release/chromium-development/Bark Chromium.app'))
        obsolete.add(self.app(cleanup.BUILD_DIR / 'Bark.app'))
        self.app('release/custom-test/Bark.app')
        self.app('Applications/Bark.app')
        self.assertEqual(self.removals(), obsolete)

    def test_explicit_keep_accepts_relative_and_absolute_paths(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        for path in [old, old.relative_to(self.root)]:
            with self.subTest(path=path):
                self.assertEqual(self.removals(keep=[path]), set())

    def test_symlinked_app_or_parent_cannot_select_external_files(self):
        external = self.app('outside/Bark.app')
        self.app(cleanup.DEV_APP)
        parent = self.root / 'release/macos-arm64'
        parent.mkdir()
        (parent / 'Bark.app').symlink_to(external, target_is_directory=True)
        (self.root / 'release/arc-import').symlink_to(external.parent, target_is_directory=True)
        self.assertEqual(self.removals(), set())
        with self.assertRaises(ValueError):
            cleanup.move_to_trash(self.root, parent / 'Bark.app', self.trash)
        self.assertTrue(external.exists())

    def test_unknown_identity_metadata_or_incomplete_bundles_are_kept(self):
        self.app(cleanup.DEV_APP)
        self.app('release/macos-arm64/Bark.app', bundle_id='com.example.unrelated')
        malformed = self.app('release/arc-import/Bark.app')
        (malformed / 'Contents/Info.plist').write_bytes(b'not a plist')
        incomplete = self.app('.build/import-preview/Bark Import Preview.app')
        (incomplete / 'Contents/MacOS/Bark').unlink()
        self.app('release/v0.1.0/Bark.app', version='99.0.0')
        self.assertEqual(self.removals(), set())

    def test_preview_does_not_move_anything_or_inspect_processes(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        with patch.object(cleanup, 'ROOT', self.root), \
                patch.object(cleanup, 'apply_cleanup') as apply, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(cleanup.main([]), 0)
        apply.assert_not_called()
        self.assertTrue(old.exists())
        self.assertIn('Preview only', output.getvalue())

    def test_malformed_xml_does_not_remove_the_only_valid_release(self):
        self.app('release/v0.1.0/Bark.app')
        malformed = self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        (malformed / 'Contents/Info.plist').write_bytes(b'<?xml version="1.0"?><plist><dict>')
        self.assertEqual(self.removals(), set())

    def test_bundle_identity_is_rechecked_before_moving(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        entries = cleanup.plan_cleanup(self.root)
        (old / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'another.app'}))
        with patch.object(cleanup, 'running_commands', return_value=[]), self.assertRaises(ValueError):
            cleanup.apply_cleanup(self.root, entries, self.trash)
        self.assertTrue(old.exists())

    def test_running_browser_or_nested_helper_prevents_move(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        for suffix in ['/Contents/MacOS/Bark --flag',
                       '/Contents/Frameworks/Bark Helper.app/Contents/MacOS/Helper --type=gpu']:
            with self.subTest(suffix=suffix), \
                    patch.object(cleanup, 'running_commands', return_value=[str(old) + suffix]), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cleanup.apply_cleanup(self.root, cleanup.plan_cleanup(self.root), self.trash), 0)
        self.assertTrue(old.exists())
        self.assertFalse(self.trash.exists())

    def test_process_inspection_failure_leaves_all_files_in_place(self):
        old = self.app('release/v0.1.0/Bark.app')
        self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        with patch.object(cleanup.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'ps')), \
                self.assertRaisesRegex(RuntimeError, 'nothing was moved'):
            cleanup.apply_cleanup(self.root, cleanup.plan_cleanup(self.root), self.trash)
        self.assertTrue(old.exists())

    def test_apply_preserves_release_assets_profiles_and_bundle_symlinks(self):
        old = self.app('release/v0.1.0/Bark.app')
        latest = self.app('release/v0.1.1/Bark.app', '0.1.1', '2')
        (old / 'Contents/current').symlink_to('MacOS', target_is_directory=True)
        assets = [old.parent / 'downloads/Bark.zip', old.parent / 'release-manifest.json',
                  self.root / 'Library/Application Support/BarkChromium/Bookmarks']
        for asset in assets:
            asset.parent.mkdir(parents=True, exist_ok=True)
            asset.write_text('preserve me')
        with patch.object(cleanup, 'running_commands', return_value=[]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cleanup.apply_cleanup(self.root, cleanup.plan_cleanup(self.root), self.trash), 1)
        self.assertFalse(old.exists())
        self.assertTrue(latest.exists())
        self.assertTrue(all(asset.read_text() == 'preserve me' for asset in assets))
        moved = list(self.trash.glob('*.app'))
        self.assertEqual(len(moved), 1)
        self.assertTrue((moved[0] / 'Contents/current').is_symlink())
        self.assertEqual((moved[0] / 'Contents/MacOS/Bark').read_bytes(), b'browser fixture')

    def test_repeated_cleanup_never_overwrites_an_earlier_trashed_copy(self):
        first = cleanup.move_to_trash(self.root, self.app('release/v0.1.0/Bark.app'), self.trash)
        second = cleanup.move_to_trash(self.root, self.app('release/v0.1.0/Bark.app'), self.trash)
        self.assertNotEqual(first, second)
        self.assertTrue(first.exists() and second.exists())

    def test_cli_rejects_zero_retention_or_misspelled_keep(self):
        for args in [['--keep-releases', '0'], ['--keep', 'missing.app']]:
            with self.subTest(args=args), patch.object(cleanup, 'ROOT', self.root), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                cleanup.main(args)
            self.assertEqual(error.exception.code, 2)


if __name__ == '__main__':
    unittest.main()
