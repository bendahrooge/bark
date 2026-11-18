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
                        '-L', output, '-lBarkCore', stage / 'mac/ChromiumSidebar.swift',
                        stage / 'mac/BarkFeatures.swift',
                        stage / 'mac/SiteControls.swift',
                        stage / 'mac/PageFrame.swift', stage / 'mac/Organization.swift',
                        stage / 'mac/CommandBar.swift', stage / 'mac/Preferences.swift',
                        stage / 'mac/Feedback.swift',
                        stage / 'mac/SidebarBackground.swift', stage / 'mac/SpaceEditor.swift',
                        stage / 'mac/BarkImportReader.swift', stage / 'mac/ChromiumBarkImport.swift',
                        chromium.ROOT / 'tools/fixtures/ChromiumSidebarTests.swift',
                        chromium.ROOT / 'tools/fixtures/BarkImportReaderTests.swift',
                        chromium.ROOT / 'tools/fixtures/OrganizationTests.swift',
                        chromium.ROOT / 'tools/fixtures/CommandBarTests.swift',
                        chromium.ROOT / 'tools/fixtures/PreferencesTests.swift',
                        chromium.ROOT / 'tools/fixtures/PeekTests.swift',
                        chromium.ROOT / 'tools/fixtures/FeedbackTests.swift',
                        '-o', executable], check=True)
        subprocess.run([executable], check=True)


if __name__ == '__main__':
    main()
