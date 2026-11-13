# Bark

Bark is an Arc-style browser built on a **Chromium source fork**, with a native Swift sidebar on macOS and Chrome extensions integrated with real Chromium tabs and browser windows.

**Migration status:** the full macOS Chromium application builds and runs the experimental Swift sidebar through a direct Objective-C++ bridge to native windows, tabs, and profiles. Browser integration checks cover extension behavior, native layout, and Incognito storage isolation. Chrome Web Store installation, a real extension popup, profile isolation, and extension persistence after a clean restart have also been verified. See the [validation record](docs/chromium-validation.md). Chromium is the only engine in this repository; the CEF adapter, preview shell, and associated build/test tooling have been removed. Developer ID signing, notarization, and signed Sparkle updates are configured; complete UI parity and engine-profile migration remain unfinished. See [release instructions](SIGNING_AND_NOTARIZATION.md).

The Swift sidebar has an Arc-inspired space heading, emoji dock, roomier tab rows, hover-only tab actions, a compact address field, and translucent space colors. Ordinary and Incognito windows use the sidebar; private windows have a persistent Incognito indicator and omit space management. It supports resizing, a traffic-light-adjacent collapse control, edge-hover reveal, pinned tabs, favicons, and system/light/dark appearance. Spaces have independent tabs, colors, and emoji, with a profile selected when creating each space. Spaces assigned to the same profile share sign-ins and extensions. Switching profiles keeps one Bark window visible. Shared Arc import parsing and folder models remain available for the remaining interface migration.

## Source layout

```text
apps/macos/src/           Shared macOS UI and import utilities
apps/macos/src/chromium/  Native Chromium sidebar and Objective-C++ bridge
apps/windows/src/        Reserved Windows interface
apps/linux/src/          Reserved Linux interface
packages/core/           Portable Swift state, Arc import, folders, themes and navigation
engine/chromium/          Source engine: lock, patches, overlay, GN presets
tools/chromium.py         Source checkout, patch verification, build and update driver
tools/fixtures/extension/ Local MV3 fixture for Chromium integration tests
```

The Chromium integration preserves native `Profile`, `BrowserWindowInterface`, `TabStripModel`, extension services, permissions, and lifecycle. Swift sends commands and receives snapshots through Objective-C++, using Chromium session IDs for tabs. Windows and Linux keep independent UI folders. No Chromium rendering or extension-security fork is planned.

## Build setup

See [Chromium build and migration instructions](engine/chromium/README.md). A remote Linux VM is suitable for the Linux foundation and portable checks. The native macOS build needs a Mac with Xcode. Run the build preflight before downloading source; Bark requires at least 150 GiB free for the initial checkout and build.

```sh
python3 tools/chromium.py doctor --work-dir /path/to/build-volume
python3 tools/chromium.py verify-patches
python3 tools/chromium.py sync --work-dir /path/to/build-volume
python3 tools/chromium.py build --work-dir /path/to/build-volume --target mac-arm64
# On an x86-64 Linux build host, use --target linux-x64.
```

These commands build the Chromium development application with Bark's identity. The macOS Swift interface is enabled with `--bark-swift-ui`. Release packaging and notarization use the [macOS release tooling](SIGNING_AND_NOTARIZATION.md).

The development flag `--bark-swift-ui` enables the native Swift sidebar on macOS. Use a disposable profile for integration work; see the [native integration and validation instructions](engine/chromium/README.md#native-interface-integration). Run `python3 tools/test_chromium_swift.py` to check the Swift bridge without compiling Chromium, and `node tools/test_chromium_browser.mjs --headed --swift-ui` to exercise extensions in the compiled native window. Run `node tools/test_chromium_spaces.mjs` to verify space/profile switching, persistence, isolation, and window grouping.

## Chromium security updates

```sh
python3 tools/chromium.py check
python3 tools/chromium.py update
```

The daily workflow checks official stable release metadata. Updates pin an exact upstream revision and verify Bark's small patch stack before changing the lockfile. Build and regression tests are still required; patches applying cleanly do not establish release readiness. Security fixes should be validated promptly, including between weekly batches. No workflow automatically merges or publishes a release.

Regular CI runs shared Swift tests, Python tooling tests, and lightweight source-patch checks. Full Chromium builds use a manually triggered workflow on trusted self-hosted Mac/Linux runners. Run portable checks locally with:

```sh
swift test --scratch-path .build/core
python3 -m unittest discover -s tools/tests
```

The new macOS profile location is `~/Library/Application Support/BarkChromium`; existing `BarkNative` preview data is preserved. Encryption keeps Bark's **Bark Safe Storage / Bark** keychain identity. Development bundles use a stable signing identity; encrypted-storage restart tests and an explicit migration path remain required before replacing older installs. Release signing and notarization are handled by `tools/release_macos.py`.

MIT licensed. Chromium and bundled components retain their licenses. Bark is independent of Arc and Google.
