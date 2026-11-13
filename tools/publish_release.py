#!/usr/bin/env python3
"""Upload a verified Bark release as a draft; --publish makes it the update feed.

Authenticate with `gh auth login` first, or supply GH_TOKEN in GitHub Actions.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

from release_macos import ROOT, SPARKLE_NS, read_config, release_info


def capture(*args):
    return subprocess.check_output(args, text=True).strip()


def validate_downloads(downloads, config, version, build):
    release_info(config, version, build)
    archive = downloads / f'Bark-{version}-mac-arm64.zip'
    feed = downloads / 'appcast.xml'
    checksums = downloads / 'SHA256SUMS'
    metadata = json.loads((downloads.parent / 'release-manifest.json').read_text())
    if (metadata['version'], metadata['build'], metadata['repository']) != (version, str(build), config['repository']):
        raise ValueError('Release manifest does not match requested release')
    for file in (archive, feed):
        with file.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != metadata['sha256'][file.name]:
            raise ValueError(f'{file.name} changed after notarization/feed signing')
    if checksums.read_text() != f"{metadata['sha256'][archive.name]}  {archive.name}\n":
        raise ValueError('SHA256SUMS does not match the release archive')
    item = ET.parse(feed).getroot().find('./channel/item')
    if item is None or item.findtext(f'{{{SPARKLE_NS}}}version') != str(build):
        raise ValueError('Feed build number does not match')
    enclosure = item.find('enclosure')
    if enclosure is None or not enclosure.get(f'{{{SPARKLE_NS}}}edSignature'):
        raise ValueError('Missing update signature')
    expected = f"https://github.com/{config['repository']}/releases/download/v{version}/{archive.name}"
    if enclosure.get('url') != expected:
        raise ValueError('Feed download URL does not match release')
    return [archive, feed, checksums], metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    parser.add_argument('--downloads', type=Path)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    config = read_config()
    downloads = args.downloads or ROOT / 'release' / f'v{args.version}' / 'downloads'
    files, manifest = validate_downloads(downloads, config, args.version, args.build)
    if not args.notes.is_file():
        parser.error('Release notes file does not exist')
    if capture('git', 'status', '--porcelain'):
        parser.error('Commit and push the source before publishing')
    revision = capture('git', 'rev-parse', 'HEAD')
    if revision != manifest['source_commit'] or manifest['source_dirty']:
        parser.error('Package a release from this clean commit before publishing')
    repository = config['repository']
    repo = json.loads(capture('gh', 'api', f'repos/{repository}'))
    if repo['private']:
        parser.error('The Sparkle feed requires a public release repository')
    remote = json.loads(capture('gh', 'api', f"repos/{repository}/commits/{repo['default_branch']}"))
    if remote['sha'] != revision:
        parser.error('Push this commit to the default branch before publishing')
    releases = json.loads(capture('gh', 'api', '--paginate', '--slurp', f'repos/{repository}/releases?per_page=100'))
    releases = [release for page in releases for release in page]
    if any(release['tag_name'] == f'v{args.version}' for release in releases):
        parser.error('This version already has a release; do not overwrite signed updates')
    stable = [r for r in releases if not r['draft'] and not r['prerelease']]
    if stable:
        latest = json.loads(capture('gh', 'api', f'repos/{repository}/releases/latest'))
        asset = next((a for a in latest['assets'] if a['name'] == 'appcast.xml'), None)
        if not asset:
            parser.error('Latest release has no appcast; inspect it before replacing the update feed')
        with urllib.request.urlopen(asset['browser_download_url'], timeout=60) as response:
            old_feed = ET.fromstring(response.read())
        previous = [int(e.text) for e in old_feed.findall(f'./channel/item/{{{SPARKLE_NS}}}version')]
        if not previous or int(args.build) <= max(previous):
            parser.error('Build number must exceed the published update build')
    # Draft first: the stable /latest feed cannot change during a partial upload.
    subprocess.run(['gh', 'release', 'create', f'v{args.version}', '--repo', repository,
                    '--target', revision, '--draft', '--title', f'Bark {args.version}',
                    '--notes-file', str(args.notes), *map(str, files)], check=True)
    if args.publish:
        subprocess.run(['gh', 'release', 'edit', f'v{args.version}', '--repo', repository,
                        '--draft=false', '--latest'], check=True)
    print(capture('gh', 'release', 'view', f'v{args.version}', '--repo', repository,
                  '--json', 'url', '--jq', '.url'))


if __name__ == '__main__':
    main()
