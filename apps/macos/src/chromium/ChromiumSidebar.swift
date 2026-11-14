import AppKit
import Combine
import SwiftUI
import BarkCore

// This model is a projection of Chromium's TabStripModel, never a second tab
// database. Commands use session IDs, not indices that can change under us.
struct ChromiumTab: Decodable, Identifiable {
    let id: Int
    let title: String
    let url: String
    let pinned: Bool
    let active: Bool
    let loading: Bool
    let favicon: String?
    // Playing sound now or moments ago, and silenced by the user.
    var audible: Bool? = nil
    var muted: Bool? = nil
    // Chromium's split view: the split this tab belongs to, and whether that
    // split is the one on screen.
    var split: String? = nil
    var splitActive: Bool? = nil
    var isBlank: Bool { url == "about:blank" || url == "chrome://newtab/" }
    var faviconImage: NSImage? {
        guard let favicon, let data = Data(base64Encoded: favicon), data.count <= 262144 else { return nil }
        return NSImage(data: data)
    }
}

struct ChromiumArchivedTab: Decodable {
    let title: String
    let url: String
    var displayTitle: String {
        if !title.isEmpty { return title.count > 60 ? String(title.prefix(59)) + "…" : title }
        return URL(string: url)?.host ?? url
    }
}

struct ChromiumDownloads: Decodable {
    let active: Int
    /// 0–1, or negative when the size of a download is unknown.
    let progress: Double
    /// A download finished in the last 30 seconds.
    let recent: Bool
}

struct ChromiumSpace: Decodable, Identifiable {
    let id: String
    let name: String
    let active: Bool
    var profile: String? = nil
    var theme: String? = nil
    var emoji: String? = nil
    var displayName: String { name == "Your Chromium" ? "Personal" : name }
}

struct ChromiumProfile: Decodable, Identifiable {
    let id: String
    let name: String
}

struct ChromiumSnapshot: Decodable {
    let tabs: [ChromiumTab]
    let spaces: [ChromiumSpace]
    let profile: String
    let canGoBack: Bool
    let canGoForward: Bool
    var sidebarCollapsed: Bool? = nil
    var sidebarRevealed: Bool? = nil
    var sidebarWidth: Double? = nil
    var securityLevel: String? = nil
    var securityDescription: String? = nil
    var incognito: Bool? = nil
    var profiles: [ChromiumProfile]? = nil
    var profileId: String? = nil
    var activeSpaceId: String? = nil
    var switchingSpace: Bool? = nil
    // Chromium's color mode: "system", "light", or "dark".
    var appearance: String? = nil
    // Tabs shown in every space of this profile's window, as icons.
    var favorites: [ChromiumTab]? = nil
    // Tabs archived from the active space, most recent first.
    var archivedTabs: [ChromiumArchivedTab]? = nil
    var downloads: ChromiumDownloads? = nil
    // False once this profile's window is hidden behind another space's window.
    var windowVisible: Bool? = nil
    // Read-only tabs of the spaces adjacent to the active one, keyed by space ID.
    var spacePreviews: [String: [ChromiumTab]]? = nil
}

typealias ChromiumCommand = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

/// A row under the address bar: an open tab to switch to, a history entry, or
/// the typed URL itself.
struct SpaceSettingsTarget: Identifiable {
    let space: ChromiumSpace
    var id: String { space.id }
}

struct AddressSuggestion: Decodable, Identifiable, Equatable {
    let kind: String
    let title: String
    let url: String
    var id: Int? = nil
    var favicon: String? = nil
    var space: String? = nil
    var isTab: Bool { kind == "tab" }
    var listID: String { kind + ":" + (id.map(String.init) ?? url) }
}

private struct AddressSuggestions: Decodable {
    let query: String
    let items: [AddressSuggestion]
}

@MainActor final class ChromiumSidebarModel: ObservableObject {
    @Published private(set) var snapshot = ChromiumSnapshot(tabs: [], spaces: [], profile: "", canGoBack: false, canGoForward: false)
    @Published var address = ""
    @Published var editingAddress = false
    // Presents the centered address bar over this sidebar's browser window.
    var presentAddressBar: (() -> Void)?
    // The sidebar's AppKit view, for window geometry and keyboard shortcuts.
    weak var hostView: NSView?
    let splitDrop = SplitDropController()
    // Incremented by the keyboard shortcut; the sidebar archives with undo.
    @Published private(set) var archiveRequests = 0
    @Published private(set) var suggestions: [AddressSuggestion] = []
    @Published var selectedSuggestion: Int?
    private var suggestionQuery: String?

    /// Requests suggestions for `text`; results arrive via `updateSuggestions`.
    func requestSuggestions(for text: String) {
        suggestionQuery = text
        send("suggest", text: text)
    }

    func updateSuggestions(_ json: String) {
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(AddressSuggestions.self, from: data),
              result.query == suggestionQuery else { return }
        let previous = selectedSuggestion.flatMap { suggestions.indices.contains($0) ? suggestions[$0].listID : nil }
        suggestions = result.items
        // Keep the highlighted row if it is still present; otherwise clear it.
        selectedSuggestion = previous.flatMap { id in suggestions.firstIndex { $0.listID == id } }
    }

    func clearSuggestions() {
        suggestionQuery = nil
        suggestions = []
        selectedSuggestion = nil
    }

