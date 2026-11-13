# Chromium / Swift integration validation

Validated on November 10–11, 2026, on an Apple Silicon Mac with Xcode 27.2. Chromium is pinned to **157.0.8103.51**, revision `653674df293788cf4932c40d914e9e15b41a2d31`. This is the experimental source build enabled with `--bark-swift-ui`.

## Build and automated checks

- The complete `chrome` target builds, including Chromium's native helper-library and framework checks.
- GN dependency checking and a small executable linked with Chromium's actual linker pass. That executable also successfully creates and releases the Swift native view.
- **25 Chromium tooling tests** pass. Same-pin preparation verifies owned files, preserves unrelated work, and leaves unchanged files' timestamps intact to retain compiled dependencies. The retired engine's three tooling tests were removed with its implementation.
- **26 Swift bridge checks** pass: snapshot decoding, stable IDs, address editing and cancellation, origin/port display, optional sidebar state, malformed input, Unicode commands, callback shutdown, and both native-view lifetimes.
- **24 browser checks** pass with `node tools/test_chromium_browser.mjs --headed --swift-ui`: Manifest V3 content scripts and service workers, messaging, tabs, storage across restarts and separate profiles, declarative request blocking, native action popups, `activeTab`/scripting, reinstall, uninstall, sidebar layout reservation, reclaimed page height, last-tab window closing, and multi-window shutdown.

Latest browser report: `test-results/chromium-browser/run-2qK0Yr/report.json`. Native header/branding review: `test-results/chromium-ui/header-branding-report.json`. Native toolbar-removal review: `test-results/chromium-ui/sidebar-toolbar-report.json`. Earlier interaction report: `test-results/chromium-ui/report.json`. These local artifacts are ignored by Git.

## Native interaction and Web Store checks

[uBlock Origin Lite](https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh), version **2026.1103.1743**, installed through the normal Chrome Web Store flow and Chromium's native permission prompt. Its toolbar popup opened on a regular page. The extension remained enabled after a clean browser restart, with developer mode off.

The Swift sidebar successfully created, selected, navigated, pinned, and closed real Chromium tabs. The pinned tab restored after restarting. The Extensions control opened Chromium's actual extension manager. Resizing changed the sidebar from 260 to 280 points. Light appearance updated both the Swift sidebar and native browser content; the initial system appearance was dark.

In the earlier implementation, creating a space made a persistent native Chromium profile. This behavior is superseded by the separate-space catalog described below. The new space had an empty extension list while the original retained uBlock Origin Lite. Switching between profile windows preserved this isolation. The new space, its 🚀 emoji, and Ocean theme survived restarting.

The final two-profile shutdown and subsequent single-profile shutdown both exited with code 0. Both profiles recorded a normal exit, and the final restart showed no crash-restore prompt. Native app-menu automation could not reliably activate Quit, so this check used Chromium's normal SIGINT quit handler. The automated suite also checks browser-protocol shutdown.

## Defects caught and corrected

- Swift runtime search paths and the SDK's header-only CoreAudioTypes autolink needed explicit handling for Chromium's linker. Swift dependencies are scoped to the browser framework so sandbox helper loaders retain their required library layout. The build now links a small Swift ABI check before the full browser target.
- Chromium's default extension-pinning code could try to pin an already-pinned action after reinstalling a CDP-loaded extension. This reproduced with the Swift sidebar disabled. Patch 0005 guards the redundant operation while retaining permission and policy checks.
- A queued Swift snapshot could run after a window's last tab disappeared. Chromium's forward-navigation helper requires an active tab. The bridge now guards empty/closing tab strips. The new window-shutdown regression reproduced the crash before this fix and passes afterward.

## November 11 sidebar refinement

The sidebar now has a compact origin display, a space heading and emoji dock, 36-point tab rows with softer selection/hover treatments, hover-only tab actions, and stronger translucent theme tints. A separate header host places collapse/navigation controls alongside the native traffic lights. Collapse releases the sidebar's reserved page width; the window-edge monitor temporarily reveals it without resizing the page. Resize and collapse preferences persist. Native menus, address editing, and space editors keep a revealed sidebar open; observers and pending dismissal work are removed during teardown.

