# Chromium source migration

Chromium source is Bark's engine. The macOS browser-source build runs an experimental Swift sidebar while retaining Chromium's native extension system. The build, extension checks, and native interaction results are recorded in [the validation report](../../docs/chromium-validation.md). Complete UI parity and user-data migration remain in progress. [Signed release packaging and updates](../../SIGNING_AND_NOTARIZATION.md) use Developer ID, notarization, and Sparkle.

The lockfile pins an official Mac Stable Chromium revision, depot_tools revision, and SHA-256 hashes for Bark's patches. Three patches change macOS/Linux profile locations and the unbranded macOS keychain name. A fourth adds macOS window/layout hooks, routes address focus to Swift, hides the duplicate toolbar, and links Swift only into the browser framework. A fifth prevents Chromium's default-pinning code from trying to pin an already-pinned extension during reinstallation. A sixth anchors native extension and site-permission bubbles to sidebar controls. A seventh aligns the native titlebar, makes default new tabs blank, and applies Bark product labels during locale repacking while preserving resource IDs, URLs, and upstream attribution. An eighth persists space membership and logical window grouping through Chromium’s session-restore machinery, and defaults Bark to restoring the last session without overriding explicit startup preferences or policy. Build branding uses Chromium's `branding_file_path` argument. No extension verification, renderer sandbox, site isolation, or certificate checks are disabled.

## Build hosts

- macOS: Apple Silicon Mac with Xcode and its Metal compiler component; start with 150 GiB free, preferably 200–300 GiB. The actual source, output, cache, and symbol footprint varies. If `xcrun metal --version` reports a missing toolchain, install it with `xcodebuild -downloadComponent MetalToolchain`.
- Linux: x86-64 VM, ideally 16 vCPUs, 32 GiB RAM, and 200–300 GiB SSD storage. The [upstream Linux baseline](https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md) specifies at least 100 GB disk and 8 GB RAM. Our larger preflight budget leaves build headroom.
- A Linux VM builds Linux Chromium and runs portable tests. It does not supply Apple's SwiftUI/AppKit SDKs. The [standard macOS build](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md) requires a Mac with Xcode.
- Windows source/UI folders remain reserved. A Windows source-build preset, identity patches, packaging, and native validation are still required.

Git and Git LFS must be available on `PATH` before syncing dependencies. On macOS with Homebrew, install the latter with `brew install git-lfs`; on Linux use your distribution’s `git-lfs` package. The preflight checks for both before starting downloads.

Run on the build host from a checkout of Bark. Use an absolute path on a volume with enough capacity:

```sh
python3 tools/chromium.py doctor --work-dir /path/to/bark-build
python3 tools/chromium.py sync --work-dir /path/to/bark-build

# Linux only: review and run Chromium's OS package installer if dependencies
# are missing. It requires administrator access; Bark never runs it silently.
# /path/to/bark-build/src/build/install-build-deps.sh

python3 tools/chromium.py build --work-dir /path/to/bark-build --target linux-x64
# On an Apple Silicon Mac, use --target mac-arm64 instead.
```

`sync` bootstraps the pinned depot_tools utilities and downloads source/dependencies without running Chromium's hooks. `build` applies the reviewed patch set, copies the branding overlay, runs upstream hooks, generates GN files, and builds the `chrome` target with autoninja. Bootstrap and checkout/dependency hooks execute upstream build tooling. Expect a large download and a substantial first build. Outputs are under `src/out/Bark-<target>/`: `chrome` on Linux or `Bark.app` on macOS. These are development foundation builds with Chromium's browser UI, **not the completed native Bark interface or signed releases**.

If Google's source Git endpoint is unavailable, use `python3 tools/chromium.py sync --github-mirror --work-dir /path/to/bark-build`. This seeds the same exact pinned commit from [Chromium’s official GitHub mirror](https://github.com/chromium/chromium), verifies the checkout revision, and leaves `origin` pointing to Chromium upstream. Dependencies still use their pinned upstream sources. It does not change the lockfile, select a different release, or discard local edits.

Use `build --jobs 8` to cap local compiler concurrency when sharing the machine with other work. Without `--jobs`, Chromium's build tool chooses its defaults.

On macOS, `build` checks the sidebar's GN dependencies, compiles the Swift bridge and its window/layout hooks, and links a small ABI check using Chromium's actual linker before starting the full browser target. This catches integration API and Swift runtime-linking changes early during Chromium updates; it does not replace the full build and runtime checks.