    func moveSuggestionSelection(by step: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selectedSuggestion ?? -1) + step
        selectedSuggestion = next < 0 ? nil : min(next, suggestions.count - 1)
    }

    /// Opens a suggestion: switches to an open tab, otherwise navigates.
    func openSuggestion(_ suggestion: AddressSuggestion) {
        if suggestion.isTab, let id = suggestion.id { send("switchToTab", id: id) }
        else { send("navigate", text: suggestion.url) }
    }
    var presentingSidebarUI = false
    @Published var theme: SpaceTheme = .gray
    @Published var emoji = "🍃"
    private var callback: ChromiumCommand?
    private let context: UnsafeMutableRawPointer?
    private var previousActiveID: Int?
    // Two-finger horizontal swipe between spaces. The offset follows the
    // fingers; releasing past the threshold commits to the adjacent space.
    @Published private(set) var spaceSwipeOffset: CGFloat = 0
    private var rawSwipeOffset: CGFloat = 0
    private var swipeCommitTarget: String?
    private var swipeResetWork: DispatchWorkItem?

    init(context: UnsafeMutableRawPointer?, callback: ChromiumCommand?) {
        self.context = context
        self.callback = callback
    }

    func update(_ json: String) {
        guard let data = json.data(using: .utf8), let next = try? JSONDecoder().decode(ChromiumSnapshot.self, from: data) else { return }
        let changedProfile = next.profile != snapshot.profile || next.incognito != snapshot.incognito ||
            next.activeSpaceId != snapshot.activeSpaceId
        snapshot = next
        // A swipe ends when its space is shown here, or when another
        // profile's window took over and this one was hidden.
        if let target = swipeCommitTarget, next.activeSpaceId == target || next.windowVisible == false { finishSpaceSwipe() }
        let active = next.tabs.first { $0.active }
        if !editingAddress || previousActiveID != active?.id {
            address = active?.isBlank == true ? "" : active?.url ?? ""
        }
        previousActiveID = active?.id
        if changedProfile || activeSpace?.theme != nil {
            theme = isIncognito ? .gray : SpaceTheme(rawValue: activeSpace?.theme ?? UserDefaults.standard.string(forKey: settingsKey("theme")) ?? "gray") ?? .gray
            emoji = isIncognito ? "" : Space.normalizedEmoji(activeSpace?.emoji ?? UserDefaults.standard.string(forKey: settingsKey("emoji")) ?? "🍃") ?? "🍃"
        }
    }

    private func settingsKey(_ suffix: String) -> String { "BarkChromium.\(snapshot.profile).\(suffix)" }

    func moveSpace(_ space: ChromiumSpace, toProfile profile: String) {
        guard !isIncognito, profile != space.profile else { return }
        send("setSpaceProfile", metadata: ["space": space.id, "profile": profile])
    }

    func saveSpaceSettings(_ space: ChromiumSpace, name: String, theme: SpaceTheme, emoji: String, profile: String) {
        guard !isIncognito, let emoji = Space.normalizedEmoji(emoji) else { return }
        if space.active { self.theme = theme; self.emoji = emoji }
        send("customizeSpace", metadata: ["space": space.id, "name": String(name.prefix(32)),
                                          "theme": theme.rawValue, "emoji": emoji])
        if !profile.isEmpty, profile != space.profile { moveSpace(space, toProfile: profile) }
    }

    /// Changes another space's color or emoji without switching to it.
    func customize(_ space: ChromiumSpace, theme: SpaceTheme? = nil, emoji: String? = nil) {
        guard !isIncognito else { return }
        if space.active { customize(theme: theme ?? self.theme, emoji: emoji ?? self.emoji); return }
        let current = SpaceTheme(rawValue: space.theme ?? "gray") ?? .gray
        send("customizeSpace", metadata: ["space": space.id, "theme": (theme ?? current).rawValue,
                                          "emoji": Space.normalizedEmoji(emoji ?? "") ?? self.emoji(for: space)])
    }

    func customize(theme: SpaceTheme, emoji: String) {
        guard !isIncognito else { return }
        self.theme = theme
        self.emoji = Space.normalizedEmoji(emoji) ?? "🍃"
        if snapshot.activeSpaceId != nil {
            send("customizeSpace", metadata: ["theme": theme.rawValue, "emoji": self.emoji])
            return
        }
        UserDefaults.standard.set(theme.rawValue, forKey: settingsKey("theme"))
        UserDefaults.standard.set(self.emoji, forKey: settingsKey("emoji"))
    }

    func send(_ action: String, id: Int? = nil, text: String? = nil, width: Double? = nil, metadata: [String: String]? = nil) {
        if isIncognito && ["space", "createSpace", "deleteSpace", "manageSpaces", "moveTabToSpace", "createProfile", "customizeSpace", "appearance"].contains(action) { return }
        var message: [String: Any] = ["action": action]
        if let id { message["id"] = id }
        if let text { message["text"] = text }
        if let width { message["width"] = width }
        if let metadata { message["metadata"] = metadata }
        guard let callback, let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { callback(context, $0) }
    }

    var isIncognito: Bool { snapshot.incognito == true }
    var activeSpace: ChromiumSpace? { snapshot.spaces.first { $0.active } }
    var activeProfileName: String {
        snapshot.profiles?.first { $0.id == snapshot.profileId }?.name ?? "Personal"
    }
    var activeSpaceName: String {
        isIncognito ? "Incognito" : snapshot.spaces.first(where: { $0.active })?.displayName ?? "Personal"
    }

    /// A space can be deleted unless it is the last one of its profile.
    func canDelete(_ space: ChromiumSpace) -> Bool {
        !isIncognito && snapshot.spaces.filter { $0.profile == space.profile }.count > 1
    }
    /// Other spaces of this window's profile, where a tab can be moved.
    var moveTargets: [ChromiumSpace] {
        isIncognito ? [] : snapshot.spaces.filter { !$0.active && $0.profile != nil && $0.profile == snapshot.profileId }
    }
    var activeTabLoading: Bool {
        (snapshot.tabs + (snapshot.favorites ?? [])).contains { $0.active && $0.loading }
    }

    func emoji(for space: ChromiumSpace) -> String {
        if let emoji = space.emoji { return Space.normalizedEmoji(emoji) ?? "🍃" }
        if space.active { return emoji }
        return Space.normalizedEmoji(UserDefaults.standard.string(forKey: "BarkChromium.\(space.id).emoji") ?? "🍃") ?? "🍃"
    }

    var addressSummary: String {
        guard !address.isEmpty, let url = URL(string: address), let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return address }
        let origin = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return origin + (url.port.map { ":\($0)" } ?? "")
    }

    func cancelAddressEditing() {
        editingAddress = false
        let active = snapshot.tabs.first(where: { $0.active })
        address = active?.isBlank == true ? "" : active?.url ?? ""
    }

    func focusAddress() { presentAddressBar?() }

    // MARK: Keyboard shortcuts

    /// Tabs in sidebar order: Favorites, pinned, then the rest.
    private var orderedTabs: [ChromiumTab] {
        (isIncognito ? [] : snapshot.favorites ?? []) + snapshot.tabs.filter(\.pinned) + snapshot.tabs.filter { !$0.pinned }
    }

    func perform(_ action: BarkShortcut.Action) {
        let tabs = orderedTabs
        let active = tabs.first { $0.active }
        let spaces = snapshot.spaces
        switch action {
        case .toggleSidebar: send("toggleSidebar")
        case .togglePin:
            // Favorites stay where they are; unpinning one would drop it into a space.
            if let tab = snapshot.tabs.first(where: { $0.active }) { send("pin", id: tab.id) }
        case .copyURL, .copyMarkdown:
            guard let active, !active.isBlank else { return }
            let title = active.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action == .copyURL ? active.url : "[\(title)](\(active.url))", forType: .string)
        case .nextTab, .previousTab:
            guard tabs.count > 1 else { return }
            let step = action == .nextTab ? 1 : -1
            let index = tabs.firstIndex { $0.active }.map { ($0 + step + tabs.count) % tabs.count } ?? 0
            send("select", id: tabs[index].id)
        case .tab(let number):
            if tabs.indices.contains(number - 1) { send("select", id: tabs[number - 1].id) }
        case .nextSpace, .previousSpace:
            guard snapshot.switchingSpace != true, let index = spaces.firstIndex(where: { $0.active }) else { return }
            let target = index + (action == .nextSpace ? 1 : -1)
            if spaces.indices.contains(target) { send("space", text: spaces[target].id) }
        case .space(let number):
            guard snapshot.switchingSpace != true, spaces.indices.contains(number - 1), !spaces[number - 1].active else { return }
            send("space", text: spaces[number - 1].id)
        case .addSplit: send("splitNew")
        case .closeSplit: send("unsplit")
        case .archiveTabs:
            if !isIncognito, snapshot.tabs.contains(where: { !$0.pinned }) { archiveRequests += 1 }
        }
    }

    func shutdown() { callback = nil; swipeResetWork?.cancel() }

    // MARK: Space swipe

    private var activeSpaceIndex: Int? { snapshot.spaces.firstIndex { $0.active } }
    var previousSpace: ChromiumSpace? {
        guard let i = activeSpaceIndex, i > 0 else { return nil }
        return snapshot.spaces[i - 1]
    }
    var nextSpace: ChromiumSpace? {
        guard let i = activeSpaceIndex, i + 1 < snapshot.spaces.count else { return nil }
        return snapshot.spaces[i + 1]
    }
    /// The space being revealed by the current swipe offset.
    var swipeNeighbor: ChromiumSpace? {
        spaceSwipeOffset < 0 ? nextSpace : spaceSwipeOffset > 0 ? previousSpace : nil
    }
    var canSwipeSpaces: Bool {
        !isIncognito && snapshot.spaces.count > 1 && snapshot.switchingSpace != true && swipeCommitTarget == nil
    }

    private var preparedSpaces: Set<String> = []

    func beginSpaceSwipe() {
        rawSwipeOffset = spaceSwipeOffset
        preparedSpaces = []
    }

    /// `fingerDelta` is positive when the fingers move right.
    func updateSpaceSwipe(by fingerDelta: CGFloat, width: CGFloat) {
        guard swipeCommitTarget == nil, width > 0 else { return }
        rawSwipeOffset += fingerDelta
        let target = rawSwipeOffset < 0 ? nextSpace : previousSpace
        if let target {
            spaceSwipeOffset = min(width, max(-width, rawSwipeOffset))
            // Load another profile as soon as a swipe reveals its space, so a
            // committed switch does not wait for the profile to load.
            if target.profile != nil, target.profile != snapshot.profileId, preparedSpaces.insert(target.id).inserted {
                send("prepareSpace", text: target.id)
            }
        } else {
            // Rubber-band at the first and last space.
            let pull = rawSwipeOffset * 0.25
            spaceSwipeOffset = min(48, max(-48, pull))
        }
    }

    func endSpaceSwipe(velocity: CGFloat, width: CGFloat, cancelled: Bool) {
        let offset = spaceSwipeOffset
        let target = offset < 0 ? nextSpace : offset > 0 ? previousSpace : nil
        let flicked = abs(velocity) > 10 && (velocity < 0) == (offset < 0)
        guard !cancelled, let target, width > 0, abs(offset) > width * 0.35 || (flicked && abs(offset) > 12) else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { spaceSwipeOffset = 0 }
            rawSwipeOffset = 0
            return
        }
        swipeCommitTarget = target.id
        withAnimation(.easeOut(duration: 0.16)) { spaceSwipeOffset = offset < 0 ? -width : width }
        if target.profile != nil && target.profile != snapshot.profileId {
            // Another profile's window: start it now so it renders during the
            // slide; Chromium reveals it once the slide has finished.
            send("space", text: target.id, metadata: ["revealAfter": "160"])
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.send("space", text: target.id)
            }
        }
        // Switching to another profile presents a different window; this
        // sidebar is reset once it is covered, or if the switch never lands.
        let reset = DispatchWorkItem { [weak self] in self?.finishSpaceSwipe() }
        swipeResetWork?.cancel()
        swipeResetWork = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reset)
    }

    func finishSpaceSwipe() {
        swipeResetWork?.cancel(); swipeResetWork = nil
        swipeCommitTarget = nil
        rawSwipeOffset = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { spaceSwipeOffset = 0 }
    }
}

