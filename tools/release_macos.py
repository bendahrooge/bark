#!/usr/bin/env python3
"""Sign, notarize, and create a signed Sparkle feed for a Bark macOS release.

Private keys stay in Keychain. Publishing is a separate, explicit command.
Requires Python 3.12+, Xcode, and a built Chromium application.
"""
import argparse
import base64
import hashlib
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

from package_chromium_macos import stage

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / 'packaging/macos/release.json'
MACHO_MAGICS = {bytes.fromhex(h) for h in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def verify_release_source(source):
    framework = source / 'Contents/Frameworks/Bark Framework.framework/Bark Framework'
    if not framework.is_file():
        raise ValueError('Expected the Chromium source-build Bark framework')
    # Prevent an old cached build from gaining update metadata without the code
    # that actually starts Sparkle. This marker is a compiled diagnostic string.
    with framework.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as binary:
        if binary.find(b'Bark could not load its update framework:') == -1:
            raise ValueError('This browser was built before Sparkle integration; rebuild Chromium first')
    run('lipo', '-verify_arch', 'arm64', framework)


def read_config(path=CONFIG):
    config = json.loads(path.read_text())
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', config['repository']):
        raise ValueError('Expected a GitHub owner/repository')
    if len(base64.b64decode(config['sparkle_public_key'], validate=True)) != 32:
        raise ValueError('Sparkle requires a 32-byte Ed25519 public key')
    if not re.fullmatch(r'[A-Z0-9]{10}', config['team_id']):
        raise ValueError('Invalid Apple team ID')
    if not re.fullmatch(r'[0-9a-f]{64}', config['sparkle_sha256']):
        raise ValueError('Missing pinned Sparkle checksum')
    return config


def sparkle_directory(config):
    version = config['sparkle_version']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Expected a stable Sparkle version')
    archive = ROOT / '.deps' / f'Sparkle-{version}.tar.xz'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        url = f'https://github.com/sparkle-project/Sparkle/releases/download/{version}/{archive.name}'
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != config['sparkle_sha256']:
            raise ValueError('Sparkle download checksum mismatch')
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sparkle_sha256']:
        raise ValueError('Cached Sparkle checksum mismatch')
    # Always extract the verified archive into a new directory; do not trust a
    # previously extracted framework that could have been locally modified.
    directory = Path(tempfile.mkdtemp(prefix=f'sparkle-{version}-verified-', dir=archive.parent))
    with tarfile.open(archive) as bundle:
        bundle.extractall(directory, filter='data')
    return directory


def release_info(config, version, build):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Use a numeric release version, for example 0.1.0')
    if not re.fullmatch(r'[1-9]\d{0,8}', str(build)):
        raise ValueError('Build number must be a positive integer of at most 9 digits')
    return {
        'CFBundleIdentifier': config['bundle_id'],
        'CFBundleShortVersionString': version,
        'CFBundleVersion': str(build),
        'BarkEnableSwiftUI': True,
        'SUFeedURL': f"https://github.com/{config['repository']}/releases/latest/download/appcast.xml",
        'SUPublicEDKey': config['sparkle_public_key'],
        'SUEnableAutomaticChecks': True,
        'SUAutomaticallyUpdate': False,
        'SURequireSignedFeed': True,
        'SUVerifyUpdateBeforeExtraction': True,
        'SUSendProfileInfo': False,
    }


def signing_targets(app):
    """Include every Mach-O, including Crashpad, dylibs, XPCs and Sparkle tools."""
    targets = set()
    for directory, dirs, files in os.walk(app, followlinks=False):
        path = Path(directory)
        dirs[:] = [name for name in dirs if not (path / name).is_symlink()]
        if path.suffix in {'.app', '.framework', '.xpc', '.appex'}:
            targets.add(path)
        for name in files:
            file = path / name
            if not file.is_symlink():
                with file.open('rb') as stream:
                    if stream.read(4) in MACHO_MAGICS:
                        targets.add(file)
    return sorted(targets, key=lambda p: (-len(p.parts), str(p)))


def entitlements_for(target, app, chromium_src):
    # Apply upstream's entitlements explicitly. Ad-hoc development signatures
    # are not a reliable source of the entitlements required by hardened V8.
    if target == app or target == app / 'Contents/MacOS/Bark':
        return chromium_src / 'chrome/app/app-entitlements.plist'
    bundle = target if target.suffix == '.app' else next(
        (p for p in target.parents if p.suffix == '.app'), None)
    if bundle and bundle.name.startswith('Bark Helper ('):
        if 'Renderer' in bundle.name:
            return chromium_src / 'chrome/app/helper-renderer-entitlements.plist'
        if 'GPU' in bundle.name:
            return chromium_src / 'chrome/app/helper-gpu-entitlements.plist'
    return None


def sign(app, identity, chromium_src, team_id):
    if not identity.startswith('Developer ID Application:') or not identity.endswith(f'({team_id})'):
        raise ValueError('Release signing requires the configured team’s Developer ID Application identity')
    for target in signing_targets(app):
        arguments = ['codesign', '--force', '--sign', identity, '--timestamp', '--options', 'runtime']
        entitlements = entitlements_for(target, app, chromium_src)
        if entitlements:
            values = plistlib.loads(entitlements.read_bytes())
            if values.get('com.apple.security.get-task-allow'):
                raise ValueError('Release entitlements must not allow debugging')
            arguments += ['--entitlements', str(entitlements)]
        else:
            # Keep sandbox entitlements on Sparkle's already-signed XPC services.
            arguments += ['--preserve-metadata=entitlements']
        run(*arguments, target)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    details = run('codesign', '-dv', '--verbose=4', app, capture_output=True, text=True).stderr
    if f'TeamIdentifier={team_id}' not in details or 'runtime' not in details or 'Timestamp=' not in details:
        raise ValueError('Signed app lacks the expected team, hardened runtime, or secure timestamp')


def zip_app(app, destination):
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, destination)


