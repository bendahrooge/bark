"""Builds Bark's app icon (app.icns and Assets.car) from one 1024 px PNG.

Chromium's bundle ships both files: Finder and older macOS read app.icns,
while CFBundleIconName ("AppIcon") selects the icon in Assets.car.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

# (points, scale) pairs required for a macOS AppIcon.
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def resize(source, pixels, output):
    subprocess.run(['sips', '-z', str(pixels), str(pixels), str(source), '--out', str(output)],
                   check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--minimum-macos', required=True)
    args = parser.parse_args()
    source = Path(args.source).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bark-app-icon-') as directory:
        work = Path(directory)
        iconset = work / 'app.iconset'
        appiconset = work / 'Assets.xcassets/AppIcon.appiconset'
        iconset.mkdir()
        appiconset.mkdir(parents=True)
        images = []
        for points, scale in SIZES:
            suffix = '@2x' if scale == 2 else ''
            name = f'icon_{points}x{points}{suffix}.png'
            resize(source, points * scale, iconset / name)
            (appiconset / name).write_bytes((iconset / name).read_bytes())
            images.append({'idiom': 'mac', 'size': f'{points}x{points}', 'scale': f'{scale}x', 'filename': name})
        info = {'author': 'xcode', 'version': 1}
        (work / 'Assets.xcassets/Contents.json').write_text(json.dumps({'info': info}))
        (appiconset / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}))
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(output / 'app.icns')], check=True)
        subprocess.run(['xcrun', 'actool', '--compile', str(work), '--platform', 'macosx',
                        '--minimum-deployment-target', args.minimum_macos, '--app-icon', 'AppIcon',
                        '--output-partial-info-plist', str(work / 'partial.plist'),
                        '--output-format', 'human-readable-text', '--notices', '--warnings', '--errors',
                        str(work / 'Assets.xcassets')], check=True, stdout=subprocess.DEVNULL)
        (output / 'Assets.car').write_bytes((work / 'Assets.car').read_bytes())


if __name__ == '__main__':
    main()