// The address bar opens as a panel centered over the browser window, with the
// full URL selected so it can be replaced or edited in place. It is a child
// window of the browser window, so it moves with it and closes on Escape,
// on Return (after navigating), or when focus moves elsewhere.
@MainActor final class AddressBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let model: ChromiumSidebarModel
    private var panel: AddressBarPanel?
    private var field: NSTextField?
    private weak var parent: NSWindow?
    private var suggestionsObserver: AnyCancellable?
    private var openedAt: Date?
    private var scrim: AddressBarScrim?
    private static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40

    init(model: ChromiumSidebarModel) { self.model = model }

    func show(over window: NSWindow?) {
        guard let window, window.isVisible else { return }
        let panel = self.panel ?? makePanel()
        if parent !== window {
            parent?.removeChildWindow(panel)
            if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
            parent = window
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(parentChanged(_:)), name: name, object: window)
            }
        }
        model.editingAddress = true
        field?.stringValue = model.address
        // Start with recently used open tabs; typing narrows to matches.
        model.requestSuggestions(for: "")
        position(panel)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        openedAt = Date()
        showScrim(in: window)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field?.currentEditor()?.selectAll(nil)
    }

    func close(returnFocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        model.cancelAddressEditing()
        model.send("suggest", text: "")  // Stops any running history query.
        model.clearSuggestions()
        hideScrim()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if returnFocus, let parent, parent.isVisible { parent.makeKeyAndOrderFront(nil) }
    }

    func tearDown() {
        if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
        if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil); panel.delegate = nil }
        suggestionsObserver = nil
        scrim?.removeFromSuperview(); scrim = nil
        field?.delegate = nil
        panel = nil; field = nil; parent = nil
    }

    private func makePanel() -> AddressBarPanel {
        let panel = AddressBarPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 56),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor

        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .labelColor
        field.placeholderString = "Search or enter address"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Address")
        field.delegate = self

        let row = NSStackView(views: [icon, field])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)

        let list = NSHostingView(rootView: AddressSuggestionList(model: model) { [weak self] suggestion in
            self?.open(suggestion)
        })
        list.sizingOptions = []
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        self.field = field
        suggestionsObserver = model.$suggestions.dropFirst().sink { [weak self] items in
            // @Published fires before the value is stored; lay out next turn.
            DispatchQueue.main.async { self?.resize(rows: items.count) }
        }
        return panel
    }

    private func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + AddressSuggestionList.padding * 2 + 1
    }

    private func resize(rows: Int) {
        guard let panel, panel.isVisible else { return }
        position(panel, rows: rows)
    }

    private func open(_ suggestion: AddressSuggestion) {
        close()
        model.openSuggestion(suggestion)
    }

    // Dims the browser window's content under the bar. The scrim is a plain
    // subview of the window's content view (where Chromium also attaches the
    // sidebar), so it follows the window's rounded corners and resizing, and
    // it ignores clicks: clicking the page still dismisses the bar.
    private func showScrim(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let scrim = self.scrim ?? AddressBarScrim()
        self.scrim = scrim
        if scrim.superview !== content {
            scrim.removeFromSuperview()
            scrim.frame = content.bounds
            scrim.autoresizingMask = [.width, .height]
            scrim.alphaValue = 0
        }
        // Keep it above Chromium's views, which may have been added since.
        content.addSubview(scrim, positioned: .above, relativeTo: nil)
        scrim.generation += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scrim.animator().alphaValue = 1
        }
    }

    private func hideScrim() {
        guard let scrim, scrim.superview != nil else { return }
        scrim.generation += 1
        let generation = scrim.generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            scrim.animator().alphaValue = 0
        }, completionHandler: { [weak scrim] in
            // Reopening during the fade-out keeps the scrim in place.
            MainActor.assumeIsolated {
                guard let scrim, scrim.generation == generation else { return }
                scrim.removeFromSuperview()
            }
        })
    }

    // The field stays centered in the window; suggestions extend below it.
    private func position(_ panel: NSPanel, rows: Int? = nil) {
        guard let parent else { return }
        let frame = parent.frame
        let width = min(680, max(320, frame.width - 120))
        let height = Self.fieldHeight + listHeight(rows: rows ?? model.suggestions.count)
        let top = frame.midY + Self.fieldHeight / 2
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    @objc private func parentChanged(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    // Clicking anywhere else, including the page, dismisses the bar. Chromium
    // can also re-activate the browser window on its own right after the bar
    // opens (for example while finishing a new tab); keep the bar then.
    func windowDidResignKey(_ notification: Notification) {
        let type = NSApp.currentEvent?.type
        let clicked = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let justOpened = openedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        if !clicked && justOpened, let panel, panel.isVisible, NSApp.isActive {
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                panel.makeKey()
                if panel.firstResponder !== self.field?.currentEditor() { panel.makeFirstResponder(self.field) }
            }
            return
        }
        close(returnFocus: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        model.address = field.stringValue
        model.selectedSuggestion = nil
        model.requestSuggestions(for: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
            guard !model.suggestions.isEmpty else { return false }
            model.moveSuggestionSelection(by: command == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) {
            if let index = model.selectedSuggestion, model.suggestions.indices.contains(index) {
                open(model.suggestions[index])
                return true
            }
            let text = control.stringValue
            close()
            model.send("navigate", text: text)
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}

private struct AddressSuggestionList: View {
    static let padding: CGFloat = 6
    @ObservedObject var model: ChromiumSidebarModel
    let open: (AddressSuggestion) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if !model.suggestions.isEmpty { Divider() }
            VStack(spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.listID) { index, suggestion in
                    AddressSuggestionRow(suggestion: suggestion, selected: model.selectedSuggestion == index)
                        .frame(height: AddressBarController.rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { open(suggestion) }
                        .onHover { if $0 { model.selectedSuggestion = index } }
                }
            }.padding(Self.padding)
            Spacer(minLength: 0)
        }
    }
}

private struct AddressSuggestionRow: View {
    let suggestion: AddressSuggestion
    let selected: Bool
    private var icon: NSImage? {
        guard let encoded = suggestion.favicon, let data = Data(base64Encoded: encoded), data.count <= 262144 else { return nil }
        return NSImage(data: data)
    }
    private var subtitle: String {
        guard let url = URL(string: suggestion.url), let host = url.host else { return suggestion.url }
        let path = url.path == "/" ? "" : url.path
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }
    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else {
                    Image(systemName: suggestion.isTab ? "square.on.square" : suggestion.kind == "history" ? "clock" : "globe")
                        .foregroundStyle(.secondary)
                }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title.isEmpty ? subtitle : suggestion.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if suggestion.isTab {
                Text(suggestion.space.map { "Switch to tab · \($0)" } ?? "Switch to tab")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color.accentColor.opacity(selected ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor final class AddressBarScrim: NSView {
    var generation = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class AddressBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// A shared, understated hover treatment for navigation, tab actions and spaces.
private struct SidebarButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.13 : hovered ? 0.065 : 0),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
    }
}

private struct ChromiumTabRow: View {
    @ObservedObject var model: ChromiumSidebarModel
    let tab: ChromiumTab
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    private var favicon: NSImage? { tab.faviconImage }
    private var title: String { tab.title.isEmpty || tab.isBlank ? "New tab" : tab.title }
    private var muteLabel: String { tab.muted == true ? "Unmute tab" : "Mute tab" }
    private var audioDescription: String { tab.muted == true ? "Muted. " : tab.audible == true ? "Playing audio. " : "" }
    var body: some View {
        HStack(spacing: 9) {
            Group {
                if tab.loading { ProgressView().controlSize(.mini) }
                else if !tab.isBlank, let favicon { Image(nsImage: favicon).resizable().scaledToFit() }
                else { Image(systemName: tab.isBlank ? "square" : "globe").foregroundStyle(.secondary) }
            }.frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: tab.active ? .medium : .regular))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if tab.audible == true || tab.muted == true {
                Button { model.send("mute", id: tab.id) } label: {
                    Image(systemName: tab.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10)).frame(width: 22, height: 24)
                }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                    .help(muteLabel).accessibilityLabel(muteLabel)
            }
            if tab.split != nil && !hovered {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("In a split view").accessibilityHidden(true)
            }
            if hovered {
                HStack(spacing: 1) {
                    Button { model.send("pin", id: tab.id) } label: {
                        Image(systemName: tab.pinned ? "pin.slash" : "pin").font(.system(size: 10)).frame(width: 22, height: 24)
                    }.help(tab.pinned ? "Unpin tab" : "Pin tab").accessibilityLabel(tab.pinned ? "Unpin tab" : "Pin tab")
                    Button { model.send("close", id: tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 24)
                    }.help("Close tab").accessibilityLabel("Close tab")
                }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
            }
        }.padding(.leading, 11).padding(.trailing, hovered ? 5 : 11).frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tab.active ? Color.white.opacity(scheme == .dark ? 0.12 : 0.60)
                          // The other half of the split on screen.
                          : tab.splitActive == true ? Color.white.opacity(scheme == .dark ? 0.06 : 0.30)
                          : Color.primary.opacity(hovered ? 0.045 : 0))
                    .shadow(color: .black.opacity(tab.active ? (scheme == .dark ? 0.12 : 0.045) : 0), radius: 2, y: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9)).onTapGesture { model.send("select", id: tab.id) }
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityLabel(title)
            .accessibilityValue((tab.active ? "Selected. " : "") + (tab.split != nil ? "In a split view. " : "") + audioDescription + (tab.pinned ? "Pinned" : ""))
            .accessibilityAction { model.send("select", id: tab.id) }
            .accessibilityAction(named: "Close tab") { model.send("close", id: tab.id) }
            .accessibilityAction(named: tab.pinned ? "Unpin tab" : "Pin tab") { model.send("pin", id: tab.id) }
            .accessibilityAction(named: muteLabel) { model.send("mute", id: tab.id) }
            .contextMenu {
                if !tab.isBlank {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tab.url, forType: .string)
                    }
                    Button("Duplicate") { model.send("duplicate", id: tab.id) }
                }
                Button(muteLabel) { model.send("mute", id: tab.id) }
                if tab.split != nil {
                    Button("Separate Split View") { model.send("unsplit", id: tab.id) }
                } else if !tab.active {
                    Button("Open in Split View") { model.send("splitTab", id: tab.id, text: "right") }
                }
                Divider()
                if !model.isIncognito {
                    Button("Add to Favorites") { model.send("moveTab", id: tab.id, metadata: ["zone": "favorites", "before": ""]) }
                }
                Button(tab.pinned ? "Unpin tab" : "Pin tab") { model.send("pin", id: tab.id) }
                if !model.moveTargets.isEmpty {
                    Menu("Move to Space") {
                        ForEach(model.moveTargets) { space in
                            Button(model.emoji(for: space) + " " + space.displayName) {
                                model.send("moveTabToSpace", id: tab.id, text: space.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Close tab") { model.send("close", id: tab.id) }
                // Pinned tabs are kept, as in Chromium's own tab menu.
                Button("Close Other Tabs") { model.send("closeOthers", id: tab.id) }
                    .disabled(!model.snapshot.tabs.contains { !$0.pinned && $0.id != tab.id })
                Button("Close Tabs Below") { model.send("closeBelow", id: tab.id) }
                    .disabled(!(model.snapshot.tabs.drop { $0.id != tab.id }.dropFirst().contains { !$0.pinned }))
            }
    }
}

// A Favorites tile: a tab shown as its icon above every space of the profile.
private struct FavoriteTile: View {
    @ObservedObject var model: ChromiumSidebarModel
    let tab: ChromiumTab
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false
    private var title: String { tab.title.isEmpty || tab.isBlank ? "New tab" : tab.title }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tab.active ? Color.white.opacity(scheme == .dark ? 0.16 : 0.70)
                                 : Color.primary.opacity(hovered ? 0.09 : 0.055))
                .shadow(color: .black.opacity(tab.active ? (scheme == .dark ? 0.12 : 0.05) : 0), radius: 2, y: 1)
            Group {
                if tab.loading { ProgressView().controlSize(.small) }
                else if !tab.isBlank, let icon = tab.faviconImage { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: tab.isBlank ? "square" : "globe").foregroundStyle(.secondary) }
            }.frame(width: 18, height: 18)
        }.frame(height: 42)
            .contentShape(RoundedRectangle(cornerRadius: 10)).onTapGesture { model.send("select", id: tab.id) }
            .onHover { hovered = $0 }.help(title)
            .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityValue(tab.active ? "Selected. Favorite" : "Favorite")
            .accessibilityAction { model.send("select", id: tab.id) }
            .contextMenu {
                Button(tab.muted == true ? "Unmute tab" : "Mute tab") { model.send("mute", id: tab.id) }
                Button("Remove from Favorites") { model.send("moveTab", id: tab.id, metadata: ["zone": "unpinned", "before": ""]) }
                Button("Close tab") { model.send("close", id: tab.id) }
            }
    }
}

