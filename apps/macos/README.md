# macOS interface

Chromium provides the application entry point, native windows, tabs, profiles, and extension services. `src/chromium/` contains Bark's Swift sidebar and Objective-C++ bridge. Build it with [`tools/chromium.py`](../../tools/chromium.py) and enable the interface with `--bark-swift-ui`.

[`overlay-sources.json`](../../engine/chromium/overlay-sources.json) lists the application and shared-core files compiled into the Chromium build. `src/SidebarBackground.swift` and `src/SpaceEditor.swift` provide the shared native sidebar appearance and space editor.

The engine-independent `src/ArcImportReader.swift` remains available for the remaining import work. Portable import, folder, and browser-state models remain in `packages/core`. The older `src/SidebarHoverSensor.swift` is not compiled into Chromium: its header host observes window-edge movement directly, so hovering also works while Chromium owns mouse events.

`resources/icon.png` is Bark's app artwork. Chromium's bundle metadata and helper configuration come from its own build system.

See the [build instructions](../../engine/chromium/README.md) and [validation record](../../docs/chromium-validation.md) for current support and release requirements.