`sync` and `configure` verify each recorded Git dependency’s checked-out revision. You can also run `python3 tools/chromium.py verify-deps --work-dir /path/to/bark-build` after an interrupted checkout. A successful downloader exit alone is not sufficient if a dependency still has an incomplete working tree; Bark reports the affected paths and never resets them automatically.

The script refuses to overwrite developer changes. At the same engine revision, `prepare` can refresh patches and overlay files only after checking every previously prepared file against its recorded hash. It reconstructs the patch stack from the pinned upstream files in a staging directory, preserves compiled objects, and rolls back on write failure. Removed overlays or a new engine pin require a fresh checkout. Stop builds before preparing or configuring changes. Existing dependency checkouts and old outputs are never deleted automatically. `BARK_CHROMIUM_WORK_DIR` can set the default location. No build or test uses the user's installed Chrome profile.

The source build uses `~/Library/Application Support/BarkChromium` on macOS and `~/.config/bark` on Linux. Profiles from the retired preview use `BarkNative` and remain intact. No cookie/database copying is performed during this migration. The production macOS keychain service/account remain **Bark Safe Storage / Bark**; stable certificate signing and real encrypted-storage restart tests are required before replacing the existing app. Do not distribute an ad-hoc foundation build as a finished release.

## macOS development packaging

Stage a built application with the existing Bark artwork and a stable development signing identity:

```sh
python3 tools/package_chromium_macos.py --identity YOUR_SIGNING_IDENTITY
open "release/chromium-development/Bark Chromium.app" --args --bark-swift-ui
```

The packager refuses to replace a running destination, signs nested helpers/frameworks before the outer bundle, and verifies the result. Keep the same certificate across rebuilds so keychain access is associated with a stable signing identity. This creates a development bundle; notarized distribution and real encrypted-storage restart validation remain separate release gates. The default output filename retains `Bark Chromium.app` for existing local launch instructions, but its displayed product name and icon are Bark.

`overlay/rebrand_strings.py` changes product names in the final localized text packs. Legal credits, technical identifiers, URLs, compressed resources, and unknown/binary resources remain unchanged. Six portable tests cover the transformation. The small repack hook avoids maintaining edits to Chromium's translated source catalogs across weekly updates.

## Extension foundation check

After the build completes, run the local Manifest V3 fixture with Node 18 or newer:

```sh
node tools/test_chromium_browser.mjs
# In a logged-in macOS desktop session, also validate native action popups:
node tools/test_chromium_browser.mjs --headed --swift-ui
# For a custom build directory, pass the executable (not its .app directory):
# node tools/test_chromium_browser.mjs /path/to/Bark.app/Contents/MacOS/Bark
# node tools/test_chromium_browser.mjs /path/to/linux-output/chrome
```

The check launches the compiled browser headlessly, controls it over a private DevTools pipe, and serves test pages on loopback. It verifies content scripts, service-worker messaging, the tabs API, declarative request filtering, extension storage across a clean restart, and separate-profile storage. Every profile is temporary; macOS uses mock key storage and Linux uses basic password storage only for this test. Logs and a JSON report are saved under `test-results/chromium-browser/`.

`--headed` adds unpacked loading through Chromium's debugging API, a real toolbar-action popup, `activeTab`/scripting on an origin outside the fixture's standing permissions, uninstall/request-rule cleanup, last-tab window closing, normal multi-window shutdown, and primary Incognito window layout/storage/extension isolation. `--swift-ui` enables the native sidebar in those windows and checks its reserved layout area, reclaimed page height, and blank default new-tab document. Commands use Chromium's trusted browser DevTools session over the private pipe, only with disposable profiles; no debugging port is exposed.

Chromium 157 deliberately discards CDP-installed extensions on restart (`ExtensionPrefs::CleanUpCdpInstalledExtensions`). The headed test checks that cleanup and reinstalls the fixture, including the retained-toolbar-pin regression covered by patch 0005. It does not treat CDP installation as persistent. The headless checks verify extension data across restarts with the fixture explicitly loaded each time. Ordinary installation persistence must be checked separately using the normal `chrome://extensions` installer or Chrome Web Store.

The automated checks exercise an unpacked local extension. Separate native testing verified uBlock Origin Lite installation through Chrome Web Store, its popup, profile isolation, and persistence after a clean restart; see the [validation record](../../docs/chromium-validation.md). This does not establish support for every extension or production encrypted storage. Repeat the relevant checks for each release pin.

## Update process