// Closes a tab on middle click, which SwiftUI gestures cannot observe. The
// view takes part in hit testing only for that button, so clicks, hover,
// drags and context menus still reach the row beneath it.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void
    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.buttonNumber == 2,
                  event.type == .otherMouseDown || event.type == .otherMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseDown(with event: NSEvent) {}
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
        }
    }
}

// Kept in its own native host so the actual macOS traffic lights remain exposed.
private struct ChromiumSidebarHeader: View {
    @ObservedObject var model: ChromiumSidebarModel
    var body: some View {
        HStack(spacing: 2) {
            control("sidebar.left", model.snapshot.sidebarCollapsed == true ? "Show sidebar" : "Hide sidebar") {
                model.send("toggleSidebar")
            }
            if model.isIncognito {
                Image(systemName: "eyeglasses").font(.system(size: 12)).frame(width: 24, height: 28)
                    .help("Incognito window").accessibilityLabel("Incognito window")
            }
            if model.snapshot.sidebarCollapsed != true {
                Spacer(minLength: 0)
                control("chevron.left", "Back") { model.send("back") }.disabled(!model.snapshot.canGoBack)
                control("chevron.right", "Forward") { model.send("forward") }.disabled(!model.snapshot.canGoForward)
                if model.activeTabLoading { control("xmark", "Stop loading") { model.send("stop") } }
                else { control("arrow.clockwise", "Reload") { model.send("reload") } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 28) }
            .buttonStyle(SidebarButtonStyle()).help(label).accessibilityLabel(label)
    }
}

/// A tab being dragged in the sidebar. Positions are in the sidebar's
/// coordinate space.
private struct TabDrag {
    let id: Int
    let fromFavorites: Bool
    /// Pointer position within the tab when the drag began.
    let grab: CGSize
    let size: CGSize
    var pointer: CGPoint
    /// Released; waiting for Chromium's new tab order.
    var dropped = false
    /// Over the page: the half where releasing opens the tab in a split view.
    var splitSide: SplitDropController.Side?
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ChromiumSidebar: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var resizeStart: Double?
    @State private var resizing = false
    @State private var resizeHovered = false
    @State private var draft: SpaceDraft?
    @State private var settingsSpace: SpaceSettingsTarget?
    @State private var settingsProfileID = ""
    @State private var draftProfileID = ""
    @State private var creatingProfile = false
    @State private var profileName = ""
    @State private var tabDrag: TabDrag?
    @State private var tabFrames: [Int: CGRect] = [:]
    @State private var archiveNotice: ArchiveNotice?
    private var floating: Bool { model.snapshot.sidebarCollapsed == true }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                addressField.padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 18)
                    .background(frameReporter(Self.addressKey))
                    .overlay { if showFavoritesHint { favoritesHint.padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 18) } }
                if !favorites.isEmpty {
                    favoritesGrid.padding(.horizontal, 12).padding(.bottom, 14)
                }
                ZStack(alignment: .top) {
                    activePage.offset(x: model.spaceSwipeOffset)
                    if let neighbor = model.swipeNeighbor {
                        previewPage(neighbor)
                            .offset(x: model.spaceSwipeOffset + (model.spaceSwipeOffset < 0 ? geometry.size.width : -geometry.size.width))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                // minHeight 0: a long preview list must be clipped here, not
                // make the sidebar taller than its window (which shifts and
                // squeezes the whole sidebar while swiping).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                if !model.isIncognito {
                    if let notice = archiveNotice {
                        archiveBanner(notice).padding(.horizontal, 10).padding(.top, 6).transition(.opacity)
                    }
                    spaceDock.padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 11)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: Self.dragSpace)
                .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
                .onChange(of: model.archiveRequests) { _ in archiveTabs() }
                .overlay(alignment: .topLeading) { dragOverlay }
                .background {
                    ZStack {
                        SidebarBackground(theme: model.theme)
                        if let neighbor = model.swipeNeighbor, geometry.size.width > 0 {
                            SidebarBackground(theme: SpaceTheme(rawValue: neighbor.theme ?? "gray") ?? .gray)
                                .opacity(min(1, abs(model.spaceSwipeOffset) / geometry.size.width))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0, style: .continuous))
                .overlay(alignment: .trailing) {
                    Color.primary.opacity(resizing || resizeHovered ? 0.15 : 0).frame(width: 4).contentShape(Rectangle())
                        .onHover { resizeHovered = $0; if $0 { NSCursor.resizeLeftRight.set() } else if !resizing { NSCursor.arrow.set() } }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                            if resizeStart == nil { resizeStart = geometry.size.width }
                            resizing = true
                            model.send("resize", width: min(400, max(200, (resizeStart ?? 260) + value.translation.width)))
                        }.onEnded { _ in resizeStart = nil; resizing = false; NSCursor.arrow.set() })
                        .accessibilityLabel("Resize sidebar")
                        .accessibilityAdjustableAction { model.send("resize", width: geometry.size.width + ($0 == .increment ? 20 : -20)) }
                }
        }.accessibilityHidden(model.snapshot.sidebarCollapsed == true && model.snapshot.sidebarRevealed != true)
            .onChange(of: draft?.id) { _ in model.presentingSidebarUI = settingsSpace != nil || draft != nil }
            .onChange(of: settingsSpace?.id) { _ in model.presentingSidebarUI = settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.activeSpaceId) { _ in archiveNotice = nil }
            .onChange(of: creatingProfile) { _ in model.presentingSidebarUI = creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.sidebarRevealed) { revealed in
            if floating && revealed != true && !model.editingAddress { model.cancelAddressEditing() }
        }
            .sheet(item: $settingsSpace) { target in
                SpaceEditor(draft: SpaceDraft(Space(id: target.space.id, name: target.space.displayName,
                                                    color: target.space.theme ?? "gray", icon: model.emoji(for: target.space))),
                            profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) },
                            profileID: $settingsProfileID, originalProfileID: target.space.profile) { name, theme, emoji in
                    model.saveSpaceSettings(target.space, name: name, theme: theme, emoji: emoji, profile: settingsProfileID)
                    settingsSpace = nil
                }
            }
            .sheet(item: $draft) { draft in
                SpaceEditor(draft: draft, profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) }, profileID: $draftProfileID) { name, theme, emoji in
                    model.send("createSpace", text: name, metadata: ["theme": theme.rawValue, "emoji": emoji, "profile": draftProfileID])
                    self.draft = nil
                }
            }
            .sheet(isPresented: $creatingProfile) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("New profile").font(.headline)
                    TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder)
                    Text("Spaces assigned to this profile share its sign-ins, history, and extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { creatingProfile = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Create") {
                            model.send("createProfile", text: String(profileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)))
                            creatingProfile = false
                        }.keyboardShortcut(.defaultAction).disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 340)
            }

    }

    // The active space's heading and tabs. This is the part that moves while
    // swiping between spaces; the address field and dock stay in place.
    private var activePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if model.isIncognito {
                    Image(systemName: "eyeglasses").font(.system(size: 15))
                } else {
                    Text(model.emoji).font(.system(size: 12))
                }
                Text(model.activeSpaceName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if !model.isIncognito { spacesMenu {
                    Text("Profile: " + model.activeProfileName)
                    if let active = model.activeSpace { Button("Space settings…") { showSettings(for: active) } }
                    if let active = model.activeSpace { colorMenu(for: active) }
                    Divider()
                    ForEach(model.snapshot.spaces) { space in
                        Button((space.active ? "✓ " : "") + space.displayName) { model.send("space", text: space.id) }
                    }
                    Divider()
                    Button("New space…", action: newSpace)
                    Button("Manage spaces…") { model.send("manageSpaces") }
                    if let active = model.activeSpace {
                        Button("Delete space…") { confirmDelete(active) }.disabled(!model.canDelete(active))
                    }
                } }
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 13)
                .contextMenu { if let active = model.activeSpace, !model.isIncognito { spaceMenu(for: active) } }
            ScrollView {
                tabList(model.snapshot.tabs, interactive: true)
            }.scrollIndicators(.hidden)
                .onChange(of: tabOrder) { _ in settleTabDrag() }
        }
    }

    // A non-interactive copy of an adjacent space, revealed during a swipe.
    private func previewPage(_ space: ChromiumSpace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.emoji(for: space)).font(.system(size: 12))
                Text(space.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                // The same control as the active page (not an image of it):
                // a borderless menu sizes differently, and any difference
                // makes the page jump when the swipe lands.
                spacesMenu { EmptyView() }
            }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 13)
            tabList(model.snapshot.spacePreviews?[space.id] ?? [], interactive: false)
            Spacer(minLength: 0)
        }
    }

    // The "…" menu in a space's heading.
    private func spacesMenu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Menu(content: content) { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Spaces")
    }

    private func tabList(_ tabs: [ChromiumTab], interactive: Bool) -> some View {
        let pinned = tabs.filter(\.pinned)
        // With nothing pinned, a dragged tab is pinned by dropping it on the
        // "New tab" row, which shows that while dragging. (A separate drop
        // area would push every row down under the pointer.)
        let pinZone = interactive && tabDrag?.dropped == false && pinned.isEmpty
        return LazyVStack(spacing: 3) {
            ForEach(pinned) { tabRow($0, interactive: interactive) }
            if !pinned.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 9).padding(.vertical, 12)
            }
            HStack(spacing: 2) {
                Button { if interactive { model.send("new") } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 13)).frame(width: 16)
                        Text("New tab").font(.system(size: 13))
                        Spacer()
                    }.padding(.horizontal, 11).frame(height: 34).foregroundStyle(.secondary)
                }.buttonStyle(SidebarButtonStyle()).help("New tab")
                // Closes this space's unpinned tabs into its archive.
                if tabs.contains(where: { !$0.pinned }) {
                    Button { if interactive { archiveTabs() } } label: {
                        Image(systemName: "archivebox").font(.system(size: 11)).frame(width: 30, height: 34)
                    }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                        .help("Archive unpinned tabs").accessibilityLabel("Archive unpinned tabs")
                }
            }
            .opacity(pinZone ? 0 : 1)
            .overlay { if pinZone { dropHint("pin", "Drop here to pin", targeted: dropZone == .pinned) } }
            .background { if interactive { frameReporter(Self.newTabKey) } }
            ForEach(tabs.filter { !$0.pinned }) { tabRow($0, interactive: interactive) }
        }.padding(.horizontal, 9).padding(.bottom, 12)
    }

    // MARK: Favorites and tab dragging
    // Drag a tab to reorder it; across the "New tab" row to pin or unpin it;
    // into the Favorites grid at the top to show it in every space.

    private var favorites: [ChromiumTab] { model.isIncognito ? [] : model.snapshot.favorites ?? [] }

    private var favoritesGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: min(max(favorites.count, 1), 4))
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(favorites) { tab in
                FavoriteTile(model: model, tab: tab)
                    .opacity(tabDrag?.id == tab.id ? 0 : 1)
                    .background(frameReporter(tab.id))
                    .simultaneousGesture(tabDragGesture(tab.id, fromFavorites: true))
            }
        }.background(frameReporter(Self.gridKey))
    }

    // With no Favorites yet, the address field shows where to drop a tab.
    private var showFavoritesHint: Bool {
        !model.isIncognito && favorites.isEmpty && tabDrag?.dropped == false
    }
    private var favoritesHint: some View {
        dropHint("star", "Drop here to add to Favorites", targeted: dropZone == .favorites)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
    }

    private func dropHint(_ symbol: String, _ label: String, targeted: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(label).font(.system(size: 12))
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(targeted ? 0.06 : 0))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(targeted ? 0.35 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }.accessibilityHidden(true)
    }

    private static let dragSpace = "BarkSidebar"
    private static let newTabKey = -1
    private static let addressKey = -2
    private static let gridKey = -3

    private func frameReporter(_ key: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TabFramesKey.self, value: [key: geometry.frame(in: .named(Self.dragSpace))])
        }
    }

    @ViewBuilder private func tabRow(_ tab: ChromiumTab, interactive: Bool) -> some View {
        if interactive {
            ChromiumTabRow(model: model, tab: tab)
                .overlay { MiddleClickCatcher { model.send("close", id: tab.id) }.accessibilityHidden(true) }
                .opacity(tabDrag?.id == tab.id ? 0 : 1)
                .background(frameReporter(tab.id))
                .simultaneousGesture(tabDragGesture(tab.id, fromFavorites: false))
        } else {
            ChromiumTabRow(model: model, tab: tab)
        }
    }

    private func draggedTab(_ id: Int) -> ChromiumTab? {
        favorites.first { $0.id == id } ?? model.snapshot.tabs.first { $0.id == id }
    }

    /// The dragged tab follows the pointer above everything else, so it stays
    /// visible outside the (clipped) tab list.
    @ViewBuilder private var dragOverlay: some View {
        if let drag = tabDrag, let tab = draggedTab(drag.id) {
            if let line = dropIndicator {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor)
                    .frame(width: line.width, height: line.height).offset(x: line.minX, y: line.minY)
            }
            Group {
                if drag.fromFavorites { FavoriteTile(model: model, tab: tab) }
                else { ChromiumTabRow(model: model, tab: tab) }
            }
            .frame(width: drag.size.width, height: drag.size.height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .scaleEffect(1.02)
            .opacity(drag.dropped ? 0 : 1)
            .offset(x: drag.pointer.x - drag.grab.width, y: drag.pointer.y - drag.grab.height)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private enum DropZone: String { case favorites, pinned, unpinned }

    private var dropZone: DropZone? { tabDrag.flatMap { $0.splitSide == nil ? dropTarget(for: $0).zone : nil } }

    /// Dragging a tab out of the sidebar onto the page opens it beside the
    /// active tab, on the half it is dropped on. Favorites and the tabs
    /// already on screen cannot be split.
    private func splitSide(for drag: TabDrag) -> SplitDropController.Side? {
        guard !drag.fromFavorites, let tab = draggedTab(drag.id), !tab.active, tab.splitActive != true,
              model.snapshot.tabs.contains(where: { $0.active }) else {
            model.splitDrop.end()
            return nil
        }
        return model.splitDrop.update(from: model.hostView, floating: floating,
                                      title: tab.title.isEmpty || tab.isBlank ? "New tab" : tab.title)
    }

    /// Where the dragged tab would land, and before which tab (nil for the
    /// end of that zone).
    private func dropTarget(for drag: TabDrag) -> (zone: DropZone, before: Int?) {
        let pointer = drag.pointer
        if !model.isIncognito {
            let favoritesBottom = favorites.isEmpty ? tabFrames[Self.addressKey]?.maxY : tabFrames[Self.gridKey].map { $0.maxY + 7 }
            if let favoritesBottom, pointer.y < favoritesBottom {
                for tab in favorites where tab.id != drag.id {
                    guard let frame = tabFrames[tab.id] else { continue }
                    if pointer.y < frame.minY || (pointer.y <= frame.maxY && pointer.x < frame.midX) { return (.favorites, tab.id) }
                }
                return (.favorites, nil)
            }
        }
        // In the list, a row lands by its center; a tile by the pointer.
        let y = drag.fromFavorites ? pointer.y : pointer.y - drag.grab.height + drag.size.height / 2
        // Above the "New tab" row is the pinned list; with nothing else
        // pinned, the upper half of that row is the place to pin.
        let newTab = tabFrames[Self.newTabKey]
        let othersPinned = model.snapshot.tabs.contains { $0.pinned && $0.id != drag.id }
        let boundary = (othersPinned ? newTab?.minY : newTab?.midY) ?? -.infinity
        let pinned = y < boundary
        for tab in model.snapshot.tabs where tab.pinned == pinned && tab.id != drag.id {
            if let frame = tabFrames[tab.id], y < frame.midY { return (pinned ? .pinned : .unpinned, tab.id) }
        }
        return (pinned ? .pinned : .unpinned, nil)
    }

    /// The accent line showing where the dragged tab will land.
    private var dropIndicator: CGRect? {
        guard let drag = tabDrag, !drag.dropped, drag.splitSide == nil else { return nil }
        let target = dropTarget(for: drag)
        if target.zone == .favorites {
            if let before = target.before, let frame = tabFrames[before] {
                return CGRect(x: frame.minX - 4, y: frame.minY + 6, width: 2, height: frame.height - 12)
            }
            guard let last = favorites.last(where: { $0.id != drag.id }), let frame = tabFrames[last.id] else { return nil }
            return CGRect(x: frame.maxX + 2, y: frame.minY + 6, width: 2, height: frame.height - 12)
        }
        let pinned = target.zone == .pinned
        func line(_ y: CGFloat, _ frame: CGRect) -> CGRect { CGRect(x: frame.minX + 4, y: y - 1, width: frame.width - 8, height: 2) }
        if let before = target.before, let frame = tabFrames[before] { return line(frame.minY - 1.5, frame) }
        if let last = model.snapshot.tabs.last(where: { $0.pinned == pinned && $0.id != drag.id }), let frame = tabFrames[last.id] {
            return line(frame.maxY + 1.5, frame)
        }
        if pinned { return nil }  // The "New tab" row highlights instead.
        return tabFrames[Self.newTabKey].map { line($0.maxY + 1.5, $0) }
    }

    private func tabDragGesture(_ id: Int, fromFavorites: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                if tabDrag?.id == id, tabDrag?.dropped == false {
                    tabDrag?.pointer = value.location
                } else {
                    let frame = tabFrames[id] ?? CGRect(origin: value.startLocation, size: CGSize(width: 200, height: 36))
                    tabDrag = TabDrag(id: id, fromFavorites: fromFavorites,
                                      grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                                      size: frame.size, pointer: value.location)
                }
                if let drag = tabDrag { tabDrag?.splitSide = splitSide(for: drag) }
            }
            .onEnded { value in
                guard var drag = tabDrag, drag.id == id, !drag.dropped else { model.splitDrop.end(); return }
                drag.pointer = value.location
                let side = splitSide(for: drag)
                model.splitDrop.end()
                drag.splitSide = nil
                drag.dropped = true
                if let side {
                    withAnimation(.easeOut(duration: 0.12)) { tabDrag = drag }
                    model.send("splitTab", id: id, text: side.rawValue)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settleTabDrag(id) }
                    return
                }
                let target = dropTarget(for: drag)
                withAnimation(.easeOut(duration: 0.12)) { tabDrag = drag }
                model.send("moveTab", id: id, metadata: ["zone": target.zone.rawValue,
                                                         "before": target.before.map(String.init) ?? ""])
                // The tab reappears in its new place when Chromium's new order
                // arrives (see tabOrder), or here if nothing changed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settleTabDrag(id) }
            }
    }

    private var tabOrder: String {
        (favorites.map { "f\($0.id)" } + model.snapshot.tabs.map { "\($0.id)\($0.pinned ? "p" : "")" }).joined(separator: ",")
    }

    private func settleTabDrag(_ id: Int? = nil) {
        guard let drag = tabDrag, drag.dropped, id == nil || drag.id == id else { return }
        withAnimation(.easeOut(duration: 0.15)) { tabDrag = nil }
    }

    // MARK: Archive

    private struct ArchiveNotice: Equatable {
        let id = UUID()
        let count: Int
    }

    // Archiving is one click, so it offers an immediate way back.
    private func archiveTabs() {
        // Blank tabs are closed but not kept, so they cannot be restored.
        let count = model.snapshot.tabs.filter { !$0.pinned && !$0.isBlank }.count
        model.send("archiveTabs")
        guard !model.isIncognito, count > 0 else { return }
        let notice = ArchiveNotice(count: count)
        withAnimation(.easeOut(duration: 0.15)) { archiveNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if archiveNotice == notice { withAnimation(.easeOut(duration: 0.2)) { archiveNotice = nil } }
        }
    }

    private func archiveBanner(_ notice: ArchiveNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(notice.count == 1 ? "Archived 1 tab" : "Archived \(notice.count) tabs")
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") {
                model.send("undoArchive")
                withAnimation(.easeOut(duration: 0.15)) { archiveNotice = nil }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Undo archiving tabs")
        }.padding(.horizontal, 11).frame(height: 34)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .contain)
    }

    /// A modal confirmation that keeps a floating sidebar open while shown.
    private func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        model.presentingSidebarUI = true
        defer { model.presentingSidebarUI = creatingProfile || settingsSpace != nil || draft != nil }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Button { model.send("siteInfo") } label: {
                Image(systemName: ["warning", "dangerous"].contains(model.snapshot.securityLevel ?? "") ? "exclamationmark.triangle" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium)).frame(width: 24, height: 28)
            }.buttonStyle(SidebarButtonStyle())
                .foregroundStyle(model.snapshot.securityLevel == "dangerous" ? Color.red : model.snapshot.securityLevel == "warning" ? Color.orange : Color.secondary)
                .help("Site information and permissions").accessibilityLabel("Site information")
                .accessibilityValue(model.snapshot.securityDescription ?? "")
                .disabled(!model.snapshot.tabs.contains(where: { $0.active }))
            Button { model.focusAddress() } label: {
                Text(model.addressSummary.isEmpty ? "Search or enter address" : model.addressSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(model.addressSummary.isEmpty ? .tertiary : .primary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).frame(minWidth: 0, maxWidth: .infinity)
                .help("Edit address (⌘L)").accessibilityLabel("Address")
                .accessibilityValue(model.address)
            Button { model.send("extensionMenu") } label: {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 12)).frame(width: 24, height: 28)
            }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                .help("Extensions").accessibilityLabel("Extensions")
        }.padding(.horizontal, 7).frame(height: 36)
            .background(Color.primary.opacity(model.editingAddress ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(model.editingAddress ? 0.13 : 0), lineWidth: 1) }
    }

    // Shown while downloading (with progress) and briefly after a download
    // finishes. Opens chrome://downloads.
    private func downloadButton(_ downloads: ChromiumDownloads) -> some View {
        let label = downloads.active > 0
            ? (downloads.active == 1 ? "1 download in progress" : "\(downloads.active) downloads in progress")
            : "Download finished"
        return Button { model.send("downloads") } label: {
            ZStack {
                if downloads.active > 0 {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    if downloads.progress >= 0 {
                        Circle().trim(from: 0, to: max(0.03, downloads.progress))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.4), value: downloads.progress)
                    }
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
                } else {
                    Image(systemName: "checkmark.circle").font(.system(size: 14))
                }
            }.frame(width: 18, height: 18).frame(width: 28, height: 30)
        }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
            .help(label).accessibilityLabel("Downloads").accessibilityValue(label)
    }

    private var spaceDock: some View {
        HStack(spacing: 6) {
            Menu {
                Button("History") { model.send("history") }
                Button("Downloads") { model.send("downloads") }
                if !model.isIncognito {
                    Menu("Archived Tabs") {
                        let archived = model.snapshot.archivedTabs ?? []
                        if archived.isEmpty {
                            Text("No archived tabs in this space")
                        } else {
                            ForEach(Array(archived.enumerated()), id: \.offset) { index, tab in
                                Button(tab.displayTitle) { model.send("restoreArchived", id: index) }
                            }
                            Divider()
                            Button("Restore All") { archiveNotice = nil; model.send("restoreAllArchived") }
                            Button("Clear Archive…") {
                                if confirm("Clear this space's archive?",
                                           archived.count == 1 ? "1 archived tab will be removed. This cannot be undone."
                                                               : "\(archived.count) archived tabs will be removed. This cannot be undone.",
                                           button: "Clear") {
                                    archiveNotice = nil
                                    model.send("clearArchive")
                                }
                            }
                        }
                    }
                }
                Button("Extensions") { model.send("extensions") }
                Button("Settings") { model.send("settings") }
                Button("Keyboard Shortcuts") { ShortcutGuide.shared.show() }
                Divider()
                Button("New profile…") { profileName = ""; creatingProfile = true }
                if !model.isIncognito {
                    Divider()
                    // An inline picker shows a checkmark on the current mode.
                    Picker("Appearance", selection: Binding(
                        get: { model.snapshot.appearance ?? "system" },
                        set: { model.send("appearance", text: $0) })) {
                        Text("System appearance").tag("system")
                        Text("Light appearance").tag("light")
                        Text("Dark appearance").tag("dark")
                    }.pickerStyle(.inline).labelsHidden()
                }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)).frame(width: 28, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).accessibilityLabel("Library and settings")
            if let downloads = model.snapshot.downloads, downloads.active > 0 || downloads.recent {
                downloadButton(downloads)
            }
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.snapshot.spaces) { space in
                        Button { model.send("space", text: space.id) } label: {
                            Text(model.emoji(for: space)).font(.system(size: 11)).frame(width: 28, height: 28)
                                .opacity(space.active ? 1 : 0.50)
                                .background(Color.primary.opacity(space.active ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(SidebarButtonStyle()).help(space.displayName).accessibilityLabel("Space " + space.displayName)
                            .accessibilityValue(space.active ? "Selected" : "")
                            .contextMenu { spaceMenu(for: space) }
                            .disabled(model.snapshot.switchingSpace == true)
                    }
                }
            }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: newSpace) { Image(systemName: "plus").font(.system(size: 14)).frame(width: 28, height: 30) }
                .buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary).help("New space").accessibilityLabel("New space")
        }
    }

    @ViewBuilder private func spaceMenu(for space: ChromiumSpace) -> some View {
        Button("Space settings…") { showSettings(for: space) }
        colorMenu(for: space)
        profileMenu(for: space)
        Divider()
        Button("Manage spaces…") { model.send("manageSpaces") }
        // Every profile keeps at least one space.
        Button("Delete space…") { confirmDelete(space) }.disabled(!model.canDelete(space))
    }

    private func confirmDelete(_ space: ChromiumSpace) {
        let profile = model.snapshot.profiles?.first { $0.id == space.profile }?.name
        if confirm("Delete “\(space.displayName)”?",
                   "The space is removed from the sidebar. Its open tabs move to another space"
                       + (profile.map { " in the “\($0)” profile." } ?? " of its profile."),
                   button: "Delete") {
            model.send("deleteSpace", text: space.id)
        }
    }

    private func showSettings(for space: ChromiumSpace) {
        settingsProfileID = space.profile ?? model.snapshot.profileId ?? ""
        settingsSpace = SpaceSettingsTarget(space: space)
    }

    // Shows the space's profile, and moves the space to another one.
    @ViewBuilder private func profileMenu(for space: ChromiumSpace) -> some View {
        let profiles = model.snapshot.profiles ?? []
        let current = profiles.first { $0.id == space.profile }?.name ?? "Unknown"
        if profiles.count > 1 {
            Menu("Profile: " + current) {
                ForEach(profiles) { profile in
                    Button((profile.id == space.profile ? "✓ " : "") + profile.name) {
                        if profile.id != space.profile { confirmProfileChange(space, to: profile) }
                    }
                }
            }
        } else {
            Text("Profile: " + current)
        }
    }

    private func confirmProfileChange(_ space: ChromiumSpace, to profile: ChromiumProfile) {
        if confirm("Move “\(space.displayName)” to \(profile.name)?",
                   "This space's tabs will reopen in \(profile.name). Sign-ins and site data stay with the current profile.",
                   button: "Move") {
            model.moveSpace(space, toProfile: profile.id)
        }
    }

    private func colorMenu(for space: ChromiumSpace) -> some View {
        let current = space.active ? model.theme : SpaceTheme(rawValue: space.theme ?? "gray") ?? .gray
        return Menu("Color") {
            ForEach(SpaceTheme.allCases, id: \.self) { theme in
                Button((theme == current ? "✓ " : "") + theme.label) { model.customize(space, theme: theme) }
            }
        }
    }
    private func newSpace() {
        draftProfileID = model.snapshot.profileId ?? model.snapshot.profiles?.first?.id ?? ""
        draft = SpaceDraft()
    }
}

