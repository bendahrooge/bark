import AppKit
import Foundation
import BarkCore
import SwiftUI

private final class Commands {
    var messages: [[String: Any]] = []
}

@main struct ChromiumSidebarTests {
    @MainActor static func main() throws {
        checkPeekShortcuts()
        try checkBarkImportReader()
        _ = NSApplication.shared
        checkPeekPromotion()
        checkSidebarGradient()
        try checkFeedback()
        try checkPreferences()
        let commands = Commands()
        let context = Unmanaged.passUnretained(commands).toOpaque()
        let callback: ChromiumCommand = { pointer, text in
            guard let pointer, let text,
                  let data = String(cString: text).data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            Unmanaged<Commands>.fromOpaque(pointer).takeUnretainedValue().messages.append(message)
        }
        checkSpacePager(callback: callback)
        let model = ChromiumSidebarModel(context: context, callback: callback)
        try checkSidebarPlaceholders(model, commands: commands)
        let frameGeometry = PageFrameGeometry()
        frameGeometry.update(#"{"bounds":{"x":260,"y":0,"width":740,"height":700},"panes":[{"x":267,"y":7,"width":355,"height":686},{"x":634,"y":7,"width":359,"height":686}]}"#)
        precondition(frameGeometry.state?.contentBounds == CGRect(x: 267, y: 7, width: 726, height: 686),
                     "Split drop bounds include both real panes and their divider, excluding the reserved page frame")
        let frameState = frameGeometry.state
        frameGeometry.update("malformed")
        precondition(frameGeometry.state == frameState, "Invalid geometry cannot hide or cover the current page")
        let frameHost = PageFrameHostingView(model: model)
        frameHost.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        precondition(!frameHost.isOpaque && frameHost.hitTest(NSPoint(x: 500, y: 350)) == nil &&
                     frameHost.hitTest(NSPoint(x: 999, y: 350)) == nil,
                     "The frame must be transparent and pass page, scrollbar and divider input through")
        let backdrop = SidebarBackdropHostingView(model: model)
        backdrop.frame = CGRect(x: 0, y: 0, width: 260, height: 700)
        precondition(!backdrop.isOpaque && backdrop.hitTest(NSPoint(x: 20, y: 20)) == nil &&
                     backdrop.hitTest(NSPoint(x: 220, y: 350)) == nil && backdrop.safeAreaRect == backdrop.bounds,
                     "The continuous backdrop covers the caption row without intercepting traffic lights or sidebar input")
        let first = #"{"tabs":[{"id":41,"title":"Page A","url":"https://example.test/a","active":true,"pinned":true,"loading":false}],"spaces":[],"profile":"/temporary/bark-bridge-test","canGoBack":false,"canGoForward":false}"#
        model.update(first)
        precondition(model.snapshot.tabs.first?.id == 41 && model.address == "https://example.test/a")
        precondition(model.addressSummary == "example.test", "The resting address displays the origin")
        try checkOrganization()
        try checkCommandBar()
        try checkAddressBarIcons(model, snapshot: first)
        checkSiteControls(model, snapshot: first, commands: commands)
        model.address = "https://www.example.test:8443/path?q=1"
        precondition(model.addressSummary == "example.test:8443", "Nondefault ports remain visible")
        model.editingAddress = true
        model.address = "my unfinished query"
        model.update(first.replacingOccurrences(of: "Page A", with: "Updated title"))
        precondition(model.address == "my unfinished query", "A page title event must not erase an in-progress address")
        model.update(first.replacingOccurrences(of: "41", with: "99"))
        precondition(model.address == "https://example.test/a", "Changing the active tab must update the address")
        model.update("{malformed}")
        precondition(model.snapshot.tabs.first?.id == 99, "Malformed snapshots must not clear real tabs")
        model.send("close", id: 99)
        precondition(commands.messages.last?["id"] as? Int == 99)
        precondition(commands.messages.last?["action"] as? String == "close")
        model.send("navigate", text: "https://example.test/\"a\"?q=🍃")
        precondition(commands.messages.last?["text"] as? String == "https://example.test/\"a\"?q=🍃", "C ABI JSON must preserve Unicode and quoting")
        model.update(first.replacingOccurrences(of: "https://example.test/a", with: "about:blank"))
        model.address = "an abandoned search"
        model.cancelAddressEditing()
        precondition(model.address.isEmpty && !model.editingAddress, "Escape on a blank tab must restore an empty address")
        model.update(first.replacingOccurrences(of: "https://example.test/a", with: "chrome://newtab/"))
        precondition(model.address.isEmpty && model.snapshot.tabs.first?.isBlank == true,
                     "Native new-tab URLs must also display as a blank Bark tab")
        let collapsed = first.dropLast() + #","sidebarCollapsed":true,"sidebarRevealed":false,"sidebarWidth":320}"#
        model.update(String(collapsed))
        precondition(model.snapshot.sidebarCollapsed == true && model.snapshot.sidebarWidth == 320)
        model.update(first)
        precondition(model.snapshot.sidebarCollapsed == nil, "Older snapshots remain compatible")
        precondition(!model.isIncognito, "Older snapshots default to ordinary browsing")
        let privateSnapshot = first.dropLast() + #","incognito":true}"#
        // Incognito and its parent can share a profile path. Switching mode
        // must still reset the projection without writing parent preferences.
        model.update(String(privateSnapshot))
        precondition(model.isIncognito && model.activeSpaceName == "Incognito" && model.emoji.isEmpty)
        let themeBefore = model.theme
        model.customize(theme: .ocean, emoji: "🚀")
        precondition(model.theme == themeBefore && model.emoji.isEmpty,
                     "Private-window customization must not mutate a persistent space")
        let privateCommandCount = commands.messages.count
        for action in ["space", "createSpace", "deleteSpace", "manageSpaces", "moveTabToSpace", "createProfile", "deleteProfile", "customizeSpace", "appearance", "importBrowserData"] { model.send(action, text: "private test") }
        precondition(commands.messages.count == privateCommandCount,
                     "Private windows cannot send commands that edit or open persistent spaces")
        model.send("new")
        precondition(commands.messages.last?["action"] as? String == "new",
                     "Private tab commands still reach the real Chromium tab strip")
        model.update(first)
        precondition(!model.isIncognito && model.activeSpaceName == "Personal",
                     "Returning to a regular snapshot restores ordinary space presentation")
        let spaces = #"{"tabs":[],"spaces":[{"id":"research","name":"Research","active":true,"profile":"Default","theme":"ocean","emoji":"🔬"},{"id":"reading","name":"Reading","active":false,"profile":"Default","theme":"lavender","emoji":"📚"}],"profiles":[{"id":"Default","name":"Personal"}],"profile":"/temporary/bark-bridge-test","profileId":"Default","activeSpaceId":"research","canGoBack":false,"canGoForward":false}"#
        model.update(spaces)
        precondition(model.activeSpaceName == "Research" && model.activeProfileName == "Personal",
                     "Spaces have their own names and IDs independent of their shared profile")
        precondition(model.theme == .ocean && model.emoji == "🔬" && model.emoji(for: model.snapshot.spaces[1]) == "📚",
                     "Space appearance comes from catalog metadata, including inactive dock items")
        model.update(spaces.replacingOccurrences(of: #""active":true"#, with: #""active":TEMP"#)
            .replacingOccurrences(of: #""active":false"#, with: #""active":true"#)
            .replacingOccurrences(of: #""active":TEMP"#, with: #""active":false"#)
            .replacingOccurrences(of: #""activeSpaceId":"research""#, with: #""activeSpaceId":"reading""#))
        precondition(model.theme == .lavender && model.emoji == "📚" && model.activeProfileName == "Personal",
                     "Switching spaces in one profile updates its theme and emoji")
        model.update(spaces.replacingOccurrences(of: #""emoji":"🔬""#, with: #""emoji":"""#))
        precondition(model.emoji.isEmpty && model.emoji(for: model.snapshot.spaces[0]).isEmpty,
                     "A space without a chosen icon has an empty icon, which is drawn as a dot")
        model.saveSpaceSettings(model.snapshot.spaces[0], name: "Research", theme: .ocean, emoji: "", profile: "")
        precondition((commands.messages.last?["metadata"] as? [String: String])?["emoji"] == "",
                     "Saving a space without an icon keeps it unset")
        model.update(spaces.replacingOccurrences(of: #""active":true"#, with: #""active":TEMP"#)
            .replacingOccurrences(of: #""active":false"#, with: #""active":true"#)
            .replacingOccurrences(of: #""active":TEMP"#, with: #""active":false"#)
            .replacingOccurrences(of: #""activeSpaceId":"research""#, with: #""activeSpaceId":"reading""#))
        model.customize(theme: .gray, emoji: "🌿")
        precondition(commands.messages.last?["action"] as? String == "customizeSpace" &&
                     (commands.messages.last?["metadata"] as? [String: String])?["emoji"] == "🌿",
                     "Catalog customization goes through the native bridge instead of profile preferences")
        let featureSnapshot = #"{"tabs":[{"id":7,"title":"Inbox","url":"https://mail.test/u/1","active":true,"pinned":true,"loading":false,"customTitle":"Mail","pinnedURL":"https://mail.test/","drifted":true,"folder":"f1"},{"id":8,"title":"","url":"about:blank","active":false,"pinned":false,"loading":false}],"spaces":[{"id":"s","name":"Work","active":true,"theme":"ocean","emoji":"","gradient":"rose","grain":0.4,"folders":[{"id":"f1","name":"Projects","collapsed":true}]}],"profile":"/temporary/bark-features","activeSpaceId":"s","canGoBack":false,"canGoForward":false,"media":{"id":9,"title":"Song page","url":"https://www.music.test/x","playing":true,"mediaTitle":"Song","artist":"Band"},"features":{"archiveAfterHours":24,"peek":true,"littleWindow":false,"autoPictureInPicture":true}}"#
        model.update(featureSnapshot)
        var pin = model.snapshot.tabs[0]
        model.close(pin)
        precondition(pin.closeLabel == "Close pinned tab session" && commands.messages.last?["action"] as? String == "closePinnedSession")
        pin.sessionClosed = true
        model.close(pin)
        precondition(pin.closeLabel == "Remove pinned tab" && commands.messages.last?["action"] as? String == "removeClosedPin" &&
                     commands.messages.last?["id"] as? Int == pin.id)
        model.close(model.snapshot.tabs[1])
        precondition(commands.messages.last?["action"] as? String == "close")
        precondition(model.snapshot.tabs[0].displayTitle == "Mail" && model.snapshot.tabs[1].isSidebarPlaceholder &&
                     model.snapshot.tabs[0].drifted == true && model.folders.map(\.name) == ["Projects"] &&
                     model.folders[0].collapsed == true, "Custom titles, drifted pins and folders decode")
        precondition(model.activeSpace?.style == SpaceStyle(gradient: .rose) &&
                     model.activeSpace?.style.metadata == ["gradient": "rose", "grain": "0", "gradientCanvas": ""],
                     "Older textured spaces keep their gradient and clear obsolete grain on save")
        let canvas = SpaceGradientCanvas(startColor: "#7C68A6", endColor: "#AB607D",
                                         start: SpaceColorPoint(x: 0.17, y: 0.19), end: SpaceColorPoint(x: 0.64, y: 0.62))
        let canvasStyle = SpaceStyle(gradient: .rose, canvas: canvas)
        let canvasMetadata = canvasStyle.metadata
        let decodedCanvas = try JSONDecoder().decode(SpaceGradientCanvas.self, from: Data(canvasMetadata["gradientCanvas"]!.utf8))
        precondition(decodedCanvas == canvas, "Both custom colors and normalized points survive bridge serialization")
        model.update(featureSnapshot.replacingOccurrences(of: #""grain":0.4"#, with: #""grain":0.4,"gradientCanvas":"# + canvas.json!))
        precondition(model.activeSpace?.style == canvasStyle, "The sidebar reads custom colors from older textured spaces")
        model.customize(model.activeSpace!, emoji: "🎨")
        precondition((commands.messages.last?["metadata"] as? [String: String])?["gradientCanvas"] == nil,
                     "Changing an icon preserves the exact custom colors")
        model.customize(model.activeSpace!, theme: .mint)
        let recolored = (commands.messages.last?["metadata"] as? [String: String])!["gradientCanvas"]!
        let recoloredCanvas = try JSONDecoder().decode(SpaceGradientCanvas.self, from: Data(recolored.utf8))
        precondition(recoloredCanvas.startColor == SpaceTheme.mint.accentHex && recoloredCanvas.endColor == canvas.endColor &&
                     recoloredCanvas.start == canvas.start && recoloredCanvas.end == canvas.end,
                     "Named-color commands preserve the other custom color and the canvas layout")
        for preset in SpaceThemePreset.allCases {
            let metadata = preset.style.metadata
            let restored = try JSONDecoder().decode(SpaceGradientCanvas.self, from: Data(metadata["gradientCanvas"]!.utf8))
            precondition(SpaceThemePreset.matching(SpaceStyle(canvas: restored)) == preset,
                         "Named presets remain selected after saving and decoding their appearance")
            var customized = preset.style
            customized.canvas!.startColor = "#010203"
            precondition(SpaceThemePreset.matching(customized) == nil, "Editing a preset's colors clears its selection")
        }
        let originalPresets: [(SpaceThemePreset, String, String)] = [
            (.ocean, "#477E9B", "#3D8270"), (.sunset, "#AB607D", "#BD8A48"),
            (.forest, "#58764E", "#3D8270"), (.midnight, "#454B79", "#7C68A6")
        ]
        for (preset, start, end) in originalPresets {
            let saved = SpaceStyle(canvas: SpaceGradientCanvas(startColor: start, endColor: end))
            precondition(SpaceThemePreset.matching(saved) == preset && saved.themeCanvas == preset.canvas,
                         "Previously saved presets retain their identity and receive the updated palette")
            var custom = saved
            custom.canvas!.start.x = 0.1
            precondition(custom.themeCanvas == custom.canvas,
                         "A customized gradient must not be replaced by the new preset palette")
        }
        precondition(SpaceThemePreset.matching(canvasStyle) == nil &&
                     SpaceThemePreset.matching(SpaceStyle(gradient: .rose)) == nil,
                     "Existing custom canvases and legacy gradients are preserved without mislabeling them as presets")
        precondition(!SpaceGradientCanvas(startColor: "invalid", endColor: "#AB607D").isValid &&
                     SpaceGradientCanvas.hex(SpaceGradientCanvas.color("#7C68A6")) == "#7C68A6",
                     "Custom color validation and sRGB conversion keep exact color values")
        precondition(model.snapshot.media?.heading == "Song" && model.snapshot.media?.detail == "Band" &&
                     model.snapshot.features?.archiveAfterHours == 24 && model.snapshot.features?.littleWindow == false,
                     "Media and Library switches decode")
        model.updateSwitcher(#"{"tabs":[]}"#)  // Ignored while no switcher is open.
        precondition(!RecentTabSwitcher.shared.active, "A switcher list arriving late does not open the switcher")
        model.update(spaces.replacingOccurrences(of: #""active":true"#, with: #""active":TEMP"#)
            .replacingOccurrences(of: #""active":false"#, with: #""active":true"#)
            .replacingOccurrences(of: #""active":TEMP"#, with: #""active":false"#)
            .replacingOccurrences(of: #""activeSpaceId":"research""#, with: #""activeSpaceId":"reading""#))
        precondition(model.canDelete(model.snapshot.spaces[0]) && model.moveTargets.map(\.id) == ["research"],
                     "A profile with two spaces can delete one and move tabs to the other")
        model.update(#"{"tabs":[{"id":7,"title":"Song","url":"https://example.test/song","active":true,"pinned":false,"loading":true,"audible":true,"muted":false}],"spaces":[{"id":"research","name":"Research","active":true,"profile":"Default"}],"profiles":[{"id":"Default","name":"Personal"}],"profile":"/temporary/bark-bridge-test","profileId":"Default","activeSpaceId":"research","canGoBack":false,"canGoForward":false}"#)
        precondition(model.snapshot.tabs[0].audible == true && model.snapshot.tabs[0].muted == false && model.activeTabLoading,
                     "Audio and loading state reach the tab row and the Stop control")
        precondition(!model.canDelete(model.snapshot.spaces[0]) && model.moveTargets.isEmpty,
                     "A profile's last space cannot be deleted")
        model.update(#"{"tabs":[{"id":1,"title":"Pinned","url":"https://example.test/p","active":false,"pinned":true,"loading":false},{"id":2,"title":"A","url":"https://example.test/a","active":true,"pinned":false,"loading":false,"split":"s1","splitActive":true},{"id":3,"title":"B","url":"https://example.test/b","active":false,"pinned":false,"loading":false,"split":"s1","splitActive":true}],"favorites":[{"id":9,"title":"Favorite","url":"https://example.test/f","active":false,"pinned":true,"loading":false}],"spaces":[{"id":"research","name":"Research","active":true,"profile":"Default"},{"id":"home","name":"Home","active":false,"profile":"Default"}],"profiles":[{"id":"Default","name":"Personal"}],"profile":"/temporary/bark-bridge-test","profileId":"Default","activeSpaceId":"research","canGoBack":false,"canGoForward":false}"#)
        precondition(model.snapshot.tabs[1].split == "s1" && model.snapshot.tabs[2].splitActive == true && model.snapshot.tabs[0].split == nil,
                     "Split view membership reaches the tab rows")
        func shortcut(_ characters: String?, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> BarkShortcut.Action? {
            BarkShortcut.match(characters: characters, keyCode: code, modifiers: modifiers)?.action
        }
        precondition(shortcut("s", 1, .command) == .toggleSidebar && shortcut("C", 8, [.command, .shift]) == .copyURL &&
                     shortcut("C", 8, [.command, .shift, .option]) == .copyMarkdown && shortcut("3", 20, .control) == .space(3) &&
                     shortcut(nil, 124, [.command, .option, .numericPad, .function]) == .nextSpace && shortcut("+", 24, [.control, .shift]) == .addSplit,
                     "Bark shortcuts match by character or key code, ignoring unrelated modifier flags")
        precondition(shortcut("s", 1, [.command, .shift]) == nil && shortcut("c", 8, .command) == nil && shortcut("t", 17, .command) == nil,
                     "Other key combinations are left to Chromium")
        model.perform(.nextTab)
        precondition(commands.messages.last?["action"] as? String == "select" && commands.messages.last?["id"] as? Int == 3,
                     "Next tab follows the sidebar's order")
        model.perform(.tab(1))
        precondition(commands.messages.last?["id"] as? Int == 9, "Tab numbers count from Favorites at the top of the sidebar")
        model.perform(.nextSpace)
        precondition(commands.messages.last?["action"] as? String == "space" && commands.messages.last?["text"] as? String == "home")
        let beforeEdge = commands.messages.count
        model.perform(.previousSpace)
        model.perform(.space(1))
        precondition(commands.messages.count == beforeEdge, "Space shortcuts do nothing at the first space or for the current one")
        model.perform(.closeSplit)
        precondition(commands.messages.last?["action"] as? String == "unsplit")
        let windowFrame = NSRect(x: 100, y: 100, width: 1000, height: 700)
        for point in [NSPoint(x: 99, y: 400), NSPoint(x: 1101, y: 400),
                      NSPoint(x: 600, y: 99), NSPoint(x: 600, y: 801)] {
            precondition(SplitDropController.isOutsideWindow(point, window: windowFrame),
                         "Dragging beyond any window edge creates a new window")
        }
        for point in [NSPoint(x: 101, y: 400), NSPoint(x: 1099, y: 400),
                      NSPoint(x: 600, y: 101), NSPoint(x: 600, y: 799)] {
            precondition(!SplitDropController.isOutsideWindow(point, window: windowFrame),
                         "Sidebar, page and titlebar drops inside the window must not detach")
        }
        precondition(!SplitDropController.isOutsideWindow(NSPoint(x: -500, y: -200),
            window: NSRect(x: -1000, y: -500, width: 1000, height: 700)),
            "A window on a display with a negative origin uses the same drop geometry")
        let sidebarFrame = NSRect(x: 100, y: 100, width: 260, height: 662)
        let page = SplitDropController.pageRect(window: windowFrame, sidebar: sidebarFrame, floating: false)
        precondition(page == NSRect(x: 360, y: 100, width: 740, height: 662) &&
                     SplitDropController.side(at: NSPoint(x: 400, y: 300), page: page, sidebar: sidebarFrame) == .left &&
                     SplitDropController.side(at: NSPoint(x: 900, y: 300), page: page, sidebar: sidebarFrame) == .right &&
                     SplitDropController.side(at: NSPoint(x: 200, y: 300), page: page, sidebar: sidebarFrame) == nil,
                     "A tab dragged onto the page splits on the half under the pointer; the sidebar is not a drop target")
        let floatingPage = SplitDropController.pageRect(window: windowFrame, sidebar: sidebarFrame, floating: true)
        precondition(floatingPage.minX == 100 && SplitDropController.side(at: NSPoint(x: 200, y: 300), page: floatingPage, sidebar: sidebarFrame) == nil &&
                     SplitDropController.side(at: NSPoint(x: 400, y: 300), page: floatingPage, sidebar: sidebarFrame) == .left,
                     "A floating sidebar covers part of the page without becoming a drop target")
        precondition(SplitDropController.side(at: NSPoint(x: 730, y: 720), page: page, sidebar: sidebarFrame) == .top &&
                     SplitDropController.side(at: NSPoint(x: 730, y: 140), page: page, sidebar: sidebarFrame) == .bottom &&
                     SplitDropController.side(at: NSPoint(x: 600, y: 720), page: floatingPage, sidebar: sidebarFrame) == .top &&
                     SplitDropController.side(at: NSPoint(x: 600, y: 140), page: floatingPage, sidebar: sidebarFrame) == .bottom,
                     "Top and bottom drop targets work with docked and floating sidebars")
        precondition(SplitDropController.halfRect(for: .top, page: page) == NSRect(x: 360, y: 431, width: 740, height: 331) &&
                     SplitDropController.halfRect(for: .bottom, page: page) == NSRect(x: 360, y: 100, width: 740, height: 331) &&
                     SplitDropController.halfRect(for: .left, page: page) == NSRect(x: 360, y: 100, width: 370, height: 662) &&
                     SplitDropController.halfRect(for: .right, page: page) == NSRect(x: 730, y: 100, width: 370, height: 662),
                     "Each preview covers the destination half, with AppKit's top above its bottom")
        for size in [NSSize(width: 1600, height: 400), NSSize(width: 400, height: 1600)] {
            let frame = NSRect(origin: NSPoint(x: -100, y: -200), size: size)
            precondition(SplitDropController.side(at: NSPoint(x: frame.midX, y: frame.maxY - 20), page: frame, sidebar: .zero) == .top &&
                         SplitDropController.side(at: NSPoint(x: frame.midX, y: frame.minY + 20), page: frame, sidebar: .zero) == .bottom &&
                         SplitDropController.side(at: NSPoint(x: frame.minX + 20, y: frame.midY), page: frame, sidebar: .zero) == .left &&
                         SplitDropController.side(at: NSPoint(x: frame.maxX - 20, y: frame.midY), page: frame, sidebar: .zero) == .right,
                         "All four targets remain reachable in wide and tall windows and on offset screens")
        }
        precondition(SplitDropController.side(at: NSPoint(x: 730, y: 780), page: page, sidebar: sidebarFrame) == nil &&
                     SplitDropController.side(at: NSPoint(x: 730, y: 90), page: page, sidebar: sidebarFrame) == nil,
                     "The title bar and area outside the window never create a split")
        model.shutdown()
        let count = commands.messages.count
        model.send("new")
        precondition(commands.messages.count == count, "A detached sidebar must never call its destroyed C++ controller")
        let handle = barkSwiftSidebarCreate(context, callback)
        first.withCString { barkSwiftSidebarUpdate(handle, $0) }
        precondition(Unmanaged<AnyObject>.fromOpaque(handle).takeUnretainedValue() is NSView)
        checkNewTabButton(handle, commands: commands)
        let header = barkSwiftSidebarHeaderCreate(handle)
        checkHeaderHoverExit(Unmanaged<NSView>.fromOpaque(header).takeUnretainedValue())
        barkSwiftSidebarHeaderDestroy(header)
        checkSpaceDockScrolling(handle, commands: commands)
        let resize = barkSwiftSidebarResizeCreate(handle)
        let resizeView = Unmanaged<NSView>.fromOpaque(resize).takeUnretainedValue()
        precondition(!resizeView.isOpaque, "The boundary resize target must not paint over the page or sidebar")
        barkSwiftSidebarResizeDestroy(resize)
        barkSwiftSidebarDestroy(handle)
        print("Swift/Chromium bridge checks passed, including four-way split drop targets")
    }
}

@MainActor private func checkNewTabButton(_ handle: UnsafeMutableRawPointer, commands: Commands) {
    let host = Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 480),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    let key = "accessibilityEnhancedUserInterface"
    let previous = NSApp.value(forKey: key)
    NSApp.setValue(true, forKey: key)
    defer { NSApp.setValue(previous, forKey: key) }

    for tabs in ["[]", #"[{"id":1,"title":"Example","url":"https://example.test/","active":true,"pinned":false,"loading":false}]"#] {
        let state = #"{"tabs":\#(tabs),"spaces":[],"profile":"Default","canGoBack":false,"canGoForward":false}"#
        state.withCString { barkSwiftSidebarUpdate(handle, $0) }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var nodes = host.accessibilityChildren() ?? []
        var buttons: [AnyObject] = []
        while let item = nodes.popLast() {
            let node = item as AnyObject
            if node.accessibilityRole?() == .button && node.accessibilityLabel?() == "New tab" { buttons.append(node) }
            nodes += node.accessibilityChildren?() ?? []
        }
        precondition(buttons.count == 1, "The tab list must show a New tab button even when it is empty")
        let count = commands.messages.count
        precondition(buttons[0].accessibilityPerformPress?() == true)
        precondition(commands.messages.count == count + 1 && commands.messages.last?["action"] as? String == "new",
                     "Pressing the sidebar button must dispatch the native New Tab command once")
    }
}

@MainActor private func checkSidebarGradient() {
    let window = CGSize(width: 480, height: 240)
    let canvas = SpaceGradientCanvas(startColor: "#F92435", endColor: "#185ADF",
                                     start: .init(x: 0.03, y: 0.15), end: .init(x: 0.75, y: 0.65))
    func render(width: CGFloat, canvasSize: CGSize?) -> NSBitmapImageRep {
        let backdrop = SidebarBackground(theme: .gray, style: SpaceStyle(canvas: canvas), canvasSize: canvasSize)
            .frame(width: width, height: window.height)
            .environment(\.colorScheme, .light)
            .environment(\._accessibilityReduceTransparency, true)
        return NSBitmapImageRep(cgImage: ImageRenderer(content: backdrop).cgImage!)
    }
    let docked = render(width: window.width, canvasSize: nil)
    let floating = render(width: 160, canvasSize: window)
    func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    precondition(abs(color(docked, 12, 120).redComponent - color(docked, 145, 120).redComponent) > 0.05,
                 "The sampled sidebar region includes distinct gradient colors")
    for (x, y) in [(12, 44), (90, 120), (145, 198)] {
        let a = color(docked, x, y), b = color(floating, x, y)
        precondition(max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                         abs(a.blueComponent - b.blueComponent)) < 0.01,
                     "The revealed sidebar must show the same gradient colors as the attached sidebar")
    }
}

@MainActor private func checkSidebarPlaceholders(_ model: ChromiumSidebarModel, commands: Commands) throws {
    func tab(_ id: Int, _ url: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["id": id, "url": url, "title": "", "pinned": false, "active": false, "loading": false]
        row.merge(fields) { _, value in value }
        return row
    }
    let rows = [
        tab(1, "about:blank", ["active": true]),
        tab(2, ""),
        tab(3, "about:blank#fragment"),
        tab(4, "chrome://newtab/?source=test"),
        tab(5, "https://pending.test/", ["blankPlaceholder": true, "loading": true]),
        tab(6, "https://restored.test/path", ["blankPlaceholder": false]),
        tab(7, "about:blank", ["pinned": true, "customTitle": "Saved pin"]),
        tab(8, "about:blank", ["split": "pair"]),
        tab(9, "about:blank", ["blankPlaceholder": false])
    ]
    let state: [String: Any] = [
        "tabs": rows, "spaces": [["id": "a", "name": "A", "active": true], ["id": "b", "name": "B", "active": false]],
        "profile": "Default", "activeSpaceId": "a", "canGoBack": false, "canGoForward": false, "spacePreviews": ["b": rows]
    ]
    model.update(String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
    let shown = [6, 7, 8, 9]
    precondition(model.activeTab?.id == 1 && model.snapshot.tabs.count == rows.count)
    precondition(model.snapshot.sidebarTabs.map(\.id) == shown && model.outgoingTabs.map(\.id) == shown &&
                 model.previewTabs(for: model.snapshot.spaces[1]).map(\.id) == shown,
                 "Current and neighboring Spaces hide empty, native NTP and pending placeholders while retaining pins and splits")
    precondition(model.outgoingTabs[0].displayTitle == "restored.test" && model.outgoingTabs[1].displayTitle == "Saved pin",
                 "A lazy untitled page displays its host and a customized pin retains its title")
    model.perform(.tab(2))
    precondition(commands.messages.last?["action"] as? String == "select" && commands.messages.last?["id"] as? Int == 6,
                 "Numbered tab shortcuts count visible rows after pins")
}

private final class DockWheelEvent: NSEvent {
    weak var target: NSWindow?
    var point = CGPoint.zero
    var delta = CGSize.zero
    var gesturePhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    override var type: EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { target?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { point }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var hasPreciseScrollingDeltas: Bool { !phase.isEmpty || !momentum.isEmpty }
    override var scrollingDeltaX: CGFloat { delta.width }
    override var scrollingDeltaY: CGFloat { delta.height }
    override var isDirectionInvertedFromDevice: Bool { true }
}

@MainActor private func waitForPager(_ message: String, until ready: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 1)
    while !ready() && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    precondition(ready(), message)
}

@MainActor private func checkSpaceDockScrolling(_ handle: UnsafeMutableRawPointer, commands: Commands) {
    let host = Unmanaged<NSView>.fromOpaque(handle).takeUnretainedValue()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 480),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    func show(_ active: Int) {
        let spaces = (0..<20).map { #"{"id":"\#($0)","name":"Space \#($0)","active":\#($0 == active)}"# }.joined(separator: ",")
        let state = #"{"tabs":[],"spaces":[\#(spaces)],"activeSpaceId":"\#(active)","profile":"Default","canGoBack":false,"canGoForward":false}"#
        state.withCString { barkSwiftSidebarUpdate(handle, $0) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    show(0)
    var views = [host]
    var dockView: NSScrollView?
    while let view = views.popLast() {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView, doc.frame.width > scroll.contentSize.width {
            dockView = scroll
            break
        }
        views += view.subviews
    }
    guard let dock = dockView else { preconditionFailure("Twenty Space icons must overflow the dock") }
    let point = dock.convert(NSPoint(x: dock.bounds.midX, y: dock.bounds.midY), to: nil)
    let tabList = CGPoint(x: point.x, y: point.y + 120)
    func scroll(_ x: CGFloat, _ y: CGFloat, at location: CGPoint, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
        let event = DockWheelEvent()
        event.target = window
        event.point = location
        event.delta = CGSize(width: x, height: y)
        event.gesturePhase = phase
        event.momentum = momentum
        NSApp.sendEvent(event)
    }
    func offset() -> CGFloat { dock.contentView.bounds.minX }
    let end = dock.documentView!.frame.width - dock.contentSize.width
    let commandCount = commands.messages.count
    scroll(0, -1, at: point)
    precondition(offset() > 0, "A vertical mouse-wheel tick scrolls the Space icons")
    scroll(0, 1000, at: point)
    precondition(offset() == 0)
    scroll(-24, 0, at: point, phase: .began)
    scroll(-24, 0, at: tabList, phase: .changed)
    scroll(0, 0, at: tabList, phase: .ended)
    precondition(offset() == 48, "A trackpad gesture stays with the dock when the pointer leaves it")
    scroll(-1000, 0, at: tabList, momentum: .began)
    scroll(0, 0, at: tabList, momentum: .ended)
    precondition(offset() == end && commands.messages.count == commandCount,
                 "Scrolling can reveal the last Space without switching Spaces")
    precondition(!dock.hasHorizontalScroller || dock.horizontalScroller?.isHidden == true)
    show(1)
    precondition(offset() < end, "An externally selected Space scrolls into view")
    show(19)
    precondition(offset() == end)
    let beforeSwipes = commands.messages.count
    func swipe(_ dx: CGFloat) {
        scroll(dx, 0, at: tabList, phase: .began)
        scroll(0, 0, at: tabList, phase: .ended)
    }
    func expectSwitches(_ expected: [String]) {
        func destinations() -> [String] {
            commands.messages.dropFirst(beforeSwipes).filter { $0["action"] as? String == "space" }
                .compactMap { $0["text"] as? String }
        }
        waitForPager("Each swipe above the dock switches one Space in the finger's direction") {
            destinations() == expected
        }
    }
    swipe(125)
    expectSwitches(["18"])
    show(18)
    scroll(160, 0, at: tabList, momentum: .began)
    scroll(0, 0, at: tabList, momentum: .ended)
    swipe(125)
    expectSwitches(["18", "17"])
    show(17)
    swipe(-125)
    expectSwitches(["18", "17", "18"])
}

@MainActor private func checkSpacePager(callback: ChromiumCommand) {
    let commands = Commands()
    var reduceMotion = false
    let model = ChromiumSidebarModel(context: Unmanaged.passUnretained(commands).toOpaque(),
                                    callback: callback, reduceSpaceMotion: { reduceMotion })
    defer { model.shutdown() }

    func show(_ active: String, visible: Bool = true, otherProfile: String? = nil) {
        let spaces = ["a", "b", "c"].map { id in
            let profile = id == otherProfile ? "Work" : "Default"
            return #"{"id":"\#(id)","name":"\#(id)","active":\#(id == active),"profile":"\#(profile)"}"#
        }.joined(separator: ",")
        model.update(#"""
        {"spaces":[\#(spaces)],"activeSpaceId":"\#(active)","profile":"Default","profileId":"Default",
         "tabs":[{"id":1,"title":"\#(active) tab","url":"https://test.invalid/\#(active)","active":true,"pinned":false,"loading":false},
                 {"id":2,"title":"New Tab","url":"about:blank","active":false,"pinned":false,"loading":false}],
         "canGoBack":false,"canGoForward":false,"windowVisible":\#(visible),"sidebarWidth":260}
        """#)
    }
    func selections() -> [String] {
        commands.messages.filter { $0["action"] as? String == "space" }.compactMap { $0["text"] as? String }
    }
    show("a")
    let spaces = model.snapshot.spaces
    model.requestSpaceSelection(spaces[0])
    precondition(selections().isEmpty && !model.spaceInMotion, "Clicking the selected Space leaves the pager idle")
    model.requestSpaceSelection(spaces[2])
    precondition(selections() == ["c"] && model.swipeDirection == -1 && model.swipeNeighbor?.id == "c",
                 "A nonadjacent dock click immediately selects the requested Space and slides toward it")
    show("c")
    precondition(model.outgoingSpace?.id == "a" && model.outgoingTabs.map(\.title) == ["a tab"] &&
                 model.previewTabs(for: spaces[2]).map(\.title) == ["c tab"],
                 "An early native snapshot updates the incoming rows while the outgoing rows keep sliding")
    model.requestSpaceSelection(spaces[1])
    model.requestSpaceSelection(spaces[0])
    model.finishSpaceSwipe()
    precondition(selections() == ["c", "a"] && model.swipeDirection == 1 && model.outgoingSpace?.id == "c",
                 "The last dock click wins, including a return to the departing Space")
    show("a")
    model.finishSpaceSwipe()
    precondition(!model.spaceInMotion && model.outgoingSpace?.id == "a")

    commands.messages.removeAll()
    model.requestSpaceSelection(spaces[1])
    model.requestSpaceSelection(spaces[2])
    model.requestSpaceSelection(spaces[1])
    show("b")
    model.finishSpaceSwipe()
    precondition(selections() == ["b"] && !model.spaceInMotion, "Reselecting the destination clears an older queued click")
    model.requestSpaceSelection(spaces[0])
    model.requestSpaceSelection(spaces[2])
    show("a", visible: false)
    precondition(selections() == ["b", "a"] && !model.spaceInMotion, "A hidden sidebar discards its queued click")

    commands.messages.removeAll()
    show("a")
    model.beginSpaceSwipe()
    model.updateSpaceSwipe(by: -40, width: 260)
    precondition(model.spaceSwipeOffset == -20)
    model.endSpaceSwipe(velocity: 0, width: 260, cancelled: false)
    precondition(selections().isEmpty && model.spaceInMotion && model.swipeNeighbor?.id == "b" && model.swipeDirection == -1,
                 "A short swipe keeps the incoming page visible as it slides back")
    model.finishSpaceSwipe()
    model.beginSpaceSwipe()
    model.updateSpaceSwipe(by: -100, width: 260)
    precondition(model.spaceSwipeOffset == -50, "The displayed drag distance is half the physical travel")
    model.endSpaceSwipe(velocity: 0, width: 260, cancelled: false)
    precondition(selections() == ["b"], "The physical drag crosses the commit threshold even when the displayed drag does not")
    show("b")
    model.finishSpaceSwipe()

    for hz in [60, 120] {
        var velocity = SpaceSwipeVelocity()
        velocity.begin(at: 0)
        for sample in 1...(hz / 5) {
            velocity.add(-600 / CGFloat(hz), at: Double(sample) / Double(hz))
        }
        precondition(abs(velocity.velocity(at: 0.2) + 600) < 0.01 && velocity.velocity(at: 0.3) == 0,
                     "Flick speed is in points per second at either event rate and drops to zero after a pause")
    }
    reduceMotion = true
    model.requestSpaceSelection(spaces[2])
    precondition(selections() == ["b", "c"] && !model.spaceInMotion, "Reduce Motion selects the destination immediately")

    func swipe(_ dx: CGFloat, cancelled: Bool = false) {
        model.beginSpaceSwipe()
        model.updateSpaceSwipe(by: dx, width: 260)
        model.endSpaceSwipe(velocity: 0, width: 260, cancelled: cancelled)
    }
    show("c")
    commands.messages.removeAll()
    swipe(120)
    swipe(120)
    precondition(selections() == ["b"] && !model.spaceInMotion)
    show("b")
    precondition(selections() == ["b", "a"] && !model.spaceInMotion,
                 "Reduce Motion preserves swipes made before the native selection acknowledgement")
    show("a")

    reduceMotion = false
    commands.messages.removeAll()
    show("a")
    swipe(-120)
    swipe(-120)
    show("b")
    waitForPager("A swipe completed before Chromium acknowledges the first advances from its destination") {
        selections() == ["b", "c"]
    }
    swipe(120, cancelled: true)
    show("c")
    waitForPager("The pager settles after a cancelled follow-up swipe") { !model.spaceInMotion }
    precondition(selections() == ["b", "c"] && model.outgoingSpace?.id == "c",
                 "A cancelled swipe never replays after a delayed snapshot")

    show("b")
    swipe(-20)
    swipe(120)
    waitForPager("A reverse swipe during a short drag's rollback commits from the original Space") {
        selections() == ["b", "c", "a"]
    }
    show("a")
    model.finishSpaceSwipe()

    // The third gesture starts while the first selection still awaits a snapshot
    // and the second swipe is queued. Its direction is relative to the second destination.
    for crossProfile in [false, true] {
        let otherProfile = crossProfile ? "c" : nil
        show("a", otherProfile: otherProfile)
        commands.messages.removeAll()
        swipe(-120)
        swipe(-120)
        model.beginSpaceSwipe()
        model.updateSpaceSwipe(by: 55, width: 260)
        show("b", otherProfile: otherProfile)
        waitForPager("The queued second swipe commits while the third gesture is in progress") {
            selections() == ["b", "c"]
        }
        if crossProfile {
            let track = commands.messages.filter { $0["action"] as? String == "trackSpaceSwipe" }
            precondition(track.count == 1 && (track[0]["metadata"] as? [String: String])?["after"] == "c",
                         "The queued profile switch takes ownership of the third gesture before Hide")
            show("b", visible: false, otherProfile: otherProfile)
        } else {
            show("c")
        }
        model.updateSpaceSwipe(by: 55, width: 260)
        model.endSpaceSwipe(velocity: 0, width: 260, cancelled: false)
        if crossProfile {
            let queued = commands.messages.filter { $0["action"] as? String == "queueSpaceSwipe" }
            precondition(queued.count == 1 && queued[0]["text"] as? String == "b" &&
                         (queued[0]["metadata"] as? [String: String])?["after"] == "c" && selections() == ["b", "c"],
                         "The old host forwards the third swipe with travel from both sides of Hide")
        } else {
            precondition(selections() == ["b", "c", "b"],
                         "The third gesture keeps its travel and reverses from the queued swipe's destination")
            show("b")
            model.finishSpaceSwipe()
        }
    }

    for wasHorizontal in [false, true] {
        show("a", otherProfile: "b")
        commands.messages.removeAll()
        swipe(-120)
        model.beginSpaceSwipe()
        precondition(commands.messages.last?["action"] as? String == "trackSpaceSwipe" &&
                     (commands.messages.last?["metadata"] as? [String: String])?["after"] == "b",
                     "A gesture beginning during a profile switch registers immediately with the old host")
        show("a", visible: false, otherProfile: "b")
        if wasHorizontal {
            model.updateSpaceSwipe(by: -120, width: 260)
            model.endSpaceSwipe(velocity: -900, width: 260, cancelled: true)
        } else {
            model.discardUndecidedSpaceSwipe()
        }
        let queued = commands.messages.filter { $0["action"] as? String == "queueSpaceSwipe" }
        precondition(queued.count == 1 && queued[0]["text"] == nil &&
                     (queued[0]["metadata"] as? [String: String])?["after"] == "b" && selections() == ["b"],
                     "Abandoning a gesture after Hide releases the old host's track without switching Spaces")
    }
}

@MainActor private func checkSiteControls(_ model: ChromiumSidebarModel, snapshot: String, commands: Commands) {
    model.update(snapshot)
    let before = commands.messages.count
    model.setSiteControlsOpen(true)
    model.setSiteControlsOpen(true)
    precondition(commands.messages.count == before + 1 && commands.messages.last?["text"] as? String == "open",
                 "Presenting the popover starts one native snapshot subscription")
    model.performSiteControl("activateExtension", text: "extension-id")
    precondition(!model.siteControlsOpen && commands.messages.last?["text"] as? String == "close",
                 "Dismiss the popover before opening native extension UI")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    precondition(commands.messages.last?["action"] as? String == "activateExtension" &&
                 commands.messages.last?["id"] as? Int == 41 &&
                 (commands.messages.last?["metadata"] as? [String: String])?["url"] == "https://example.test/a",
                 "Extension actions carry the page and tab described by the popover")
    for changed in [snapshot.replacingOccurrences(of: "41", with: "99"),
                    snapshot.replacingOccurrences(of: "example.test/a", with: "example.test/b")] {
        model.update(snapshot)
        model.setSiteControlsOpen(true)
        model.performSiteControl("activateExtension", text: "extension-id")
        let count = commands.messages.count
        model.update(changed)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(commands.messages.count == count,
                     "Switching tabs or navigating cancels a pending popover action")
    }
    model.update(snapshot)
    var page = try! JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as! [String: Any]
    let permission: [String: Any] = ["id": "clipboard", "setting": "ask", "editable": true,
                                   "isDefault": true, "options": ["default", "ask", "allow", "block"]]
    page["siteControls"] = ["tabId": 41, "url": "https://example.test/a", "canManagePermissions": true,
                            "canInspect": true, "extensions": [], "permissions": [permission]]
    let editablePage = String(data: try! JSONSerialization.data(withJSONObject: page, options: [.withoutEscapingSlashes]), encoding: .utf8)!
    model.update(editablePage)
    model.setSiteControlsOpen(true)
    let controls = model.snapshot.siteControls!
    model.setSitePermission("clipboard", to: "allow", for: controls)
    precondition(model.siteControlsOpen && commands.messages.last?["action"] as? String == "setSitePermission",
                 "Changing a permission keeps the popover open")
    precondition(commands.messages.last?["id"] as? Int == 41 &&
                 commands.messages.last?["text"] as? String == "allow" &&
                 (commands.messages.last?["metadata"] as? [String: String]) ==
                    ["url": "https://example.test/a", "permission": "clipboard"],
                 "Permission changes identify the exact page and permission")
    let count = commands.messages.count
    model.setSitePermission("unknown", to: "allow", for: controls)
    model.setSitePermission("clipboard", to: "invalid", for: controls)
    model.update(editablePage.replacingOccurrences(of: #""editable":true"#, with: #""editable":false"#))
    model.setSitePermission("clipboard", to: "allow", for: controls)
    precondition(commands.messages.count == count, "Unknown, unsupported, and managed permissions cannot be changed")
    model.update(editablePage.replacingOccurrences(of: "example.test/a", with: "example.test/b"))
    model.setSitePermission("clipboard", to: "allow", for: controls)
    precondition(commands.messages.count == count, "A permission menu cannot apply to a replacement page")
    model.update(snapshot)
    model.setSiteControlsOpen(false)
    print("Site controls dismiss and reject stale page actions correctly")
}

@MainActor private func checkAddressBarIcons(_ model: ChromiumSidebarModel, snapshot: String) throws {
    precondition(model.addressBarIcon == .globe, "An existing URL without a site icon shows a globe")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let color = NSColor(deviceRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
    let favicon = bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    let withIcon = snapshot.replacingOccurrences(of: #""loading":false"#,
        with: #""loading":false,"faviconValid":true,"favicon":""# + favicon + #"""#)
    model.update(withIcon)
    precondition(model.addressBarIcon == .favicon(favicon), "Editing the current address retains its favicon")
    model.update(withIcon.replacingOccurrences(of: #""faviconValid":true"#, with: #""faviconValid":false"#))
    precondition(model.addressBarIcon == .globe, "Chromium's default icon is not presented as a real site favicon")
    model.update(withIcon.replacingOccurrences(of: favicon, with: "invalid-image"))
    precondition(model.addressBarIcon == .globe, "Undecodable icons fall back to a globe")
    model.update(withIcon)
    model.editingAddress = true
    func results(_ query: String, action: String, items: [[String: Any]] = []) throws {
        let data = try JSONSerialization.data(withJSONObject: ["query": query, "action": action, "items": items])
        model.updateSuggestions(String(decoding: data, as: UTF8.self))
    }
    model.address = "another.example/path"
    model.requestSuggestions(for: model.address)
    try results(model.address, action: "navigate")
    precondition(model.addressBarIcon == .globe, "A different destination never keeps the old site's favicon")
    model.address = "how .env files work"
    model.requestSuggestions(for: model.address)
    try results(model.address, action: "search")
    precondition(model.addressBarIcon == .search, "The native action decides the icon, even for queries containing dots")
    try results("another.example/path", action: "navigate")
    precondition(model.addressBarIcon == .search, "Late results for previous input cannot change the current action icon")
    try results(model.address, action: "search", items: [
        ["kind": "tab", "id": 7, "title": "Example", "url": "https://example.test/", "favicon": favicon],
        ["kind": "history", "title": "History", "url": "https://history.test/"],
    ])
    model.moveSuggestionSelection(by: 1)
    precondition(model.addressBarIcon == .favicon(favicon), "Highlighting an open tab shows its destination icon")
    model.moveSuggestionSelection(by: 1)
    precondition(model.addressBarIcon == .globe, "Highlighting a history URL changes the search icon to a globe")
    model.selectedSuggestion = nil
    precondition(model.addressBarIcon == .search, "Clearing the highlighted suggestion restores the typed action")
    model.clearSuggestions()
    model.address = ""
    precondition(model.addressBarIcon == .search, "A fresh empty field invites a search")
    model.editingAddress = false
    var favorite = try JSONSerialization.jsonObject(with: Data(withIcon.utf8)) as! [String: Any]
    favorite["favorites"] = favorite["tabs"]
    favorite["tabs"] = []
    model.update(String(decoding: try JSONSerialization.data(withJSONObject: favorite), as: UTF8.self))
    precondition(model.address == "https://example.test/a" && model.addressBarIcon == .favicon(favicon),
                 "An active Favorite supplies its own address and favicon")
    model.update(snapshot)
    print("Address popover icon checks passed")
}