```sh
python3 tools/chromium.py check
python3 tools/chromium.py verify-patches
python3 tools/chromium.py update
# Review the changed lockfile, then build the new pin on each release platform.
```

The daily update workflow compares the pin with official Mac Stable metadata. `update` first checks the patch stack against the candidate revision and changes the lock only if every patch applies. A clean patch application is not a compile or security test. Release builds still need native UI, extensions, permissions, persistence, sandbox, signature, and shutdown tests. Urgent security fixes should ship as soon as validated, including between weekly releases. Changes to depot_tools and patch hashes are reviewed separately.

Mac is currently the reference channel. Before adding Linux/Windows releases, track their stable release metadata separately so platform-specific security releases cannot be missed or delayed. Full source-build CI is manual and requires a trusted self-hosted runner with the `bark-chromium` label; ordinary pull-request CI only runs portable tests and lightweight patch checks. This avoids putting untrusted PR code on a persistent build machine.

## Native interface integration

`apps/macos/src/chromium/` implements the source-build sidebar. Two `NativeViewHost` instances attach the sidebar and its compact titlebar controls to the real Chromium `BrowserView`, leaving the macOS traffic lights exposed. The Objective-C++ controller observes `TabStripModel`, coalesces snapshots on Chromium's UI task runner, and resolves commands by stable tab session ID. Native tab/extension creation and removal feed the same model. Browser teardown invalidates queued commands, removes observers, detaches the native view, and releases the Swift callback.

The development flag `--bark-swift-ui` enables the sidebar for ordinary and Incognito macOS windows. The sidebar replaces the native top toolbar and tabstrip; guest windows, extension/app popups, and fullscreen retain Chromium's native interface. The bridge supports navigation, tab creation/selection/close/pinning, Chromium favicons, resizing, persisted collapse state, temporary edge-hover reveal, theme/emoji, profile selection/creation, extensions, history, and settings. Cmd+L focuses the sidebar address field and reveals it when collapsed. The puzzle-piece button opens Chromium's native extension menu; the site-information button opens its native permissions/security dialog and reflects Chromium's security warning state. Invisible, noninteractive Views anchors track those Swift controls so native extension popups and permission prompts remain attached to the window. Chromium still owns their content and enforcement. Spaces are catalog entries in local state, independent of Chromium profiles. New-space creation offers a profile picker; new-profile creation does not open a window. Spaces sharing a profile filter the same real tab strip. Different profiles retain separate Chromium browser hosts in one logical Bark window: switching shows one host at the same position and hides its peers. Explicit new windows own independent groups. Session metadata restores tab membership and window grouping; the last active space is saved with the group. Existing profiles receive an initial space with their previous theme/emoji; their cookies and databases remain in place. Profile assignment currently occurs at space creation. Incognito uses its own off-the-record tab strip, displays a persistent private-mode indicator, and omits space creation/switching/customization. Private resize/collapse changes stay in memory. Chromium retains control of private storage and per-extension Incognito permissions. No cross-profile tab transfer or reuse of the retired preview's cookies/databases is performed.

`overlay-sources.json` maps the real application/shared-core sources into `src/bark`; do not edit the prepared copies. A small GN action compiles Swift static libraries using the selected Xcode. This avoids modifying Chromium's macOS compiler toolchain. Linux builds do not compile the Swift target.

```sh
python3 tools/test_chromium_swift.py
node tools/test_chromium_browser.mjs --headed --swift-ui
node tools/test_chromium_spaces.mjs
```

The native space suite uses a disposable profile, loopback pages, and the real command bridge. The file-based test driver starts only with an explicit directory under `--user-data-dir` and a private `--remote-debugging-pipe`; it is inactive during normal app launches. Reports are saved under `test-results/chromium-spaces/`.

The Swift checks cover snapshot decoding, stable command IDs, address editing across updates, malformed input, Unicode payloads, shutdown callback invalidation, and retained native-view creation/destruction. They do not substitute for running the complete application. Full UI parity (including folders/import, remaining keyboard shortcuts, and fullscreen), real profile migration, broader native window regressions, and signed packaging remain release gates.

Keep the existing Swift space themes, emoji, blank landing surfaces, and compact sidebar behavior. Preserve Chromium's extension toolbar/permission machinery during the native window work and run the native suite using `tools/fixtures/extension`. Source patches belong in `patches/`; platform UI belongs in `apps/<platform>/src/`. Changes to Blink, V8, or extension permission enforcement are outside this migration's scope.
