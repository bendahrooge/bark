import AppKit
import Combine
import SwiftUI
import BarkCore

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
    var faviconValid: Bool? = nil
    var space: String? = nil
    var commandID: String? = nil
    var detail: String? = nil
    var symbol: String? = nil
    var contextURL: String? = nil
    var contextSpace: String? = nil
    var invokerID: Int? = nil
    var invokerURL: String? = nil
    var isTab: Bool { kind == "tab" }
    var isCommand: Bool { kind == "command" && commandID != nil }
    var listID: String { kind + ":" + (commandID ?? id.map(String.init) ?? url) }
}

private struct AddressSuggestions: Decodable {
    let query: String
    let items: [AddressSuggestion]
    var action: String? = nil
    var searchEngine: String? = nil
}

enum AddressBarIcon: Equatable {
    case favicon(String), command(String), globe, search
}

enum AddressDisposition {
    case currentTab, newTab
}

@MainActor final class ChromiumSidebarModel: ObservableObject {
    @Published private(set) var snapshot = ChromiumSnapshot(tabs: [], spaces: [], profile: "", canGoBack: false, canGoForward: false)
    @Published var address = ""
    @Published var archivePresented = false
    @Published var editingAddress = false
    private(set) var addressDisposition: AddressDisposition = .currentTab
    @Published var siteControlsOpen = false
    @Published var noticesOpen = false
    // Presents the centered address bar over this sidebar's browser window.
    var presentAddressBar: (() -> Void)?
    // The sidebar's AppKit view, for window geometry and keyboard shortcuts.
    weak var hostView: NSView?
    weak var pageFrameView: NSView?
    weak var tabScrollView: NSScrollView?
    weak var spaceDockScrollView: NSScrollView?
    let splitDrop = SplitDropController()
    // Incremented by the keyboard shortcut; the sidebar archives with undo.
    @Published private(set) var archiveRequests = 0
    @Published private(set) var clearingTabs: [ChromiumTab] = []
    static let clearFadeDuration: TimeInterval = 0.24
    @Published var browserImportRequests = 0
    /// A folder the sidebar should offer to rename as soon as it appears.
    @Published var renameNextFolder = false

