#!/usr/bin/env python3
"""Preview obsolete local Bark apps; pass --apply to move them to Trash."""
import argparse
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
APP_IDS = {
    'app.bark.browser',
    'app.bark.browser.testing',
    'app.bark.browser.chromium-development',
    'app.bark.browser.import-preview',
}
DEV_APP = Path('release/chromium-development/Bark-dev.app')
BUILD_DIR = Path('.deps/chromium-source/src/out/Bark-mac-arm64')
LEGACY_APPS = (
    'release/macos-arm64/Bark.app',
    'release/macos-arm64-testing/Bark.app',
    'release/macos-arm64-testing/Bark Testing.app',
    'release/arc-import/Bark.app',
    '.build/import-preview/Bark Import Preview.app',
)


@dataclass(frozen=True)
class Entry:
    app: Path
    remove: bool
    reason: str


def app_info(root, app):
    """Only accept real Bark bundles inside this checkout, never symlink targets."""
    if root not in app.parents or app.resolve() != app:
        raise ValueError('path is outside the checkout or contains a symlink')
    info_path = app / 'Contents/Info.plist'
    if info_path.resolve() != info_path:
        raise ValueError('app metadata contains a symlink')
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (plistlib.InvalidFileException, ExpatError) as error:
        raise ValueError('invalid Info.plist') from error
    if not isinstance(info, dict) or info.get('CFBundleIdentifier') not in APP_IDS:
        raise ValueError('unrecognized app identity')
    if info.get('CFBundleExecutable') != 'Bark' or not (app / 'Contents/MacOS/Bark').is_file():
        raise ValueError('not a complete Bark app bundle')
    return info


def plan_cleanup(root, keep_releases=1, keep=()):
    root = root.resolve()
    protected = {(root / path).resolve() for path in keep}
    entries, releases = [], []

    def inspect(app):
        if not app.exists() and not app.is_symlink():
            return None
        try:
            return app_info(root, app)
        except (OSError, ValueError) as error:
            entries.append(Entry(app, False, f'unrecognized bundle: {error}'))
            return None

    def add(app, remove, reason):
        if app in protected:
            remove, reason = False, 'explicitly kept with --keep'
        entries.append(Entry(app, remove, reason))

    for app in sorted((root / 'release').glob('v*/Bark.app')):
        info = inspect(app)
        if info is None:
            continue
        version = str(info.get('CFBundleShortVersionString', ''))
        build = str(info.get('CFBundleVersion', ''))
        if (info['CFBundleIdentifier'] != 'app.bark.browser'
                or not re.fullmatch(r'\d+\.\d+\.\d+', version)
                or not re.fullmatch(r'\d+', build)
                or not re.fullmatch(r'v' + re.escape(version) + r'(?:-[\w.-]+)?', app.parent.name)):
            add(app, False, 'unrecognized release version; inspect manually')
            continue
        releases.append((tuple(map(int, version.split('.'))), int(build), app))

    # Numeric versions matter: v0.1.10 is newer than v0.1.9. Folder names
    # break ties deterministically (e.g. v0.1.0-final versus v0.1.0).
    releases.sort(reverse=True)
    for index, (_, _, app) in enumerate(releases):
        add(app, index >= keep_releases,
            'older packaged release' if index >= keep_releases else 'newest packaged release')

    dev = inspect(root / DEV_APP)
    raw_dev = inspect(root / BUILD_DIR / 'Bark-dev.app')
    for relative, info in [(DEV_APP, dev), (BUILD_DIR / 'Bark-dev.app', raw_dev)]:
        if info is not None:
            add(root / relative, False, 'current development build')

    has_current = bool(dev or raw_dev or releases[:keep_releases])
    for relative in LEGACY_APPS:
        app = root / relative
        if inspect(app) is not None:
            add(app, has_current, 'legacy test/preview build' if has_current else 'no current build found')

    # Remove renamed development bundles only when their replacements exist.
    for app, replacement in [
        (root / 'release/chromium-development/Bark Chromium.app', dev),
        (root / BUILD_DIR / 'Bark.app', raw_dev),
    ]:
        if inspect(app) is not None:
            add(app, replacement is not None,
                'replaced by Bark-dev.app' if replacement is not None else 'Bark-dev.app is missing')
    return sorted(entries, key=lambda entry: entry.app)


def running_commands():
    try:
        return subprocess.run(['ps', '-axo', 'command='], check=True,
                              capture_output=True, text=True).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        raise RuntimeError('Cannot check running apps; nothing was moved. Run from Terminal.') from error


def move_to_trash(root, app, trash):
    app_info(root, app)  # Recheck before each move.
    trash.mkdir(mode=0o700, parents=True, exist_ok=True)
    label = '--'.join(app.relative_to(root).parts).removesuffix('.app')
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    destination = trash / f'{label}--{stamp}-{uuid.uuid4().hex}.app'
    # A rename preserves the entire signed bundle and its internal symlinks.
    # Fail rather than copying/deleting gigabytes across filesystem boundaries.
    app.rename(destination)
    return destination


def apply_cleanup(root, entries, trash):
    candidates = [entry.app for entry in entries if entry.remove]
    if not candidates:
        return 0
    commands = running_commands()  # Fail before any changes if ps is unavailable.
    moved = 0
    for app in candidates:
        if any(command.lstrip().startswith(str(app) + '/') for command in commands):
            print(f'SKIP running app: {app}')
            continue
        destination = move_to_trash(root, app, trash)
        print(f'MOVED {app}\n   to {destination}')
        moved += 1
    return moved


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Move listed obsolete apps to ~/.Trash')
    parser.add_argument('--keep-releases', type=int, default=1, metavar='N',
                        help='Number of newest packaged release bundles to keep (default: 1)')
    parser.add_argument('--keep', action='append', type=Path, default=[], metavar='APP',
                        help='Also keep this app path, relative to the repository or absolute; repeatable')
    args = parser.parse_args(argv)
    if args.keep_releases < 1:
        parser.error('--keep-releases must be at least 1')
    if args.apply and sys.platform != 'darwin':
        parser.error('--apply requires macOS')
    root = ROOT.resolve()
    for path in args.keep:
        if not (root / path).is_dir():
            parser.error(f'--keep app does not exist: {path}')
    entries = plan_cleanup(root, args.keep_releases, args.keep)
    for entry in entries:
        print(f'{"TRASH" if entry.remove else "KEEP "} {entry.app.relative_to(root)} ({entry.reason})')
    count = sum(entry.remove for entry in entries)
    print(f'\n{count} obsolete app bundle(s). Installed apps, profiles, ZIPs, and release metadata are untouched.')
    if not args.apply:
        print('Preview only. Run with --apply to move these apps to Trash; running apps will be skipped.')
        return 0
    try:
        moved = apply_cleanup(root, entries, Path.home() / '.Trash')
    except (OSError, ValueError, RuntimeError) as error:
        print(f'Cleanup stopped: {error}', file=sys.stderr)
        return 1
    print(f'Moved {moved} app bundle(s) to Trash. Empty Trash when you want to reclaim the disk space.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