// Observe the window edge and give the empty header a native drag surface.
// Button hit targets and web-page clicks are left to their own views.
@MainActor private final class ChromiumHeaderHostingView: NSHostingView<ChromiumSidebarHeader> {
    let model: ChromiumSidebarModel
    private var monitor: Any?
    private var hideWork: DispatchWorkItem?
    private var requestedReveal = false
    private var trackingMenus = 0
    private weak var trackedContent: NSView?
    private var trackingArea: NSTrackingArea?
    private var lastGeometryReport = ""
    private var windowDragStart: (pointer: NSPoint, origin: NSPoint)?
    init(model: ChromiumSidebarModel) {
        self.model = model
        super.init(rootView: ChromiumSidebarHeader(model: model))
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }
    // Chromium already places this host inside its caption row. Applying the
    // window titlebar inset again would move the Swift controls out of line.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview, isWindowDragPoint(superview.convert(point, to: nil)) {
            return self
        }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard isWindowDragPoint(event.locationInWindow), let window else {
            super.mouseDown(with: event)
            return
        }
        // Chromium forwards events through its own frame view. Track the
        // AppKit drag here instead of asking that frame to start another loop.
        windowDragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = windowDragStart, let window, window.isMovable else {
            super.mouseDragged(with: event)
            return
        }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                      y: start.origin.y + pointer.y - start.pointer.y))
    }
    override func mouseUp(with event: NSEvent) {
        if windowDragStart != nil { windowDragStart = nil }
        else { super.mouseUp(with: event) }
    }
    @available(*, unavailable) required init(rootView: ChromiumSidebarHeader) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        if let content = window.contentView {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            content.addTrackingArea(area)
            trackedContent = content
            trackingArea = area
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResignedActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)),
                                               name: NSWindow.didMoveNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseDown { self.reportHeaderHit(event.locationInWindow) }
            self.trackPointer(event.locationInWindow)
            return event
        }
    }
    override func layout() {
        super.layout()
        reportWindowGeometry()
    }
    @objc private func windowGeometryChanged(_ notification: Notification) { reportWindowGeometry() }
    @objc private func windowBecameKey(_ notification: Notification) { model.send("hostActivated") }
    private func reportHeaderHit(_ point: NSPoint) {
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report"), let window else { return }
        let local = convert(point, from: nil)
        guard local.y >= -10, local.y <= bounds.height + 10 else { return }
        let report: [String: Any] = ["localX": local.x, "localY": local.y,
                                    "headerWidth": bounds.width, "headerHeight": bounds.height,
                                    "movable": window.isMovable, "drag": isWindowDragPoint(point)]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data(("BARK_UI_HEADER_HIT " + json + "\n").utf8))
        }
    }
    private func reportWindowGeometry() {
        // Opt-in validation of the real window, including movement and native
        // caption-button alignment. No profile or page data is recorded.
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report"),
              let window, bounds.width > 0 else { return }
        let header = convert(bounds, to: nil)
        let centers = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            window.standardWindowButton(type).map { $0.convert($0.bounds, to: nil).midY }
        }
        let report: [String: Any] = ["originX": window.frame.minX, "originY": window.frame.minY,
                                    "width": window.frame.width, "height": window.frame.height,
                                    "headerCenterY": header.midY, "trafficLightCentersY": centers]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8), json != lastGeometryReport else { return }
        lastGeometryReport = json
        FileHandle.standardError.write(Data(("BARK_UI_GEOMETRY " + json + "\n").utf8))
    }
    private func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, model.snapshot.sidebarCollapsed != true else { return false }
        let local = convert(point, from: nil)
        // The header host starts after the traffic lights. Keep its collapse
        // button and the three navigation controls fully interactive.
        guard local.x >= 0, local.x < bounds.width,
              local.y >= -4, local.y < bounds.height + 4 else { return false }
        if local.y < 0 || local.y >= bounds.height { return true }
        return local.x >= (model.isIncognito ? 54 : 28) && local.x < bounds.width - 80
    }
    @objc private func applicationResignedActive(_ notification: Notification) {
        // Dismiss on app switching, but keep native menus and popovers anchored.
        windowDragStart = nil
        dismissReveal()
    }
    @objc private func menuBeganTracking(_ notification: Notification) {
        trackingMenus += 1
        hideWork?.cancel(); hideWork = nil
    }
    @objc private func menuEndedTracking(_ notification: Notification) {
        trackingMenus = max(0, trackingMenus - 1)
        if trackingMenus == 0, let window { trackPointer(window.mouseLocationOutsideOfEventStream) }
    }
    func stopObserving() {
        windowDragStart = nil
        hideWork?.cancel(); hideWork = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let trackingArea { trackedContent?.removeTrackingArea(trackingArea); self.trackingArea = nil }
        trackedContent = nil
        NotificationCenter.default.removeObserver(self)
        trackingMenus = 0
    }
    private func trackPointer(_ point: NSPoint) {
        guard model.snapshot.sidebarCollapsed == true, window?.isKeyWindow == true else {
            hideWork?.cancel(); requestedReveal = false; return
        }
        if trackingMenus > 0 || model.presentingSidebarUI { hideWork?.cancel(); hideWork = nil; return }
        let revealed = requestedReveal || model.snapshot.sidebarRevealed == true
        let within = point.x >= 0 && point.x <= (revealed ? (model.snapshot.sidebarWidth ?? 260) + 10 : 7)
        if within {
            hideWork?.cancel(); hideWork = nil
            if !revealed { requestedReveal = true; model.send("revealSidebar", text: "true") }
        } else if revealed && hideWork == nil && !model.editingAddress {
            scheduleDismissal()
        }
    }
    override func mouseExited(with event: NSEvent) {
        if model.snapshot.sidebarCollapsed == true && !model.editingAddress && !model.presentingSidebarUI && trackingMenus == 0 { scheduleDismissal() }
    }
    private func scheduleDismissal() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissReveal() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func dismissReveal() {
        hideWork?.cancel(); hideWork = nil
        let wasRevealed = requestedReveal || model.snapshot.sidebarRevealed == true
        requestedReveal = false
        if wasRevealed { model.send("revealSidebar", text: "false") }
    }
    deinit {
        hideWork?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        // The main-thread ABI detaches tracking before releasing this view.
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor private final class ChromiumHostingView: NSHostingView<ChromiumSidebar> {
    let model: ChromiumSidebarModel
    private enum SwipeState { case idle, undecided(CGSize), horizontal, passthrough }
    private var swipe: SwipeState = .idle
    private var swallowMomentum = false
    private var lastFingerDelta: CGFloat = 0
    private var scrollMonitor: Any?
    private let addressBar: AddressBarController
    init(context: UnsafeMutableRawPointer?, callback: ChromiumCommand?) {
        let model = ChromiumSidebarModel(context: context, callback: callback)
        self.model = model
        addressBar = AddressBarController(model: model)
        super.init(rootView: ChromiumSidebar(model: model))
        // Chromium sets this view's frame; the content must never resize it.
        sizingOptions = []
        model.hostView = self
        ShortcutMonitor.shared.install()
        ShortcutGuide.shared.installHelpMenuItem()
        model.presentAddressBar = { [weak self] in
            guard let self else { return }
            self.addressBar.show(over: self.window)
        }
        // A local monitor sees trackpad scrolls before the tab list's vertical
        // ScrollView, so a horizontal gesture can be claimed for the whole sidebar.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event) ? nil : event
        }
    }
    @available(*, unavailable) required init(rootView: ChromiumSidebar) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func focusAddress() {
        model.focusAddress()
    }

    /// The sidebar model of a browser window, if it has a sidebar.
    static func model(in window: NSWindow) -> ChromiumSidebarModel? {
        func find(_ view: NSView) -> ChromiumHostingView? {
            if let host = view as? ChromiumHostingView { return host }
            for child in view.subviews { if let host = find(child) { return host } }
            return nil
        }
        return window.contentView.flatMap(find)?.model
    }

    func stopTracking() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        model.presentAddressBar = nil
        model.splitDrop.end()
        addressBar.tearDown()
    }

    /// Returns true when the event belongs to a space swipe and is consumed.
    private func handleScroll(_ event: NSEvent) -> Bool {
        // Events normally name their window. Without one, the location is in
        // screen coordinates; use the window under it.
        let eventWindow = event.window ?? NSApp.window(withWindowNumber:
            NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
        guard let window, eventWindow === window else { return false }
        let locationInWindow = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        // Trailing momentum after a swipe must not scroll the tab list.
        if !event.momentumPhase.isEmpty {
            guard swallowMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return true
        }
        // Only phased trackpad gestures; classic mouse wheels scroll normally.
        guard !event.phase.isEmpty, event.hasPreciseScrollingDeltas else { return false }
        // Content follows the fingers regardless of the natural-scrolling setting.
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerY = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            swallowMomentum = false
            let inside = !isHiddenOrHasHiddenAncestor && bounds.contains(convert(locationInWindow, from: nil))
            swipe = inside && model.canSwipeSpaces ? .undecided(.zero) : .passthrough
            if event.phase.contains(.mayBegin) { return false }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { swipe = .idle }
            guard case .horizontal = swipe else { return false }
            model.endSpaceSwipe(velocity: lastFingerDelta, width: bounds.width, cancelled: event.phase.contains(.cancelled))
            swallowMomentum = true
            return true
        }
        switch swipe {
        case .undecided(var total):
            total.width += fingerX; total.height += fingerY
            guard hypot(total.width, total.height) >= 6 else { swipe = .undecided(total); return false }
            // Decide once per gesture; a mostly vertical start keeps scrolling tabs.
            guard abs(total.width) > abs(total.height) * 1.3 else { swipe = .passthrough; return false }
            swipe = .horizontal
            model.beginSpaceSwipe()
            lastFingerDelta = total.width
            model.updateSpaceSwipe(by: total.width, width: bounds.width)
            return true
        case .horizontal:
            if fingerX != 0 { lastFingerDelta = fingerX }
            model.updateSpaceSwipe(by: fingerX, width: bounds.width)
            return true
        case .idle, .passthrough:
            return false
        }
    }
}

