#!/usr/bin/env python3
"""Check the Swift projection and native ABI without a Chromium build/profile."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

import chromium


def main():
    if platform.system() != 'Darwin':
        raise RuntimeError('SwiftUI bridge tests require macOS with Xcode')
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='bark-swift-bridge-') as directory:
        stage = Path(directory)
        for name, source in chromium.overlay_files().items():
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        output = stage / 'out'
        subprocess.run(['python3', stage / 'compile_swift.py', '--source', stage,
                        '--output', output, '--sdk', sdk,
                        '--target', architecture + '-apple-macosx13.0'], check=True)
        executable = output / 'BarkSidebarTests'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
                        '-sdk', sdk, '-target', architecture + '-apple-macosx13.0',
                        '-module-cache-path', output / 'module-cache', '-I', output,
                        '-L', output, '-lBarkCore',
                        *sorted((stage / 'mac').glob('*.swift')),
                        *sorted((chromium.ROOT / 'tools/fixtures').glob('*Tests.swift')),
                        '-o', executable], check=True)
        subprocess.run([executable], check=True)


if __name__ == '__main__':
    main()