    func requestNewFolder(containing tab: Int? = nil) {
        renameNextFolder = true
        send("newFolder", id: tab, text: "New Folder")
    }
    @Published private(set) var suggestions: [AddressSuggestion] = []
    @Published var selectedSuggestion: Int?
    @Published private var addressAction: String?
    @Published private var addressSearchEngine: String?
    private var addressActionQuery: String?
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
        addressActionQuery = result.query
        addressAction = result.action
        addressSearchEngine = result.searchEngine
        suggestions = result.items
        // Keep the highlighted row if it is still present; otherwise clear it.
        selectedSuggestion = previous.flatMap { id in suggestions.firstIndex { $0.listID == id } }
        if selectedSuggestion == nil {
            selectedSuggestion = CommandBarSelection.initialSelection(query: result.query, suggestions: suggestions)
        }
    }

    func clearSuggestions() {
        suggestionQuery = nil
        addressActionQuery = nil
        addressAction = nil
        addressSearchEngine = nil
        suggestions = []
        selectedSuggestion = nil
    }

    func moveSuggestionSelection(by step: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selectedSuggestion ?? -1) + step
        selectedSuggestion = next < 0 ? nil : min(next, suggestions.count - 1)
    }

    /// Commands stay separate from navigation and use the page they described.
    func openSuggestion(_ suggestion: AddressSuggestion, in disposition: AddressDisposition? = nil) {
        if suggestion.isCommand { performCommandBarAction(suggestion) }
        else if suggestion.isTab, let id = suggestion.id { send("switchToTab", id: id) }
        else { submitAddress(suggestion.url, in: disposition) }
    }

    func submitAddress(_ text: String, in disposition: AddressDisposition? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send((disposition ?? addressDisposition) == .newTab ? "navigateNew" : "navigate", text: text)
    }
    var presentingSidebarUI = false
    var draggingTab = false
    var resizingSidebar = false
    @Published var theme: SpaceTheme = .gray
    @Published var emoji = "👤"
    private var callback: ChromiumCommand?
    private let context: UnsafeMutableRawPointer?
    private var previousActiveID: Int?
    private var lastJSON = ""
    // Chromium can activate a tab as soon as the user commits. Keep the
    // outgoing rows and backdrop in place until the sidebar has slid past them.
    private struct SpaceSlide {
        let origin: ChromiumSpace
        let originTabs: [ChromiumTab]
        let theme: SpaceTheme
        let emoji: String
        let target: ChromiumSpace?
        let direction: CGFloat
        let committed: Bool
        let opposite: ChromiumSpace?
        let oppositeTabs: [ChromiumTab]
        let spring: SpaceSpring?
    }

    // A fresh drag can catch a running release spring between SwiftUI updates.
    private struct SpaceSpring {
        let start = ProcessInfo.processInfo.systemUptime
        let from: CGFloat
        let to: CGFloat
        let velocity: CGFloat
        let rate: CGFloat

        var offset: CGFloat {
            let t = CGFloat(ProcessInfo.processInfo.systemUptime - start)
            let distance = from - to
            return to + (distance + (velocity + rate * distance) * t) * exp(-rate * t)
        }
    }

    private struct SpaceDrag {
        let origin: String
        var handoff: String?
        var travel: CGFloat = 0
        var initialOffset: CGFloat?
    }

    @Published private var slide: SpaceSlide?
    @Published private(set) var spaceSwipeOffset: CGFloat = 0
    private var spaceDrag: SpaceDrag?
    private var queuedHandoffSpace: String?
    private var swipeCommitTarget: String? { slide?.committed == true ? slide?.target?.id : nil }
    private var slideLanded = false
    private var swipeResetWork: DispatchWorkItem?
    private static let spaceDragGain: CGFloat = 0.5

    private let reduceSpaceMotion: () -> Bool

    init(context: UnsafeMutableRawPointer?, callback: ChromiumCommand?,
         reduceSpaceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.context = context
        self.callback = callback
        self.reduceSpaceMotion = reduceSpaceMotion
    }

    func update(_ json: String) {
        // Many of Chromium's tab changes leave the sidebar as it is. Those skip
        // decoding and redrawing; the checks below still run on the same state.
        var changedProfile = false
        if json != lastJSON {
            guard let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode(ChromiumSnapshot.self, from: data) else { return }
            lastJSON = json
            changedProfile = decoded.profile != snapshot.profile || decoded.incognito != snapshot.incognito ||
                decoded.activeSpaceId != snapshot.activeSpaceId
            if changedProfile || decoded.archiveGeneration != snapshot.archiveGeneration {
                // Keep the outgoing rows laid out while they fade, including
                // when the scroll view is at the bottom of a long list.
                let cleared = !changedProfile && decoded.archiveGeneration != nil &&
                    decoded.sidebarTabs.allSatisfy(\.pinned)
                clearingTabs = cleared ? snapshot.sidebarTabs.filter { !$0.pinned } : []
                if !clearingTabs.isEmpty {
                    let generation = decoded.archiveGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearFadeDuration) { [weak self] in
                        guard let self, self.snapshot.archiveGeneration == generation else { return }
                        self.clearingTabs = []
                    }
                }
            } else if !clearingTabs.isEmpty && decoded.sidebarTabs.contains(where: { !$0.pinned }) {
                // Undo or opening a tab immediately returns the list to live rows.
                clearingTabs = []
            }
            snapshot = decoded
        }
        if changedProfile || activeSpace?.theme != nil {
            theme = isIncognito ? .gray : SpaceTheme(rawValue: activeSpace?.theme ?? UserDefaults.standard.string(forKey: settingsKey("theme")) ?? "gray") ?? .gray
            let fallback = activeSpace?.displayName == "Personal" || activeSpace == nil ? "👤" : ""
            emoji = isIncognito ? "" : Space.normalizedIcon(activeSpace?.emoji ?? UserDefaults.standard.string(forKey: settingsKey("emoji")) ?? fallback) ?? fallback
        }
        let next = snapshot
        if next.windowVisible == false || isIncognito {
            queuedSpaceSelection = nil
            queuedHandoffSpace = nil
            // AppKit can deliver the last event to the outgoing profile's
            // window after Chromium has already hidden it.
            if isIncognito || spaceDrag?.handoff == nil { spaceDrag = nil }
            if slide != nil || spaceSwipeOffset != 0 { resetSpaceSlide(to: 0) }
        } else if let slide {
            let interrupted = next.activeSpaceId != slide.origin.id && next.activeSpaceId != swipeCommitTarget
            let missingTarget = slide.target.map { target in !next.spaces.contains { $0.id == target.id } } ?? false
            if interrupted || missingTarget {
                queuedSpaceSelection = nil
                queuedHandoffSpace = nil
                spaceDrag = nil
                finishSpaceSwipe()
            } else if let target = swipeCommitTarget, next.activeSpaceId == target {
                if slideLanded {
                    finishSpaceSwipe()
                } else if queuedSpaceSelection?.velocity != nil, spaceDrag == nil, catchSpaceSpring(at: target) {
                    continueQueuedSpaceSelection()
                }
            }
        } else if changedProfile, let drag = spaceDrag, drag.origin != next.activeSpaceId {
            spaceDrag = nil
            finishSpaceSwipe()
        }
        let active = activeTab
        if !editingAddress || (addressDisposition == .currentTab && previousActiveID != active?.id) {
            address = active?.isBlank == true ? "" : active?.url ?? ""
        }
        previousActiveID = active?.id
    }

    private func settingsKey(_ suffix: String) -> String { "BarkChromium.\(snapshot.profile).\(suffix)" }

    func moveSpace(_ space: ChromiumSpace, toProfile profile: String) {
        guard !isIncognito, profile != space.profile else { return }
        send("setSpaceProfile", metadata: ["space": space.id, "profile": profile])
    }

    func saveSpaceSettings(_ space: ChromiumSpace, name: String, theme: SpaceTheme, emoji: String,
                           style: SpaceStyle = SpaceStyle(), profile: String) {
        guard !isIncognito, let emoji = Space.normalizedIcon(emoji) else { return }
        if space.active { self.theme = theme; self.emoji = emoji }
        send("customizeSpace", metadata: ["space": space.id, "name": String(name.prefix(32)),
                                          "theme": theme.rawValue, "emoji": emoji].merging(style.metadata) { $1 })
        if !profile.isEmpty, profile != space.profile { moveSpace(space, toProfile: profile) }
    }

    /// Changes another space's color or emoji without switching to it.
    func customize(_ space: ChromiumSpace, theme: SpaceTheme? = nil, emoji: String? = nil) {
        guard !isIncognito else { return }
        if space.active { customize(theme: theme ?? self.theme, emoji: emoji ?? self.emoji, recolor: theme != nil); return }
        let current = SpaceTheme(rawValue: space.theme ?? "gray") ?? .gray
        var metadata = ["space": space.id, "theme": (theme ?? current).rawValue,
                        "emoji": emoji.flatMap(Space.normalizedIcon) ?? self.emoji(for: space)]
        if let theme, var canvas = space.style.canvas {
            canvas.startColor = theme.accentHex
            metadata["gradientCanvas"] = canvas.json
        }
        send("customizeSpace", metadata: metadata)
    }

    func customize(theme: SpaceTheme, emoji: String, recolor: Bool = true) {
        guard !isIncognito else { return }
        self.theme = theme
        self.emoji = Space.normalizedIcon(emoji) ?? ""
        if snapshot.activeSpaceId != nil {
            var metadata = ["theme": theme.rawValue, "emoji": self.emoji]
            if recolor, var canvas = activeSpace?.style.canvas {
                canvas.startColor = theme.accentHex
                metadata["gradientCanvas"] = canvas.json
            }
            send("customizeSpace", metadata: metadata)
            return
        }
        UserDefaults.standard.set(theme.rawValue, forKey: settingsKey("theme"))
        UserDefaults.standard.set(self.emoji, forKey: settingsKey("emoji"))
    }

    func close(_ tab: ChromiumTab) {
        if tab.pinned {
            send(tab.sessionClosed == true ? "removeClosedPin" : "closePinnedSession", id: tab.id)
        } else {
            send("close", id: tab.id)
        }
    }

    func send(_ action: String, id: Int? = nil, text: String? = nil, width: Double? = nil, metadata: [String: String]? = nil) {
        if isIncognito && ["space", "createSpace", "deleteSpace", "manageSpaces", "moveTabToSpace", "createProfile", "deleteProfile", "customizeSpace", "appearance", "importBrowserData"].contains(action) { return }
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

    /// Keep one sidebar space; profiles may have no visible spaces.
    func canDelete(_ space: ChromiumSpace) -> Bool {
        !isIncognito && snapshot.spaces.count > 1
    }
    /// Other spaces of this window's profile, where a tab can be moved.
    var moveTargets: [ChromiumSpace] {
        isIncognito ? [] : snapshot.spaces.filter { !$0.active && $0.profile != nil && $0.profile == snapshot.profileId }
    }
    var activeTabLoading: Bool {
        (snapshot.tabs + (snapshot.favorites ?? [])).contains { $0.active && $0.loading }
    }

    var activeTab: ChromiumTab? {
        (snapshot.tabs + (snapshot.favorites ?? [])).first { $0.active }
    }

    /// Match the destination that Return will open. Native suggestions carry
    /// the same URL/search classification used by the navigation command.
    var addressBarIcon: AddressBarIcon {
        func siteIcon(_ encoded: String?, valid: Bool?) -> AddressBarIcon {
            if valid != false, let encoded, FaviconCache.image(encoded) != nil { return .favicon(encoded) }
            return .globe
        }
        if let index = selectedSuggestion, suggestions.indices.contains(index) {
            let suggestion = suggestions[index]
            if suggestion.isCommand { return .command(suggestion.symbol ?? "command") }
            return suggestion.kind == "search" ? .search : siteIcon(suggestion.favicon, valid: suggestion.faviconValid)
        }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if CommandBarSelection.isActionQuery(text) { return .command("command") }
        if let active = activeTab, !active.isBlank, text == active.url { return siteIcon(active.favicon, valid: active.faviconValid) }
        if text.isEmpty { return .search }
        guard addressActionQuery == address, addressAction == "navigate" else { return .search }
        // The typed address is the destination: show its favicon when history has one.
        let typed = suggestions.first { $0.kind == "url" }
        return siteIcon(typed?.favicon, valid: typed?.faviconValid)
    }

    /// Names the engine Return will search with, e.g. "Search with Google".
    /// Shown only while typed text (not a highlighted row) is the destination.
    var addressSearchHint: String? {
        guard selectedSuggestion == nil, addressActionQuery == address, addressAction == "search",
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let engine = addressSearchEngine, !engine.isEmpty else { return nil }
        return "Search with \(engine)"
    }

    func emoji(for space: ChromiumSpace) -> String {
        if let emoji = space.emoji { return Space.normalizedIcon(emoji) ?? "" }
        if space.active { return emoji }
        return Space.normalizedIcon(UserDefaults.standard.string(forKey: "BarkChromium.\(space.id).emoji") ?? "") ?? ""
    }

    var sidebarAddress: String { addressDisposition == .newTab ? currentPageAddress : address }

    var addressSummary: String {
        let value = sidebarAddress
        guard !value.isEmpty, let url = URL(string: value), let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return value }
        let origin = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return origin + (url.port.map { ":\($0)" } ?? "")
    }

    func cancelAddressEditing() {
        editingAddress = false
        addressDisposition = .currentTab
        address = currentPageAddress
    }

    private var currentPageAddress: String {
        guard let tab = activeTab, !tab.isBlank else { return "" }
        return tab.url
    }

    func composeAddress() {
        presentAddress(.newTab)
    }

    func focusAddress() {
        presentAddress(.currentTab)
    }

    private func presentAddress(_ disposition: AddressDisposition) {
        addressDisposition = disposition
        editingAddress = true
        address = disposition == .newTab ? "" : currentPageAddress
        presentAddressBar?()
    }

    // MARK: Keyboard shortcuts

    /// Tabs in sidebar order: Favorites, pinned, then the rest.
    private var orderedTabs: [ChromiumTab] {
        let tabs = snapshot.sidebarTabs
        return (isIncognito ? [] : snapshot.favorites ?? []) + tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
    }

    func perform(_ action: BarkShortcut.Action) {
        let tabs = orderedTabs
        let active = tabs.first { $0.active }
        let spaces = snapshot.spaces
        switch action {
        case .newLittleWindow: if !isIncognito { send("newLittleWindow") }
        case .toggleSidebar: send("toggleSidebar")
        case .undoOrganization: if snapshot.organizationUndoLabel != nil { send("undoOrganization") }
        case .togglePin:
            // Favorites stay where they are; unpinning one would drop it into a space.
            if !isIncognito, let tab = snapshot.sidebarTabs.first(where: { $0.active }) { send("pin", id: tab.id) }
        case .copyURL, .copyMarkdown:
            guard let active, !active.isBlank else { return }
            copyLink(active, markdown: action == .copyMarkdown)
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
        case .recentTab, .recentTabReverse: break  // Handled with the window by ShortcutMonitor.
        case .archiveTabs:
            if !isIncognito, snapshot.sidebarTabs.contains(where: { !$0.pinned }) { archiveRequests += 1 }
        }
    }

    func shutdown() {
        PreferencesPresenter.shared.detach(self)
        callback = nil
        swipeResetWork?.cancel()
        if RecentTabSwitcher.shared.isShowing(for: self) { RecentTabSwitcher.shared.end() }
    }

    /// Copies a tab's link (or a Markdown link to it) and confirms with a toast.
    func copyLink(_ tab: ChromiumTab, markdown: Bool = false) {
        guard !tab.isBlank else { return }
        let title = tab.displayTitle.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        ToastPresenter.shared.copyLink(markdown ? "[\(title)](\(tab.url))" : tab.url, markdown: markdown,
                                      over: hostView?.window, tint: theme.accent)
    }

    /// The tab list Chromium sent for the Control-Tab switcher.
    func updateSwitcher(_ json: String) {
        struct Switcher: Decodable { let tabs: [ChromiumTab] }
        guard let data = json.data(using: .utf8), let switcher = try? JSONDecoder().decode(Switcher.self, from: data) else { return }
        RecentTabSwitcher.shared.receive(switcher.tabs, from: self)
    }

    /// A space's dot: its own color.
    func tint(for space: ChromiumSpace) -> Color { space.active ? theme.accent : space.themeValue.accent }
    var folders: [ChromiumFolder] { isIncognito ? [] : activeSpace?.folders ?? [] }

    private var queuedSpaceSelection: (id: String, velocity: CGFloat?)?

    /// A different profile takes over this window when its slide finishes.
    var switchingSpaceProfile: Bool {
        if snapshot.switchingSpace == true { return true }
        guard let swipeCommitTarget,
              let profile = snapshot.spaces.first(where: { $0.id == swipeCommitTarget })?.profile else { return false }
        return profile != snapshot.profileId
    }

    func requestSpaceSelection(_ space: ChromiumSpace, width: CGFloat? = nil) {
        guard !isIncognito, !switchingSpaceProfile,
              let destination = snapshot.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        if let swipeCommitTarget {
            // Keep the latest click, including a click back to the outgoing Space.
            queuedSpaceSelection = space.id == swipeCommitTarget ? nil : (space.id, nil)
            return
        }
        guard let source = activeSpaceIndex else { send("space", text: space.id); return }
        guard source != destination else { return }
        let pageWidth = width ?? hostView?.bounds.width ?? CGFloat(snapshot.sidebarWidth ?? 260)
        guard pageWidth > 0 else { send("space", text: space.id); return }
        settleSpace(to: snapshot.spaces[destination], direction: destination > source ? -1 : 1,
                    width: pageWidth, velocity: 0, fromClick: true)
    }

    private func continueQueuedSpaceSelection() {
        guard let queued = queuedSpaceSelection else { return }
        queuedSpaceSelection = nil
        guard snapshot.windowVisible != false, let source = activeSpaceIndex,
              let destination = snapshot.spaces.firstIndex(where: { $0.id == queued.id }), source != destination else { return }
        let target = snapshot.spaces[destination]
        if let velocity = queued.velocity {
            let width = hostView?.bounds.width ?? CGFloat(snapshot.sidebarWidth ?? 260)
            settleSpace(to: target, direction: destination > source ? -1 : 1, width: width,
                        velocity: velocity, fromClick: false)
        } else {
            requestSpaceSelection(target)
        }
    }

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
    var outgoingSpace: ChromiumSpace? { slide?.origin ?? activeSpace }
    var outgoingTabs: [ChromiumTab] { slide?.originTabs ?? snapshot.sidebarTabs }
    var outgoingTheme: SpaceTheme { slide?.theme ?? theme }
    var outgoingEmoji: String { slide?.emoji ?? emoji }
    var spaceInMotion: Bool { (slide != nil && !slideLanded) || spaceSwipeOffset != 0 }
    var swipeDirection: CGFloat { slide?.direction ?? (spaceSwipeOffset < 0 ? -1 : 1) }
    var swipeNeighbor: ChromiumSpace? {
        if let slide { return slide.target }
        return spaceSwipeOffset < 0 ? nextSpace : spaceSwipeOffset > 0 ? previousSpace : nil
    }
    func swipePage(in direction: CGFloat) -> ChromiumSpace? {
        if direction == swipeDirection { return swipeNeighbor }
        return slide?.opposite
    }

    func previewTabs(for space: ChromiumSpace) -> [ChromiumTab] {
        if snapshot.activeSpaceId == space.id { return snapshot.sidebarTabs }
        if let slide, slide.opposite?.id == space.id { return slide.oppositeTabs }
        return snapshot.spacePreviews?[space.id]?.filter { !$0.isSidebarPlaceholder } ?? []
    }
    var canSwipeSpaces: Bool {
        !isIncognito && snapshot.windowVisible != false && snapshot.spaces.count > 1 &&
            (snapshot.switchingSpace != true || swipeCommitTarget != nil)
    }

    private var preparedSpaces: Set<String> = []

    func beginSpaceSwipe() {
        guard canSwipeSpaces,
              let origin = queuedHandoffSpace ?? queuedSpaceSelection?.id ?? swipeCommitTarget ?? activeSpace?.id else { return }
        spaceDrag = SpaceDrag(origin: origin)
        if switchingSpaceProfile, let target = swipeCommitTarget { trackSpaceHandoff(after: target) }
        preparedSpaces = []
    }

    private func trackSpaceHandoff(after target: String) {
        guard spaceDrag != nil else { return }
        spaceDrag?.handoff = target
        send("trackSpaceSwipe", metadata: ["after": target])
    }

    func discardUndecidedSpaceSwipe() {
        if let handoff = spaceDrag?.handoff { send("queueSpaceSwipe", metadata: ["after": handoff]) }
        spaceDrag = nil
    }

    private func neighbor(of id: String, direction: CGFloat) -> ChromiumSpace? {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + (direction < 0 ? 1 : -1)
        return snapshot.spaces.indices.contains(next) ? snapshot.spaces[next] : nil
    }

    /// `fingerDelta` is positive when the fingers move right.
    func updateSpaceSwipe(by fingerDelta: CGFloat, width: CGFloat) {
        guard var drag = spaceDrag, width > 0 else { return }
        if drag.initialOffset == nil, drag.handoff == nil, drag.origin == activeSpace?.id, queuedSpaceSelection == nil {
            _ = catchSpaceSpring(at: drag.origin)
            if slide == nil {
                let atEdge = spaceSwipeOffset < 0 ? nextSpace == nil : previousSpace == nil
                let offset = atEdge ? spaceSwipeOffset * 2 : spaceSwipeOffset
                drag.initialOffset = offset - drag.travel * Self.spaceDragGain
            }
        }
        drag.travel += fingerDelta
        spaceDrag = drag
        guard let initialOffset = drag.initialOffset else { return }
        let offset = initialOffset + drag.travel * Self.spaceDragGain
        let target = offset < 0 ? nextSpace : previousSpace
        if let target {
            spaceSwipeOffset = min(width, max(-width, offset))
            if target.profile != nil, target.profile != snapshot.profileId, preparedSpaces.insert(target.id).inserted {
                send("prepareSpace", text: target.id)
            }
        } else {
            spaceSwipeOffset = min(48, max(-48, offset * 0.5))
        }
    }

    func endSpaceSwipe(velocity: CGFloat, width: CGFloat, cancelled: Bool) {
        guard let drag = spaceDrag, width > 0 else { return }
        spaceDrag = nil
        let direction: CGFloat = drag.travel < 0 ? -1 : 1
        let travel = abs(drag.travel)
        let projected = travel + max(0, velocity * direction) * 0.16
        if !cancelled, travel > 12, projected > width * 0.35,
           let target = neighbor(of: drag.origin, direction: direction) {
            if let handoff = drag.handoff {
                if snapshot.windowVisible != false { queuedHandoffSpace = target.id }
                send("queueSpaceSwipe", text: target.id, metadata: ["after": handoff])
            } else if slide != nil {
                queuedSpaceSelection = target.id == swipeCommitTarget ? nil : (target.id, velocity)
            } else {
                settleSpace(to: target, direction: direction, width: width, velocity: velocity, fromClick: false)
            }
        } else if let handoff = drag.handoff {
            send("queueSpaceSwipe", metadata: ["after": handoff])
        } else if slide == nil, spaceSwipeOffset != 0 {
            let visibleDirection: CGFloat = spaceSwipeOffset < 0 ? -1 : 1
            animateSpaceSlide(target: neighbor(of: drag.origin, direction: visibleDirection),
                              direction: visibleDirection, destination: 0, velocity: velocity,
                              committed: false, fromClick: false)
        }
    }

    func settleSpace(to target: ChromiumSpace, direction: CGFloat, width: CGFloat,
                     velocity: CGFloat, fromClick: Bool) {
        animateSpaceSlide(target: target, direction: direction, destination: direction * width,
                          velocity: velocity, committed: true, fromClick: fromClick)
    }

    private func animateSpaceSlide(target: ChromiumSpace?, direction: CGFloat, destination: CGFloat,
                                   velocity: CGFloat, committed: Bool, fromClick: Bool) {
        guard let origin = activeSpace else { return }
        swipeResetWork?.cancel()
        slideLanded = false
        let remaining = destination - spaceSwipeOffset
        let animation: Animation?
        let duration: TimeInterval
        var spring: SpaceSpring?
        if reduceSpaceMotion() {
            // Keep the destination until Chromium acknowledges it, even when
            // there is no visual transition to wait for.
            animation = nil
            duration = 0
        } else if fromClick {
            // Dock selection has no finger velocity. Start promptly and taper
            // through the last few pixels.
            duration = 0.28
            animation = .timingCurve(0.20, 0.12, 0.18, 1, duration: duration)
        } else {
            // A critically damped spring carries the displayed velocity into
            // release. initialVelocity is measured in remaining distances/sec.
            let relativeSpeed = abs(remaining) > 1 ? velocity * Self.spaceDragGain / remaining : 0
            let rate: CGFloat = committed ? 21 : 24
            let speed = min(rate, max(-rate, relativeSpeed))
            spring = SpaceSpring(from: spaceSwipeOffset, to: destination, velocity: speed * remaining, rate: rate)
            animation = .interpolatingSpring(mass: 1, stiffness: rate * rate, damping: 2 * rate, initialVelocity: speed)
            duration = committed ? 0.42 : 0.35
        }
        let opposite = spaceSwipeOffset * direction < 0 ? neighbor(of: origin.id, direction: -direction) : nil
        slide = SpaceSlide(origin: origin, originTabs: snapshot.sidebarTabs, theme: theme, emoji: emoji,
                           target: target, direction: direction, committed: committed, opposite: opposite,
                           oppositeTabs: opposite.map(previewTabs(for:)) ?? [], spring: spring)

        // Prepare both the slide and its completion before the native switch:
        // the command can publish a new snapshot immediately.
        let landed = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.slideLanded = true
            if !committed || self.snapshot.activeSpaceId == target?.id || self.snapshot.windowVisible == false {
                self.finishSpaceSwipe()
            } else {
                // A different profile may still be drawing its window.
                let timeout = DispatchWorkItem { [weak self] in
                    self?.spaceDrag = nil
                    self?.queuedSpaceSelection = nil
                    self?.queuedHandoffSpace = nil
                    self?.finishSpaceSwipe()
                }
                self.swipeResetWork = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            }
        }
        swipeResetWork = landed
        if let animation {
            let start = { [weak self] in
                guard let self, !landed.isCancelled else { return }
                withAnimation(animation) { self.spaceSwipeOffset = destination }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: landed)
            }
            if fromClick {
                // Mount the incoming page before the animation clock starts.
                DispatchQueue.main.async { start() }
            } else {
                start()
            }
        } else {
            spaceSwipeOffset = 0
            landed.perform()
        }
        if committed, let target {
            let crossProfile = target.profile != nil && target.profile != snapshot.profileId
            let metadata = crossProfile ? ["revealAfter": String(Int((duration * 1000).rounded()))] : [:]
            send("space", text: target.id, metadata: metadata)
            if crossProfile { trackSpaceHandoff(after: target.id) }
        }
    }

    // Rebase the pager on the newly active Space without moving either page.
    private func catchSpaceSpring(at origin: String) -> Bool {
        guard let slide, let spring = slide.spring, !slide.committed || swipeCommitTarget == origin else { return false }
        resetSpaceSlide(to: spring.offset - (slide.committed ? spring.to : 0))
        return true
    }

    private func resetSpaceSlide(to offset: CGFloat) {
        swipeResetWork?.cancel()
        swipeResetWork = nil
        slideLanded = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            slide = nil
            spaceSwipeOffset = offset
        }
    }

    func finishSpaceSwipe() {
        resetSpaceSlide(to: 0)
        continueQueuedSpaceSelection()
    }

}
