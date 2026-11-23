import AppKit
import Combine
import SwiftUI
import BarkCore

/// Bark's keyboard shortcuts drive both key handling and the guide in the Help menu.
struct BarkShortcut {
    enum Action: Equatable {
        case newLittleWindow, toggleSidebar, togglePin, copyURL, copyMarkdown, archiveTabs, undoOrganization
        case nextTab, previousTab, nextSpace, previousSpace
        case tab(Int), space(Int)
        case addSplit, closeSplit
        case recentTab, recentTabReverse
    }
    /// Either a character (as typed without modifiers) or a layout-independent key code.
    enum Key: Equatable {
        case character(String)
        case code(UInt16)
    }
    let action: Action
    let key: Key
    let modifiers: NSEvent.ModifierFlags
    /// The keys as shown in the guide, such as "⌘ S".
    let keys: String
    let title: String
    let section: String
    /// Holding the keys repeats the action.
    var repeats = false

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static let all: [BarkShortcut] = {
        var list = [
            BarkShortcut(action: .newLittleWindow, key: .character("n"), modifiers: [.option, .command], keys: "⌥ ⌘ N", title: "New Little window", section: "Sidebar and tabs"),
            BarkShortcut(action: .toggleSidebar, key: .character("s"), modifiers: .command, keys: "⌘ S", title: "Show or hide the sidebar", section: "Sidebar and tabs"),
            BarkShortcut(action: .togglePin, key: .character("d"), modifiers: .command, keys: "⌘ D", title: "Pin or unpin the current tab", section: "Sidebar and tabs"),
            BarkShortcut(action: .copyURL, key: .character("c"), modifiers: [.command, .shift], keys: "⇧ ⌘ C", title: "Copy the page's link", section: "Sidebar and tabs"),
            BarkShortcut(action: .copyMarkdown, key: .character("c"), modifiers: [.command, .shift, .option], keys: "⌥ ⇧ ⌘ C", title: "Copy the page's link as Markdown", section: "Sidebar and tabs"),
            BarkShortcut(action: .undoOrganization, key: .character("z"), modifiers: [.command, .option], keys: "⌥ ⌘ Z", title: "Undo the last sidebar organization change", section: "Sidebar and tabs"),
            BarkShortcut(action: .archiveTabs, key: .character("k"), modifiers: [.command, .shift], keys: "⇧ ⌘ K", title: "Archive this space's unpinned tabs", section: "Sidebar and tabs"),
            BarkShortcut(action: .nextTab, key: .code(125), modifiers: [.command, .option], keys: "⌥ ⌘ ↓", title: "Next tab in the sidebar", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .previousTab, key: .code(126), modifiers: [.command, .option], keys: "⌥ ⌘ ↑", title: "Previous tab in the sidebar", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .tab(1), key: .character("1"), modifiers: .command, keys: "⌘ 1 – 9", title: "Go to that tab, counting from the top of the sidebar", section: "Sidebar and tabs"),
            BarkShortcut(action: .recentTab, key: .code(48), modifiers: .control, keys: "⌃ Tab", title: "Switch to a recent tab (hold ⌃ and press Tab again to go further back)", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .recentTabReverse, key: .code(48), modifiers: [.control, .shift], keys: "⌃ ⇧ Tab", title: "Move back through recent tabs", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .nextSpace, key: .code(124), modifiers: [.command, .option], keys: "⌥ ⌘ →", title: "Next space", section: "Spaces"),
            BarkShortcut(action: .previousSpace, key: .code(123), modifiers: [.command, .option], keys: "⌥ ⌘ ←", title: "Previous space", section: "Spaces"),
            BarkShortcut(action: .space(1), key: .character("1"), modifiers: .control, keys: "⌃ 1 – 9", title: "Go to that space", section: "Spaces"),
            BarkShortcut(action: .addSplit, key: .code(24), modifiers: [.control, .shift], keys: "⌃ ⇧ =", title: "Open a split view beside the current tab", section: "Split view"),
            BarkShortcut(action: .closeSplit, key: .code(27), modifiers: [.control, .shift], keys: "⌃ ⇧ −", title: "Separate the split view into two tabs", section: "Split view"),
        ]
        for number in 2...9 {
            list.append(BarkShortcut(action: .tab(number), key: .character(String(number)), modifiers: .command, keys: "", title: "", section: ""))
            list.append(BarkShortcut(action: .space(number), key: .character(String(number)), modifiers: .control, keys: "", title: "", section: ""))
        }
        return list
    }()