// MARK: Split view drop target

/// Highlights the half of the page where a dragged sidebar tab would open in
/// a split view. The sidebar's own view is clipped to its bounds, so the
/// highlight is a transparent child window over the page.
@MainActor final class SplitDropController {
    enum Side: String { case left, right }
    private var panel: NSPanel?
    private var label: NSTextField?
    private weak var parent: NSWindow?

    /// The page area of `window` in screen coordinates: everything beside the
    /// sidebar, below the titlebar strip. A collapsed sidebar floats over the
    /// page, which then spans the window.
    static func pageRect(window: NSRect, sidebar: NSRect, floating: Bool) -> NSRect {
        let left = floating ? window.minX : min(max(sidebar.maxX, window.minX), window.maxX)
        let top = min(max(sidebar.maxY, window.minY), window.maxY)
        return NSRect(x: left, y: window.minY, width: window.maxX - left, height: top - window.minY)
    }

    static func side(at point: NSPoint, page: NSRect, sidebar: NSRect) -> Side? {
        guard page.width >= 200, page.contains(point), !sidebar.contains(point) else { return nil }
        return point.x < page.midX ? .left : .right
    }

    /// Call while dragging. Returns the half under the pointer, or nil when
    /// the pointer is not over the page.
    func update(from view: NSView?, floating: Bool, title: String) -> Side? {
        guard let view, let window = view.window else { end(); return nil }
        let sidebar = window.convertToScreen(view.convert(view.bounds, to: nil))
        let page = Self.pageRect(window: window.frame, sidebar: sidebar, floating: floating)
        guard let side = Self.side(at: NSEvent.mouseLocation, page: page, sidebar: sidebar) else { end(); return nil }
        var half = page
        half.size.width = page.width / 2
        if side == .right { half.origin.x = page.midX }
        show(half.insetBy(dx: 6, dy: 6), over: window, title: title)
        return side
    }