The layout patch reserves room for the collapse control when the native toolbar expands across the window. Fullscreen retains Chromium's normal tabstrip. The complete build, 15 Swift bridge checks, and 17 native browser/extension checks pass for these changes. After the Mac was unlocked, native review confirmed collapse/restore, resizing from 280 to the 200-point minimum and back, readable light/dark appearance, compact-address navigation, Escape cancellation, and the header Back control. Edge entry revealed an overlay without reducing page width, and moving into the page dismissed it. A second edge-entry check used a middle-button pointer action, which is not registered by the monitor; this exercises the mouse-movement path independently of its primary-click fallback. The space appearance popover opened and cancelled through accessibility; its separate popup window was not included in the main-window screenshot.

Review caught and fixed two accessibility issues: the compact address field previously disappeared from accessibility when showing an origin, and collapsed sidebar descendants remained exposed. The field now stays a real editable control, and the hidden sidebar is excluded from accessibility. Blank tabs use a neutral empty-page icon. Both review-session shutdowns exited cleanly. The final development bundle was rebuilt, ad-hoc signed, and passed deep strict signature verification.

## Sidebar replaces the top toolbar

The November 11 build removes the duplicate horizontal toolbar from ordinary macOS windows using the Swift sidebar. Page content fills the released space. Chromium's native toolbar objects and extension services remain alive; patch 0006 redirects extension menus, extension action popups, installation bubbles, page information, and permission prompts to native anchors aligned with the sidebar controls. The site-information button reflects Chromium's security classification and opens its own native dialog.

Native review confirmed the sidebar's extensions button opens Chromium's extensions menu and the installed uBlock Origin Lite popup. The site-information dialog exposes connection security, cookies/site data, and site settings. A loopback page triggered the native notification-permission prompt; closing it returned the default permission state without granting access. Edge-hover reveal and dismissal continued to work with the top toolbar removed.

Cmd+L reveals the sidebar when collapsed and selects the complete URL. Review caught an asynchronous selection problem when SwiftUI changed the resting origin into the full address. The address is now an explicitly owned AppKit text field inside SwiftUI; updates leave unchanged editor text alone to preserve selection. The final build was checked for full-URL selection, replacement typing, Escape restoration in expanded and collapsed modes, Enter navigation, and Back navigation to a blank page. A final screenshot confirmed the horizontal toolbar is absent and the address remains aligned in the sidebar.

The final complete build, 15 Swift bridge checks, and 19 browser checks pass. The new page-height assertions pass during extension installation and after restarting. Development packaging passed deep strict ad-hoc signature verification. Intermediate review sessions exited with code 0; the final disposable review window is left open on a blank page. Fullscreen and private windows retain their native Chromium interface.

## Window header and product identity

Patch 0007 gives the native traffic lights a 38-point titlebar and disables the extra SwiftUI safe-area inset inside the positioned header. Native measurements put all three traffic-light centers and the header center at the same vertical coordinate; screenshots also confirm the rendered Swift buttons align. The header exposes its empty space as an AppKit mouse target, with button targets excluded. Space dock glyphs are now 13 points inside 28-point targets.

Native default new-tab navigation now resolves to an empty `about:blank` document while retaining the virtual new-tab URL. The sidebar presents it as a blank address and neutral new-tab icon. The headed browser suite checks the actual document and empty body. Normal Chromium extension/policy URL overrides keep their earlier handling.

Locale repacking changes product labels to Bark without changing resource IDs or translated message layouts. Actual packed English strings and native Settings pages confirm “About Bark” and Bark default-browser text. Default-browser infobars use a neutral globe, and development packaging uses the existing Bark artwork and displayed name. Legal attribution, license payloads, technical identifiers, URLs, and saved user profile names remain intact.

The final development bundle is signed with the existing Apple Development certificate and passes deep strict signature verification. Reusing this identity avoids a different ad-hoc identity on every rebuild. The encryption-availability relaunch warning is not suppressed: it reports unavailable encrypted storage and needs a real-keychain restart check. This review used disposable profiles with mock keychain storage.