    /// Shortcuts handled by Chromium and listed in Bark's guide.
    static let builtIn: [(keys: String, title: String)] = [
        ("⌘ T", "New tab"), ("⌘ L", "Edit the address"), ("⌘ W", "Close the tab"),
        ("⇧ ⌘ T", "Reopen the last closed tab"),
        ("⌘ N", "New window"), ("⇧ ⌘ N", "New Incognito window"), ("⌘ R", "Reload"),
        ("⌘ [  and  ⌘ ]", "Back and forward"), ("⌘ F", "Find on the page"), ("⌘ Y", "History"),
    ]

    static func match(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> BarkShortcut? {
        let pressed = modifiers.intersection(relevantModifiers)
        let typed = characters?.lowercased()
        return all.first { shortcut in
            guard shortcut.modifiers == pressed else { return false }
            switch shortcut.key {
            case .character(let character): return character == typed
            case .code(let code): return code == keyCode
            }
        }
    }
}

/// Handles Bark's shortcuts for the key browser window before Chromium's menu
/// and the page receive them.
@MainActor final class ShortcutMonitor {
    static let shared = ShortcutMonitor()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            ShortcutMonitor.shared.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Only browser windows with a sidebar; sheets, panels, and windows
        // using Chromium's own toolbar keep Chromium's shortcuts.
        if RecentTabSwitcher.shared.handleKey(event) { return true }
        guard let window = event.window ?? NSApp.keyWindow, window.isKeyWindow, window.attachedSheet == nil,
              let model = ChromiumHostingView.model(in: window) else { return false }
        // Ordinary Cmd+Z belongs to the webpage and text fields. Only consume
        // it when focus is inside the sidebar itself; Option-Cmd-Z is explicit.
        if event.charactersIgnoringModifiers?.lowercased() == "z",
           event.modifierFlags.intersection(BarkShortcut.relevantModifiers) == .command,
           !(window.firstResponder is NSTextView),
           let focused = window.firstResponder as? NSView, let sidebar = model.hostView,
           focused === sidebar || focused.isDescendant(of: sidebar),
           model.snapshot.organizationUndoLabel != nil {
            model.send("undoOrganization")
            return true
        }
        guard let shortcut = BarkShortcut.match(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                                modifiers: event.modifierFlags) else { return false }
        if shortcut.action == .recentTab || shortcut.action == .recentTabReverse {
            RecentTabSwitcher.shared.press(model: model, window: window, reverse: shortcut.action == .recentTabReverse)
            return true
        }
        if !event.isARepeat || shortcut.repeats { model.perform(shortcut.action) }
        return true
    }
}

/// The shortcut list, opened from Help > Keyboard Shortcuts.
@MainActor final class ShortcutGuide: NSObject {
    static let shared = ShortcutGuide()
    private var window: NSWindow?
    private var menuItem: NSMenuItem?

    /// Adds "Keyboard Shortcuts" to the Help menu Chromium built.
    func installHelpMenuItem() {
        guard menuItem?.menu == nil, let menu = NSApp.helpMenu ?? NSApp.mainMenu?.items.last?.submenu else { return }
        let item = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showFromMenu(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menuItem = item
    }

    @objc private func showFromMenu(_ sender: Any?) { show() }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
            window.title = "Keyboard Shortcuts"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ShortcutGuideView())
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ShortcutGuideView: View {
    private static let sections = ["Sidebar and tabs", "Spaces", "Split view"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Use these shortcuts while a Bark window is in front.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Self.sections, id: \.self) { section in
                    group(section, BarkShortcut.all.filter { $0.section == section }.map { ($0.keys, $0.title) })
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Split view with the mouse").font(.system(size: 13, weight: .semibold))
                    Text("Drag a tab from the sidebar onto the left or right half of the page to open it beside the current tab. Drag the divider to resize the halves. To go back to two separate tabs, right-click either tab and choose Separate Split View.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                group("Browser shortcuts", BarkShortcut.builtIn.map { ($0.keys, $0.title) })
                Text("These shortcuts replace Chromium's for the same keys: Save Page (⌘ S), Bookmark (⌘ D), and Inspect Element (⇧ ⌘ C) remain available from the menus and the page's context menu.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 400, minHeight: 320)
    }

    private func group(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.1).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.0).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}