    func end() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
    }

    private func show(_ frame: NSRect, over window: NSWindow, title: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = "Split with " + title
        panel.setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 2
        content.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        content.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        panel.contentView = content
        self.label = label
        return panel
    }
}

// MARK: Keyboard shortcuts

/// Arc's default shortcuts that differ from Chromium's. One table drives both
/// the key handling and the guide in the Help menu.
struct BarkShortcut {
    enum Action: Equatable {
        case toggleSidebar, togglePin, copyURL, copyMarkdown, archiveTabs
        case nextTab, previousTab, nextSpace, previousSpace
        case tab(Int), space(Int)
        case addSplit, closeSplit
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
            BarkShortcut(action: .toggleSidebar, key: .character("s"), modifiers: .command, keys: "⌘ S", title: "Show or hide the sidebar", section: "Sidebar and tabs"),
            BarkShortcut(action: .togglePin, key: .character("d"), modifiers: .command, keys: "⌘ D", title: "Pin or unpin the current tab", section: "Sidebar and tabs"),
            BarkShortcut(action: .copyURL, key: .character("c"), modifiers: [.command, .shift], keys: "⇧ ⌘ C", title: "Copy the page's link", section: "Sidebar and tabs"),
            BarkShortcut(action: .copyMarkdown, key: .character("c"), modifiers: [.command, .shift, .option], keys: "⌥ ⇧ ⌘ C", title: "Copy the page's link as Markdown", section: "Sidebar and tabs"),
            BarkShortcut(action: .archiveTabs, key: .character("k"), modifiers: [.command, .shift], keys: "⇧ ⌘ K", title: "Archive this space's unpinned tabs", section: "Sidebar and tabs"),
            BarkShortcut(action: .nextTab, key: .code(125), modifiers: [.command, .option], keys: "⌥ ⌘ ↓", title: "Next tab in the sidebar", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .previousTab, key: .code(126), modifiers: [.command, .option], keys: "⌥ ⌘ ↑", title: "Previous tab in the sidebar", section: "Sidebar and tabs", repeats: true),
            BarkShortcut(action: .tab(1), key: .character("1"), modifiers: .command, keys: "⌘ 1 – 9", title: "Go to that tab, counting from the top of the sidebar", section: "Sidebar and tabs"),
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

