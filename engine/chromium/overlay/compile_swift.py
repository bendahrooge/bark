#!/usr/bin/env python3
"""Compile Bark's macOS UI with the selected Xcode, into static archives."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--swiftc', type=Path)
    parser.add_argument('--target', required=True)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    target = args.target.replace('x64-', 'x86_64-')
    compiler = str(args.swiftc) if args.swiftc else subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--find', 'swiftc'], text=True).strip()
    common = [compiler, '-swift-version', '5', '-O',
              '-sdk', str(args.sdk.resolve()), '-target', target,
              '-module-cache-path', str(output / 'module-cache'),
              '-parse-as-library', '-emit-library', '-static']
    core = sorted((source / 'core').glob('*.swift'))
    if not core:
        raise RuntimeError('BarkCore sources missing from prepared overlay')
    subprocess.run([*common, '-module-name', 'BarkCore', '-emit-module',
                    '-emit-module-path', str(output / 'BarkCore.swiftmodule'),
                    *map(str, core), '-o', str(output / 'libBarkCore.a')], check=True)
    ui = [source / 'mac' / name for name in ('ChromiumSidebar.swift', 'SidebarBackground.swift', 'SpaceEditor.swift')]
    subprocess.run([*common, '-module-name', 'BarkSidebar', '-I', str(output),
                    *map(str, ui), '-o', str(output / 'libBarkSidebar.a')], check=True)


if __name__ == '__main__':
    main()