def notarize(app, profile, output):
    submission = output / 'notarization-upload.zip'
    zip_app(app, submission)
    # --wait may exit unsuccessfully even though it returns useful JSON.
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(submission),
                             '--keychain-profile', profile, '--wait', '--timeout', '30m',
                             '--output-format', 'json'], capture_output=True, text=True)
    (output / 'notarization.json').write_text(result.stdout)
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError('Notary submission failed: ' + result.stderr.strip()) from None
    if result.returncode or status.get('status') != 'Accepted':
        raise RuntimeError(f"Notarization was not accepted; see {output / 'notarization.json'}. "
                           f"Submission: {status.get('id', 'unknown')}. No update feed was generated.")
    run('xcrun', 'stapler', 'staple', app)
    run('xcrun', 'stapler', 'validate', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    submission.unlink()


def generate_feed(sparkle, config, archive, version, build):
    feed = archive.parent / 'appcast.xml'
    arguments = [sparkle / 'bin/generate_appcast', '--account', config['sparkle_account'],
                 '--download-url-prefix', f"https://github.com/{config['repository']}/releases/download/v{version}/",
                 '--maximum-deltas', '0', '-o', feed, archive.parent]
    # CI may supply a private key through stdin; never put it on a command line.
    key = os.environ.get('SPARKLE_PRIVATE_KEY')
    if key:
        arguments += ['--ed-key-file', '-']
    run(*arguments, input=key, text=True)
    root = ET.parse(feed).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one release in the generated feed')
    enclosure = items[0].find('enclosure')
    if enclosure is None or not enclosure.get(f'{{{SPARKLE_NS}}}edSignature'):
        raise ValueError('Refusing an unsigned update archive')
    if items[0].findtext(f'{{{SPARKLE_NS}}}version') != str(build):
        raise ValueError('Generated feed build number does not match the app')
    expected_url = f"https://github.com/{config['repository']}/releases/download/v{version}/{archive.name}"
    if enclosure.get('url') != expected_url:
        raise ValueError('Generated feed download URL does not match this release')
    return feed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / '.deps/chromium-source/src/out/Bark-mac-arm64/Bark.app')
    parser.add_argument('--chromium-src', type=Path, default=ROOT / '.deps/chromium-source/src')
    parser.add_argument('--config', type=Path, default=CONFIG)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True, help='Increasing integer, independent of Chromium version')
    parser.add_argument('--output', type=Path, help='New directory for the release')
    parser.add_argument('--identity')
    parser.add_argument('--notary-profile')
    args = parser.parse_args()
    config = read_config(args.config)
    info = release_info(config, args.version, args.build)
    output = (args.output or ROOT / 'release' / f'v{args.version}').resolve()
    if output.exists():
        parser.error('Output already exists; choose a new directory to preserve previous release artifacts')
    identity = args.identity or config['signing_identity']
    profile = args.notary_profile or config['notary_profile']
    verify_release_source(args.source)
    # Check credentials before copying or signing the large application.
    run('xcrun', 'notarytool', 'history', '--keychain-profile', profile,
        '--output-format', 'json', stdout=subprocess.DEVNULL)
    sparkle = sparkle_directory(config)
    # A separate directory prevents generate_appcast seeing the notary upload.
    output.mkdir(parents=True)
    revision = run('git', 'rev-parse', 'HEAD', capture_output=True, text=True).stdout.strip()
    dirty = bool(run('git', 'status', '--porcelain', capture_output=True, text=True).stdout.strip())
    downloads = output / 'downloads'
    downloads.mkdir()
    app = output / 'Bark.app'
    stage(args.source, app, info)
    run('ditto', sparkle / 'Sparkle.framework', app / 'Contents/Frameworks/Sparkle.framework')
    run('ditto', sparkle / 'LICENSE', app / 'Contents/Resources/Sparkle-LICENSE.txt')
    sign(app, identity, args.chromium_src, config['team_id'])
    notarize(app, profile, output)
    archive = downloads / f'Bark-{args.version}-mac-arm64.zip'
    zip_app(app, archive)
    if archive.stat().st_size >= 2 * 1024**3:
        raise ValueError('Archive exceeds GitHub’s 2 GiB per-asset limit')
    feed = generate_feed(sparkle, config, archive, args.version, args.build)
    with archive.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    (downloads / 'SHA256SUMS').write_text(f'{checksum}  {archive.name}\n')
    (output / 'release-manifest.json').write_text(json.dumps({
        'version': args.version, 'build': str(args.build), 'repository': config['repository'],
        'source_commit': revision, 'source_dirty': dirty,
        'sha256': {archive.name: checksum, feed.name: hashlib.sha256(feed.read_bytes()).hexdigest()},
    }, indent=2) + '\n')
    print(f'Notarized release and signed feed ready in {downloads}')
    print('Publish all three download files together using tools/publish_release.py.')


if __name__ == '__main__':
    main()
