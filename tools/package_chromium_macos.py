#!/usr/bin/env python3
"""Stage and sign a macOS Chromium build without modifying the build output."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def stage(source, destination, info_updates=None):
    source, destination = source.resolve(), destination.resolve()
    if not (source / 'Contents/MacOS/Bark').is_file():
        raise ValueError('Build Bark before packaging')
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('The package must be separate from the source bundle')
    executable = destination / 'Contents/MacOS/Bark'
    commands = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    if any(line == str(executable) or line.startswith(str(executable) + ' ') for line in commands):
        raise ValueError('Quit this Bark build before replacing its bundle')
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(source), str(destination)], check=True)
    info_path = destination / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = 'app.bark.browser.chromium-development'
    info['CFBundleName'] = info['CFBundleDisplayName'] = 'Bark-dev'
    # Development packages have their own profile/keychain. Release staging
    # explicitly supplies the production identity and existing data locations.
    info['CrProductDirName'] = 'BarkChromium Development'
    info['BarkSafeStorageName'] = 'Bark Development Safe Storage'
    info['CFBundleIconFile'] = 'Bark.icns'
    info.pop('CFBundleIconName', None)
    if info_updates:
        info.update(info_updates)
    # Compile the existing Bark artwork as a standard macOS application icon.
    with tempfile.TemporaryDirectory(prefix='bark-icon-') as directory:
        iconset = Path(directory) / 'Bark.iconset'
        iconset.mkdir()
        for size in [16, 32, 128, 256, 512]:
            for scale in [1, 2]:
                suffix = '@2x' if scale == 2 else ''
                subprocess.run(['sips', '-z', str(size * scale), str(size * scale),
                                str(ROOT / 'apps/macos/resources/icon.png'), '--out',
                                str(iconset / f'icon_{size}x{size}{suffix}.png')],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o',
                        str(destination / 'Contents/Resources/Bark.icns')], check=True)
    info_path.write_bytes(plistlib.dumps(info))


def package(source, destination, identity):
    stage(source, destination)
    framework = destination / 'Contents/Frameworks/Bark Framework.framework'
    bundles = sorted(framework.rglob('*.app'), key=lambda p: len(p.parts), reverse=True)
    for bundle in [*bundles, framework, destination]:
        subprocess.run(['codesign', '--force', '--sign', identity,
                        '--preserve-metadata=entitlements,flags', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    print('Signed development build:', destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / '.deps/chromium-source/src/out/Bark-mac-arm64/Bark-dev.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'release/chromium-development/Bark-dev.app')
    parser.add_argument('--identity', required=True, help='Existing development signing identity; use - only for disposable ad-hoc tests')
    args = parser.parse_args()
    package(args.source, args.output, args.identity)


if __name__ == '__main__':
    main()
