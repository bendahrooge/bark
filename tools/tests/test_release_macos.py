import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_macos as release
import publish_release as publish


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = release.read_config()

    def test_release_identity_and_signed_updates(self):
        info = release.release_info(self.config, '0.1.0', '1')
        self.assertEqual(info['CFBundleIdentifier'], 'app.bark.browser')
        self.assertEqual(info['CFBundleVersion'], '1')
        self.assertEqual(info['SUFeedURL'], 'https://github.com/bendahrooge/bark/releases/latest/download/appcast.xml')
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertTrue(info['BarkEnableSwiftUI'])

    def test_invalid_versions_cannot_become_paths_or_tags(self):
        for version, build in [('v1.0.0', '1'), ('../1.0.0', '1'), ('1.0.0', '-1'), ('1.0.0', '0'), ('1.0.0', '1;echo bad')]:
            with self.subTest(version=version, build=build), self.assertRaises(ValueError):
                release.release_info(self.config, version, build)

    def test_signing_inventory_includes_nested_tools_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Bark.app'
            files = [app / 'Contents/MacOS/Bark',
                     app / 'Contents/Frameworks/Bark Framework.framework/Versions/1/Helpers/chrome_crashpad_handler',
                     app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
                     app / 'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer']
            for file in files:
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
            resource = app / 'Contents/Info.plist'
            resource.write_bytes(plistlib.dumps({'CFBundleName': 'Bark'}))
            (app / 'outside').symlink_to(root, target_is_directory=True)
            targets = release.signing_targets(app)
            self.assertTrue(all(file in targets for file in files))
            self.assertNotIn(resource, targets)
            self.assertEqual(targets[-1], app)
            for file in files:
                for parent in file.parents:
                    if parent in targets:
                        self.assertLess(targets.index(file), targets.index(parent))

    def test_v8_helpers_keep_jit_entitlements(self):
        app, src = Path('/Bark.app'), Path('/chromium')
        for name in ['Bark Helper (Renderer).app', 'Bark Helper (Aperitif Renderer).app']:
            bundle = app / 'Contents/Frameworks/Bark Framework.framework/Versions/1/Helpers' / name
            self.assertEqual(release.entitlements_for(bundle, app, src).name, 'helper-renderer-entitlements.plist')
        self.assertEqual(release.entitlements_for(app, app, src).name, 'app-entitlements.plist')
        self.assertIsNone(release.entitlements_for(app / 'Contents/Frameworks/Sparkle.framework', app, src))

    def test_development_certificate_cannot_sign_release(self):
        with self.assertRaises(ValueError):
            release.sign(Path('/Bark.app'), 'Apple Development: Example', Path('/src'), self.config['team_id'])

    def test_notary_rejection_never_staples(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(release, 'zip_app'), patch.object(release, 'run') as run:
            result = subprocess.CompletedProcess([], 1, '{"status":"Invalid","id":"test"}', '')
            with patch.object(release.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, 'not accepted'):
                    release.notarize(Path('/Bark.app'), 'test', Path(directory))
            run.assert_not_called()

    def test_feed_generation_requires_archive_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'Bark-0.1.0-mac-arm64.zip'
            archive.touch()
            (archive.parent / 'appcast.xml').write_text('<rss><channel><item><enclosure/></item></channel></rss>')
            with patch.object(release, 'run'), self.assertRaisesRegex(ValueError, 'unsigned'):
                release.generate_feed(Path('/sparkle'), self.config, archive, '0.1.0', '1')

    def test_publisher_rejects_archive_changed_after_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            downloads = output / 'downloads'
            downloads.mkdir()
            archive = downloads / 'Bark-0.1.0-mac-arm64.zip'
            archive.write_bytes(b'changed')
            (output / 'release-manifest.json').write_text(json.dumps({
                'version': '0.1.0', 'build': '1', 'repository': self.config['repository'],
                'sha256': {archive.name: hashlib.sha256(b'original').hexdigest()},
            }))
            with self.assertRaisesRegex(ValueError, 'changed after'):
                publish.validate_downloads(downloads, self.config, '0.1.0', '1')


if __name__ == '__main__':
    unittest.main()
