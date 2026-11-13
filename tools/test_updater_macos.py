#!/usr/bin/env python3
"""Smoke-test the real Sparkle framework and Bark menu integration in a tiny host."""
from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile
import uuid

from release_macos import ROOT, read_config, release_info, sparkle_directory, sign, notarize, zip_app, generate_feed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release-signing', action='store_true',
                        help='Also exercise Developer ID signing and Apple notarization')
    parser.add_argument('--feed-signing', action='store_true',
                        help='Generate and validate a signed test appcast using the Sparkle Keychain key')
    args = parser.parse_args()
    config = read_config()
    sparkle = sparkle_directory(config)
    with tempfile.TemporaryDirectory(prefix='bark-updater-test-') as directory:
        app = Path(directory) / 'UpdaterTest.app'
        executable = app / 'Contents/MacOS/Bark'
        executable.parent.mkdir(parents=True)
        info = release_info(config, '0.1.0', '1')
        info.update(CFBundleIdentifier='app.bark.updater-test.' + uuid.uuid4().hex,
                    CFBundleExecutable='Bark', CFBundleName='UpdaterTest', CFBundlePackageType='APPL',
                    SUEnableAutomaticChecks=False, SUEnableInstallerLauncherService=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc',
                        '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        '-Wobjc-missing-property-synthesis', '-Wexit-time-destructors',
                        '-I' + str(ROOT / 'apps/macos/src/chromium'),
                        str(ROOT / 'apps/macos/src/chromium/updater_mac.mm'),
                        str(ROOT / 'tools/fixtures/UpdaterTests.mm'),
                        '-framework', 'AppKit', '-o', str(executable)], check=True)
        subprocess.run(['ditto', str(sparkle / 'Sparkle.framework'),
                        str(app / 'Contents/Frameworks/Sparkle.framework')], check=True)
        if args.release_signing:
            sign(app, config['signing_identity'], ROOT / '.deps/chromium-source/src', config['team_id'])
            notarize(app, config['notary_profile'], Path(directory))
        else:
            subprocess.run(['codesign', '--sign', '-', str(app)], check=True)
        if args.feed_signing:
            downloads = Path(directory) / 'downloads'
            downloads.mkdir()
            archive = downloads / 'Bark-0.1.0-mac-arm64.zip'
            zip_app(app, archive)
            generate_feed(sparkle, config, archive, '0.1.0', '1')
        subprocess.run([str(executable)], check=True, timeout=30)


if __name__ == '__main__':
    main()