The complete build, 25 Python tooling tests, 16 Swift bridge checks, and 20 browser/extension checks pass. The Mac locked during final validation of the revised header drag handling; that interaction remains pending until the desktop is unlocked. Local geometry and packaging logs are under `test-results/chromium-ui/` and `test-results/chromium-source/`.

## Incognito sidebar

Ordinary Incognito windows now use the same Swift navigation sidebar and header as regular windows. The private window has an Incognito heading and a header indicator that remains visible when collapsed. Space switching, creation, customization, and the persistent library dock are omitted. Both sides of the command bridge reject private-window space/appearance changes, and private resize/collapse changes remain in memory. Guest/system profiles, app popups, and fullscreen keep their previous native interface.

The complete Chromium build passes, along with 25 Python tooling tests, 22 Swift bridge checks, and 24 browser checks. The new native regression opens primary Incognito windows through Chromium's normal windows API with the sidebar flag enabled. It verifies reserved sidebar width and reclaimed top-toolbar height; separation of ordinary/private cookies and local storage; private storage surviving reload within a session; clearing after the last private window closes; ordinary data remaining intact; and clean teardown. The extension is active in the normal window but cannot read the Incognito window it creates or filter its requests without Incognito permission. No extension permissions or off-the-record storage rules were changed.

The native Incognito new-tab explanation remains Chromium's normal private landing page; sidebar-created blank tabs still retain the persistent Incognito indicator. The signed development bundle was rebuilt with the existing certificate. Desktop screenshots and the earlier header-drag review remain pending while the Mac is locked.

## Spaces and profiles in one visible window

Spaces now have independent IDs, tab membership, colors, and emoji. The new-space editor assigns a registered profile; multiple spaces can use the same profile and share its sign-ins, history, and extensions. Creating a profile does not open another window. Existing profiles receive an initial space without moving their cookies or databases. Assignment is currently selected when creating a space; reassigning an existing populated space is not implemented.

Spaces sharing a profile use the same native Chromium browser and tab strip. Different profiles keep their own Chromium hosts inside a logical Bark window, with one visible host at the same position. Explicitly opened additional windows retain independent groups. Tab extra data persists membership and logical-window grouping through session restore. Bark defaults to restoring the last session while preserving explicit startup preferences and policy.

The complete build, GN dependency checks, 25 tooling tests, 26 Swift bridge checks, and 24 browser/extension checks pass. Seven native integration checks also pass with `node tools/test_chromium_spaces.mjs`: same-profile tabs and shared storage/extensions, separate-profile isolation, repeated switching, pins/themes/emoji, normal restart with the last active space and one visible window, independent additional windows, beforeunload confirmation visibility/cancellation, and group shutdown. Report: `test-results/chromium-spaces/run-D13DiA/report.json`. The tests use disposable profiles, loopback pages, a private debugging pipe, and mock key storage.

The signed staged bundle matches the built executable/framework UUIDs and passes deep strict signature verification with the existing Apple Development identity. Native review of the staged bundle confirmed creating a themed space, creating a profile without opening a window, choosing that profile in the new-space picker, and opening the assigned space. The header drag moved the window from (171, 82) to (271, 153) points without resizing, and a cross-profile switch retained that exact position with one visible host, including the portion beyond the screen edge. This completes the earlier pending header-drag check. Native report: `test-results/chromium-ui/space-profile-report.json`.

## Remaining migration work

The interface remains experimental. Spaces now share a profile or select another assigned profile inside one visible logical window; Chromium still uses a separate native host for each profile. Full parity with the existing preview still includes folders and Arc import, remaining keyboard shortcuts, fullscreen sidebar integration, remaining profile-page branding. Default native new tabs now load an empty document. Guest windows and fullscreen still use Chromium's native controls; Incognito now uses the Swift sidebar.

This validation covers macOS and a representative Manifest V3 extension, not every Chrome extension or Linux/Windows builds. Tests used disposable profiles and mock keychain storage. A stable Apple Development identity is now used for the staged bundle. Release signing, notarization, real encrypted-storage restart checks, and migration from `BarkNative` remain required before distributing the Chromium app. The retired preview's source and build tooling have been removed from this repository.
