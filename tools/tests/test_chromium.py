import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import call, patch

MODULE = Path(__file__).resolve().parents[1] / 'chromium.py'
spec = importlib.util.spec_from_file_location('bark_chromium', MODULE)
chromium = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chromium)


class ChromiumBuildTests(unittest.TestCase):
    def test_lock_pins_sources_and_patch_contents(self):
        data = chromium.load_lock()
        self.assertEqual(40, len(data['revision']))
        self.assertGreaterEqual(len(chromium.patch_files(data)), 3)
        self.assertNotIn('cef', data)

    def test_rejects_changed_patch(self):
        with patch.object(chromium, 'digest', return_value='0' * 64):
            with self.assertRaisesRegex(ValueError, 'Patch changed'):
                chromium.load_lock()

    def test_rejects_paths_outside_source(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'bad.patch'
            source.write_text('--- a/../../outside\n+++ b/../../outside\n')
            with self.assertRaisesRegex(ValueError, 'Unsafe patch path'):
                chromium.patch_paths([source])

    def test_space_check_runs_before_fetch(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(chromium.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(100, 99, 1)), \
                patch.object(chromium.platform, 'system', return_value='Linux'), \
                patch.object(chromium, 'run') as execute:
            with self.assertRaisesRegex(RuntimeError, 'Insufficient build space'):
                chromium.sync(Path(folder) / 'new', chromium.load_lock())
            execute.assert_not_called()
            self.assertFalse((Path(folder) / 'new').exists())

    def test_preparation_does_not_overwrite_developer_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            src = root / 'src'; src.mkdir()
            subprocess.run(['git', 'init', '-q', str(src)], check=True)
            (src / 'user-file').write_text('keep me')
            with patch.object(chromium, 'ensure_checkout'):
                with self.assertRaisesRegex(RuntimeError, 'dirty Chromium checkout'):
                    chromium.prepare(root, chromium.load_lock())
            self.assertEqual('keep me', (src / 'user-file').read_text())

    def test_missing_git_lfs_is_reported_before_fetch(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(chromium.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(300 * 1024**3, 0, 200 * 1024**3)), \
                patch.object(chromium.shutil, 'which', side_effect=lambda name: '/usr/bin/git' if name == 'git' else None), \
                patch.object(chromium.platform, 'system', return_value='Linux'), \
                patch.object(chromium, 'run') as execute:
            with self.assertRaisesRegex(RuntimeError, 'Install Git LFS'):
                chromium.sync(Path(folder) / 'new', chromium.load_lock())
            execute.assert_not_called()
            self.assertFalse((Path(folder) / 'new').exists())

    def test_macos_target_rejects_linux_host(self):
        with patch.object(chromium.platform, 'system', return_value='Linux'):
            with self.assertRaisesRegex(RuntimeError, 'requires a Mac'):
                chromium.configure(Path('/unused'), chromium.load_lock(), 'mac-arm64')

    def test_missing_metal_toolchain_has_an_actionable_preflight_error(self):
        with patch.object(chromium, 'run'), \
                patch.object(chromium.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'missing Metal Toolchain')):
            with self.assertRaisesRegex(RuntimeError, 'downloadComponent MetalToolchain'):
                chromium.check_macos_toolchain()

    def test_release_metadata_is_validated(self):
        with patch.object(chromium, 'read_url', return_value=json.dumps([{'channel': 'Canary', 'platform': 'Mac'}]).encode()):
            with self.assertRaisesRegex(ValueError, 'release metadata'):
                chromium.latest_release()

    def test_official_mirror_uses_exact_pin_and_keeps_upstream_origin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            src = root / 'src'; (src / '.git').mkdir(parents=True)
            lock = chromium.load_lock()
            with patch.object(chromium, 'git', side_effect=['origin', chromium.UPSTREAM, lock['revision']]), \
                    patch.object(chromium, 'run') as execute:
                chromium.seed_from_github(root, lock)
            self.assertEqual(execute.call_args_list, [
                call(['git', '-C', src, 'fetch', '--no-tags', '--depth=1', '--progress', chromium.SOURCE_MIRROR, lock['revision']]),
                call(['git', '-C', src, 'checkout', '--detach', lock['revision']]),
            ])

    def test_mirror_does_not_change_an_unexpected_origin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'src/.git').mkdir(parents=True)
            with patch.object(chromium, 'git', side_effect=['origin', 'https://example.com/my-fork.git']), \
                    patch.object(chromium, 'run') as execute:
                with self.assertRaisesRegex(RuntimeError, 'origin differs'):
                    chromium.seed_from_github(root, chromium.load_lock())
            execute.assert_not_called()

    def test_mirror_retry_reuses_an_already_downloaded_commit(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            src = root / 'src'; (src / '.git').mkdir(parents=True)
            lock = chromium.load_lock()
            with patch.object(chromium, 'git', side_effect=['origin', chromium.UPSTREAM, lock['revision']]), \
                    patch.object(chromium.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
                    patch.object(chromium, 'run') as execute:
                chromium.seed_from_github(root, lock)
            execute.assert_called_once_with(['git', '-C', src, 'checkout', '--detach', lock['revision']])

    def test_mirror_sync_still_preserves_local_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            src = root / 'src'; (src / '.git').mkdir(parents=True)
            with patch.object(chromium, 'doctor'), \
                    patch.object(chromium, 'git', return_value=' M important.cc'), \
                    patch.object(chromium, 'seed_from_github') as seed:
                with self.assertRaisesRegex(RuntimeError, 'checkout has changes'):
                    chromium.sync(root, chromium.load_lock(), github_mirror=True)
            seed.assert_not_called()

    def test_dependency_verification_detects_interrupted_and_wrong_checkouts(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            dep = root / 'src/dependency'; dep.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', dep], check=True)
            metadata = root / '.gclient_entries'
            metadata.write_text('entries = ' + repr({'src/dependency': 'https://example.com/dep.git@' + 'a' * 40}))
            with self.assertRaisesRegex(RuntimeError, 'incomplete checkout'):
                chromium.verify_dependencies(root)
            (dep / 'source.txt').write_text('fixture')
            subprocess.run(['git', '-C', dep, 'add', 'source.txt'], check=True)
            subprocess.run(['git', '-C', dep, '-c', 'user.name=Bark test', '-c', 'user.email=test@example.invalid',
                            '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
            revision = chromium.git(dep, 'rev-parse', 'HEAD')
            with self.assertRaisesRegex(RuntimeError, 'incorrect revision'):
                chromium.verify_dependencies(root)
            metadata.write_text('entries = ' + repr({'src/dependency': 'https://example.com/dep.git@' + revision}))
            chromium.verify_dependencies(root)

    def test_dependency_metadata_cannot_escape_the_build_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / '.gclient_entries').write_text('entries = ' + repr({'../outside': 'https://example.com/dep.git@' + 'a' * 40}))
            with self.assertRaisesRegex(RuntimeError, 'outside the build directory'):
                chromium.verify_dependencies(root)

    def make_prepared_fixture(self, directory):
        root = Path(directory)
        engine = root / 'engine'; (engine / 'patches').mkdir(parents=True)
        (engine / 'overlay').mkdir()
        (engine / 'overlay/BRANDING').write_text('Bark')
        work = root / 'work'; src = work / 'src'; src.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', src], check=True)
        (src / 'one.cc').write_text('upstream one\n')
        (src / 'two.cc').write_text('upstream two\n')
        subprocess.run(['git', '-C', src, 'add', '.'], check=True)
        subprocess.run(['git', '-C', src, '-c', 'user.name=Bark test', '-c', 'user.email=test@example.invalid',
                        '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], check=True)
        first = engine / 'patches/0001.patch'
        first.write_text('--- a/one.cc\n+++ b/one.cc\n@@ -1 +1 @@\n-upstream one\n+Bark one\n')
        second = engine / 'patches/0002.patch'
        second.write_text('--- a/two.cc\n+++ b/two.cc\n@@ -1 +1 @@\n-upstream two\n+Bark two\n')
        lock = {'revision': chromium.git(src, 'rev-parse', 'HEAD'), 'patches': [{'file': first.name}]}
        return root, engine, work, lock

    def test_append_patch_and_refresh_overlay_without_discarding_build_or_developer_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root, engine, work, lock = self.make_prepared_fixture(directory)
            with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                chromium.prepare(work, lock)
                unchanged_mtime = (work / 'src/one.cc').stat().st_mtime_ns
                (work / 'src/unrelated.txt').write_text('developer work')
                output = work / 'src/out'; output.mkdir(); (output / 'cached.o').write_text('cached object')
                lock['patches'].append({'file': '0002.patch'})
                (engine / 'overlay/BRANDING').write_text('Bark updated')
                chromium.prepare(work, lock)
                chromium.prepare(work, lock)  # Idempotent.
                self.assertEqual('Bark one\n', (work / 'src/one.cc').read_text())
                self.assertEqual(unchanged_mtime, (work / 'src/one.cc').stat().st_mtime_ns)
                self.assertEqual('Bark two\n', (work / 'src/two.cc').read_text())
                self.assertEqual('Bark updated', (work / 'src/bark/BRANDING').read_text())
                self.assertEqual('developer work', (work / 'src/unrelated.txt').read_text())
                self.assertEqual('cached object', (output / 'cached.o').read_text())

    def test_refresh_refuses_edited_prepared_output_or_new_patch_target(self):
        for target in ('one.cc', 'two.cc', 'bark/BRANDING'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root, engine, work, lock = self.make_prepared_fixture(directory)
                with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                    chromium.prepare(work, lock)
                    lock['patches'].append({'file': '0002.patch'})
                    (work / 'src' / target).write_text('keep my edits')
                    before = (work / 'bark-prepared.json').read_bytes()
                    with self.assertRaisesRegex(RuntimeError, 'changed|developer changes'):
                        chromium.prepare(work, lock)
                    self.assertEqual('keep my edits', (work / 'src' / target).read_text())
                    self.assertEqual(before, (work / 'bark-prepared.json').read_bytes())

    def test_refresh_replaces_only_verified_applied_patch_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root, engine, work, lock = self.make_prepared_fixture(directory)
            with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                chromium.prepare(work, lock)
                patchfile = engine / 'patches/0001.patch'
                patchfile.write_text(patchfile.read_text().replace('+Bark one', '+different'))
                chromium.prepare(work, lock)
                self.assertEqual('different\n', (work / 'src/one.cc').read_text())
                lock['patches'] = []
                chromium.prepare(work, lock)
                self.assertEqual('upstream one\n', (work / 'src/one.cc').read_text())

    def test_refresh_removes_only_unchanged_obsolete_overlays(self):
        with tempfile.TemporaryDirectory() as directory:
            root, engine, work, lock = self.make_prepared_fixture(directory)
            with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                old_source = engine / 'overlay/old.swift'
                old_source.write_text('obsolete generated source')
                chromium.prepare(work, lock)
                old_output = work / 'src/bark/old.swift'
                unowned = work / 'src/bark/developer.swift'
                unowned.write_text('developer work')
                output = work / 'src/out'; output.mkdir()
                (output / 'cached.o').write_text('cached object')
                unchanged_mtime = (work / 'src/bark/BRANDING').stat().st_mtime_ns
                old_source.unlink()
                (engine / 'overlay/new.swift').write_text('replacement generated source')
                chromium.prepare(work, lock)
                chromium.prepare(work, lock)  # The updated manifest is reusable.
                self.assertFalse(old_output.exists())
                self.assertEqual('replacement generated source', (work / 'src/bark/new.swift').read_text())
                self.assertEqual('developer work', unowned.read_text())
                self.assertEqual('cached object', (output / 'cached.o').read_text())
                self.assertEqual(unchanged_mtime, (work / 'src/bark/BRANDING').stat().st_mtime_ns)
                stamp = json.loads((work / 'bark-prepared.json').read_text())
                self.assertNotIn('overlay/old.swift', stamp['inputs'])
                self.assertNotIn('bark/old.swift', stamp['outputs'])
                self.assertIn('bark/new.swift', stamp['outputs'])

    def test_refresh_preserves_edited_or_symlinked_obsolete_overlay(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as directory:
                root, engine, work, lock = self.make_prepared_fixture(directory)
                with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                    chromium.prepare(work, lock)
                    (engine / 'overlay/BRANDING').unlink()
                    target = work / 'src/bark/BRANDING'
                    if symlink:
                        outside = root / 'developer.txt'
                        outside.write_text('Bark')
                        target.unlink()
                        target.symlink_to(outside)
                    else:
                        target.write_text('keep my edits')
                    before = (work / 'bark-prepared.json').read_bytes()
                    with self.assertRaisesRegex(RuntimeError, 'Prepared source changed: bark/BRANDING'):
                        chromium.prepare(work, lock)
                    self.assertEqual('Bark' if symlink else 'keep my edits', target.read_text())
                    self.assertEqual(symlink, target.is_symlink())
                    self.assertEqual(before, (work / 'bark-prepared.json').read_bytes())

    def test_refresh_restores_removed_overlay_when_manifest_update_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root, engine, work, lock = self.make_prepared_fixture(directory)
            with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                chromium.prepare(work, lock)
                old_output = work / 'src/bark/BRANDING'
                old_output.chmod(0o755)
                old_metadata = old_output.stat()
                (engine / 'overlay/BRANDING').unlink()
                (engine / 'overlay/new.swift').write_text('new generated source')
                lock['patches'].append({'file': '0002.patch'})
                before = (work / 'bark-prepared.json').read_bytes()
                with patch.object(Path, 'replace', side_effect=OSError('cannot replace manifest')):
                    with self.assertRaisesRegex(OSError, 'cannot replace manifest'):
                        chromium.prepare(work, lock)
                self.assertEqual('Bark', (work / 'src/bark/BRANDING').read_text())
                self.assertEqual(old_metadata.st_mode, old_output.stat().st_mode)
                self.assertEqual(old_metadata.st_mtime_ns, old_output.stat().st_mtime_ns)
                self.assertFalse((work / 'src/bark/new.swift').exists())
                self.assertEqual('upstream two\n', (work / 'src/two.cc').read_text())
                self.assertEqual(before, (work / 'bark-prepared.json').read_bytes())
                chromium.prepare(work, lock)  # A failed update can be retried.
                self.assertFalse((work / 'src/bark/BRANDING').exists())
                self.assertEqual('Bark two\n', (work / 'src/two.cc').read_text())

    def test_overlay_sources_cannot_escape_repository_or_collide(self):
        with tempfile.TemporaryDirectory() as directory:
            root, engine, work, lock = self.make_prepared_fixture(directory)
            manifest = engine / 'overlay-sources.json'
            with patch.object(chromium, 'ROOT', root), patch.object(chromium, 'ENGINE', engine):
                for name, source in [('../escape', 'engine/overlay/BRANDING'),
                                     ('safe', '../outside'), ('BRANDING', 'engine/overlay/BRANDING')]:
                    manifest.write_text(json.dumps({name: source}))
                    with self.assertRaises(ValueError):
                        chromium.overlay_files()


if __name__ == '__main__':
    unittest.main()