    /// Chromium shortcuts that already match Arc's, listed in the guide.
    static let builtIn: [(keys: String, title: String)] = [
        ("⌘ T", "New tab"), ("⌘ L", "Edit the address"), ("⌘ W", "Close the tab"),
        ("⇧ ⌘ T", "Reopen the last closed tab"), ("⌃ Tab", "Next tab"), ("⌃ ⇧ Tab", "Previous tab"),
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
/// and the page see them, as Arc does.
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
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              let model = ChromiumHostingView.model(in: window),
              let shortcut = BarkShortcut.match(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                                modifiers: event.modifierFlags) else { return false }
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
                Text("Bark uses Arc's shortcuts. Press the keys shown while a browser window is in front.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Self.sections, id: \.self) { section in
                    group(section, BarkShortcut.all.filter { $0.section == section }.map { ($0.keys, $0.title) })
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Split view with the mouse").font(.system(size: 13, weight: .semibold))
                    Text("Drag a tab from the sidebar onto the left or right half of the page to open it beside the current tab. Drag the divider to resize the halves. To go back to two separate tabs, right-click either tab and choose Separate Split View.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                group("Also the same as Arc", BarkShortcut.builtIn.map { ($0.keys, $0.title) })
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

// Main-thread-only ABI. C++ detaches the native host before releasing this
// retained view, and shuts down its callback before destroying the controller.
@_cdecl("BarkSwiftSidebarCreate")
@MainActor func barkSwiftSidebarCreate(_ context: UnsafeMutableRawPointer?, _ callback: ChromiumCommand?) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(ChromiumHostingView(context: context, callback: callback)).toOpaque()
}

@_cdecl("BarkSwiftSidebarUpdate")
@MainActor func barkSwiftSidebarUpdate(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.update(String(cString: json))
}

@_cdecl("BarkSwiftSidebarDestroy")
@MainActor func barkSwiftSidebarDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeRetainedValue()
    view.stopTracking()
    view.model.shutdown()
}

@_cdecl("BarkSwiftSidebarSuggestions")
@MainActor func barkSwiftSidebarSuggestions(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.updateSuggestions(String(cString: json))
}

@_cdecl("BarkSwiftSidebarFocusAddress")
@MainActor func barkSwiftSidebarFocusAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().focusAddress()
}

@_cdecl("BarkSwiftSidebarHeaderCreate")
@MainActor func barkSwiftSidebarHeaderCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(ChromiumHeaderHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarHeaderDestroy")
@MainActor func barkSwiftSidebarHeaderDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<ChromiumHeaderHostingView>.fromOpaque(handle).takeRetainedValue()
    view.stopObserving()
}
