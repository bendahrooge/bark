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
    var faviconValid: Bool? = nil
    // Playing sound now or moments ago, and silenced by the user.
    var audible: Bool? = nil
    var muted: Bool? = nil
    // Chromium's split view: the split this tab belongs to, and whether that
    // split is the one on screen.
    var split: String? = nil
    var splitActive: Bool? = nil
    // A title the person gave the tab, shown instead of the page's.
    var customTitle: String? = nil
    // A pinned tab's own page, and whether the tab has navigated away from it.
    var pinnedURL: String? = nil
    var drifted: Bool? = nil
    var sessionClosed: Bool? = nil
    var keepVisibleAfterClose: Bool? = nil
    var visibleWhenCollapsed: Bool { active || keepVisibleAfterClose == true }
    var closeLabel: String { pinned ? "Close pinned tab session" : "Close tab" }
    // The sidebar folder of a pinned tab.
    var folder: String? = nil
    // A JPEG of the page, in the Control-Tab switcher only.
    var thumbnail: String? = nil
    // Set by Chromium from the committed entry, even while another URL is loading.
    var blankPlaceholder: Bool? = nil
    var isBlank: Bool {
        if url.isEmpty { return true }
        if url.hasPrefix("about:blank") {
            let page = url.prefix { $0 != "?" && $0 != "#" }
            return page == "about:blank" || page == "about:blank/"
        }
        return url.hasPrefix("chrome://") && URL(string: url)?.host == "newtab"
    }
    var isSidebarPlaceholder: Bool { !pinned && split == nil && (blankPlaceholder ?? isBlank) }
    var pageTitle: String {
        if isBlank { return "New tab" }
        return title.isEmpty ? (URL(string: url)?.host ?? url) : title
    }
    // Chromium may supply its default globe even when the page has no favicon.
    var faviconImage: NSImage? { faviconValid == false ? nil : FaviconCache.image(favicon) }
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return pageTitle
    }
    var thumbnailImage: NSImage? { thumbnail.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)) }
}

/// Decoded favicons by their encoded form. Rows are rebuilt on every snapshot,
/// and decoding each tab's PNG again every time was the costly part.
enum FaviconCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    static func image(_ encoded: String?) -> NSImage? {
        guard let encoded else { return nil }
        let key = encoded as NSString
        if let image = images.object(forKey: key) { return image }
        guard let data = Data(base64Encoded: encoded), data.count <= 262144, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
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
    var gradient: String? = nil
    var gradientCanvas: SpaceGradientCanvas? = nil
    var folders: [ChromiumFolder]? = nil
    var pinsCollapsed: Bool? = nil
    var displayName: String { name == "Your Chromium" ? "Personal" : name }
    var style: SpaceStyle {
        SpaceStyle(gradient: gradient.flatMap(SpaceTheme.init(rawValue:)),
                   canvas: gradientCanvas?.isValid == true ? gradientCanvas : nil)
    }
    var themeValue: SpaceTheme { SpaceTheme(rawValue: theme ?? "gray") ?? .gray }
}

struct ChromiumProfile: Decodable, Identifiable {
    let id: String
    let name: String
}

struct ChromiumSnapshot: Decodable {
    let tabs: [ChromiumTab]
    var sidebarTabs: [ChromiumTab] { tabs.filter { !$0.isSidebarPlaceholder } }
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
    var archiveGeneration: Int? = nil
    var organizationUndoLabel: String? = nil
    var downloads: ChromiumDownloads? = nil
    // False once this profile's window is hidden behind another space's window.
    var windowVisible: Bool? = nil
    // Read-only tabs of the spaces adjacent to the active one, keyed by space ID.
    var spacePreviews: [String: [ChromiumTab]]? = nil
    var browserImportResult: ChromiumBarkImportResult? = nil
    // Media playing in a tab that is not on screen.
    var media: ChromiumMedia? = nil
    var features: ChromiumFeatures? = nil
    var siteControls: ChromiumSiteControls? = nil
    var notices: [ChromiumNotice]? = nil
    var preferences: ChromiumPreferences? = nil
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
    weak var tabScrollView: NSScrollView?
    weak var spaceDockScrollView: NSScrollView?
    let splitDrop = SplitDropController()
    // Incremented by the keyboard shortcut; the sidebar archives with undo.
    @Published private(set) var archiveRequests = 0
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
    }
    @Published private var slide: SpaceSlide?
    @Published private(set) var spaceSwipeOffset: CGFloat = 0
    private var rawSwipeOffset: CGFloat = 0
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
            snapshot = decoded
        }
        let next = snapshot
        if let slide {
            let interrupted = next.activeSpaceId != slide.origin.id && next.activeSpaceId != swipeCommitTarget
            let missingTarget = slide.target.map { target in !next.spaces.contains { $0.id == target.id } } ?? false
            if next.windowVisible == false || interrupted || missingTarget || isIncognito {
                queuedSpaceSelection = nil
                finishSpaceSwipe()
            } else if slideLanded, let target = swipeCommitTarget, next.activeSpaceId == target {
                finishSpaceSwipe()
            }
        } else if changedProfile, rawSwipeOffset != 0 {
            finishSpaceSwipe()
        }
        let active = activeTab
        if !editingAddress || (addressDisposition == .currentTab && previousActiveID != active?.id) {
            address = active?.isBlank == true ? "" : active?.url ?? ""
        }
        previousActiveID = active?.id
        if changedProfile || activeSpace?.theme != nil {
            theme = isIncognito ? .gray : SpaceTheme(rawValue: activeSpace?.theme ?? UserDefaults.standard.string(forKey: settingsKey("theme")) ?? "gray") ?? .gray
            let fallback = activeSpace?.displayName == "Personal" || activeSpace == nil ? "👤" : ""
            emoji = isIncognito ? "" : Space.normalizedIcon(activeSpace?.emoji ?? UserDefaults.standard.string(forKey: settingsKey("emoji")) ?? fallback) ?? fallback
        }
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
        guard tab.sessionClosed != true else { return }
        send(tab.pinned ? "closePinnedSession" : "close", id: tab.id)
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
        return addressActionQuery == address && addressAction == "navigate" ? .globe : .search
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
        case .toggleSidebar: send("toggleSidebar")
        case .undoOrganization: if snapshot.organizationUndoLabel != nil { send("undoOrganization") }
        case .togglePin:
            // Favorites stay where they are; unpinning one would drop it into a space.
            if let tab = snapshot.sidebarTabs.first(where: { $0.active }) { send("pin", id: tab.id) }
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

    private var queuedSpaceSelection: String?

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
            queuedSpaceSelection = space.id == swipeCommitTarget ? nil : space.id
            return
        }
        guard let source = activeSpaceIndex else { send("space", text: space.id); return }
        guard source != destination else { return }
        let pageWidth = width ?? hostView?.bounds.width ?? CGFloat(snapshot.sidebarWidth ?? 260)
        guard pageWidth > 0 else { send("space", text: space.id); return }
        settleSpace(to: snapshot.spaces[destination], direction: destination > source ? -1 : 1,
                    width: pageWidth, velocity: 0, fromClick: true)
    }

    func continueQueuedSpaceSelection() {
        guard let id = queuedSpaceSelection else { return }
        queuedSpaceSelection = nil
        if snapshot.windowVisible != false, let space = snapshot.spaces.first(where: { $0.id == id }) {
            requestSpaceSelection(space)
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
    var spaceInMotion: Bool { slide != nil || spaceSwipeOffset != 0 }
    var swipeDirection: CGFloat { slide?.direction ?? (spaceSwipeOffset < 0 ? -1 : 1) }
    var swipeNeighbor: ChromiumSpace? {
        if let slide { return slide.target }
        return spaceSwipeOffset < 0 ? nextSpace : spaceSwipeOffset > 0 ? previousSpace : nil
    }
    func previewTabs(for space: ChromiumSpace) -> [ChromiumTab] {
        if snapshot.activeSpaceId == space.id { return snapshot.sidebarTabs }
        return snapshot.spacePreviews?[space.id]?.filter { !$0.isSidebarPlaceholder } ?? []
    }
    var canSwipeSpaces: Bool {
        !isIncognito && snapshot.spaces.count > 1 && snapshot.switchingSpace != true && slide == nil
    }

    private var preparedSpaces: Set<String> = []

    func beginSpaceSwipe() {
        rawSwipeOffset = 0
        preparedSpaces = []
    }

    /// `fingerDelta` is positive when the fingers move right.
    func updateSpaceSwipe(by fingerDelta: CGFloat, width: CGFloat) {
        guard slide == nil, width > 0 else { return }
        rawSwipeOffset += fingerDelta
        let target = rawSwipeOffset < 0 ? nextSpace : previousSpace
        if let target {
            spaceSwipeOffset = min(width, max(-width, rawSwipeOffset * Self.spaceDragGain))
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
        guard slide == nil, width > 0, rawSwipeOffset != 0 else { return }
        let direction: CGFloat = rawSwipeOffset < 0 ? -1 : 1
        let target = direction < 0 ? nextSpace : previousSpace
        // Keep the physical travel required for a switch independent of drag gain.
        let travel = abs(rawSwipeOffset)
        let projected = travel + max(0, velocity * direction) * 0.16
        if !cancelled, let target, travel > 12, projected > width * 0.35 {
            settleSpace(to: target, direction: direction, width: width, velocity: velocity, fromClick: false)
        } else {
            animateSpaceSlide(target: target, direction: direction, destination: 0,
                              velocity: velocity, committed: false, fromClick: false)
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
        if reduceSpaceMotion() {
            finishSpaceSwipe()
            if committed, let target { send("space", text: target.id) }
            return
        }

        let remaining = destination - spaceSwipeOffset
        let animation: Animation
        let duration: TimeInterval
        if fromClick {
            // Dock selection has no finger velocity. Start promptly and taper
            // through the last few pixels.
            duration = 0.28
            animation = .timingCurve(0.20, 0.12, 0.18, 1, duration: duration)
        } else {
            // A critically damped spring carries the displayed velocity into
            // release. initialVelocity is measured in remaining distances/sec.
            let relativeSpeed = abs(remaining) > 1 ? velocity * Self.spaceDragGain / remaining : 0
            let rate: CGFloat = committed ? 21 : 24
            animation = .interpolatingSpring(mass: 1, stiffness: rate * rate, damping: 2 * rate,
                                              initialVelocity: min(rate, max(-rate, relativeSpeed)))
            duration = committed ? 0.42 : 0.35
        }
        slide = SpaceSlide(origin: origin, originTabs: snapshot.sidebarTabs, theme: theme, emoji: emoji,
                           target: target, direction: direction, committed: committed)

        // Prepare both the slide and its completion before the native switch:
        // the command can publish a new snapshot immediately.
        let landed = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.slideLanded = true
            if !committed || self.snapshot.activeSpaceId == target?.id || self.snapshot.windowVisible == false {
                self.finishSpaceSwipe()
            } else {
                // A different profile may still be drawing its window.
                let timeout = DispatchWorkItem { [weak self] in self?.finishSpaceSwipe() }
                self.swipeResetWork = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            }
        }
        swipeResetWork = landed
        let start = { [weak self] in
            guard let self, !landed.isCancelled else { return }
            withAnimation(animation) { self.spaceSwipeOffset = destination }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: landed)
        }
        if fromClick {
            // Let Chromium activate the tab and mount the incoming page at
            // its starting position before the animation clock starts.
            DispatchQueue.main.async { start() }
        } else {
            start()
        }
        if committed, let target {
            let crossProfile = target.profile != nil && target.profile != snapshot.profileId
            let metadata = crossProfile ? ["revealAfter": String(Int((duration * 1000).rounded()))] : [:]
            send("space", text: target.id, metadata: metadata)
        }
    }

    func finishSpaceSwipe() {
        swipeResetWork?.cancel()
        swipeResetWork = nil
        rawSwipeOffset = 0
        slideLanded = false
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            slide = nil
            spaceSwipeOffset = 0
        }
        continueQueuedSpaceSelection()
    }

}

// The centered panel opens empty for a new destination or with the current URL
// selected for editing. As a child window, it follows the browser when it moves.
@MainActor final class AddressBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let model: ChromiumSidebarModel
    private var panel: AddressBarPanel?
    private var field: NSTextField?
    private var icon: NSImageView?
    private var displayedIcon: AddressBarIcon?
    private weak var parent: NSWindow?
    private var suggestionsObserver: AnyCancellable?
    private var iconObserver: AnyCancellable?
    private var openedAt: Date?
    private var scrim: AddressBarScrim?
    private static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40

    init(model: ChromiumSidebarModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible == true }

    func show(over window: NSWindow?) {
        guard let window, window.isVisible else {
            model.cancelAddressEditing()
            return
        }
        let panel = self.panel ?? makePanel()
        if parent !== window {
            parent?.removeChildWindow(panel)
            if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
            parent = window
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(parentChanged(_:)), name: name, object: window)
            }
        }
        field?.stringValue = model.address
        model.clearSuggestions()
        // Start with recently used open tabs; typing narrows to matches.
        model.requestSuggestions(for: "")
        updateIcon()
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
        iconObserver = nil
        scrim?.removeFromSuperview(); scrim = nil
        field?.delegate = nil
        panel = nil; field = nil; icon = nil; displayedIcon = nil; parent = nil
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

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .labelColor
        field.placeholderString = "Search or enter address · Tab for actions"
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
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
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
        self.icon = icon
        suggestionsObserver = model.$suggestions.dropFirst().sink { [weak self] items in
            // @Published fires before the value is stored; lay out next turn.
            DispatchQueue.main.async { self?.resize(rows: items.count) }
        }
        iconObserver = model.objectWillChange.sink { [weak self] in
            // Read after @Published has stored the new text, selection, or favicon.
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
        return panel
    }

    private func updateIcon() {
        guard let icon else { return }
        let next = model.addressBarIcon
        guard next != displayedIcon else { return }
        displayedIcon = next
        switch next {
        case .favicon(let encoded):
            icon.symbolConfiguration = nil
            icon.contentTintColor = nil
            icon.image = FaviconCache.image(encoded)
            icon.setAccessibilityLabel("Website icon")
        case .command(let symbol):
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Browser action")
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityLabel("Browser action")
        case .globe, .search:
            let label = next == .search ? "Search" : "Open address"
            icon.image = NSImage(systemSymbolName: next == .search ? "magnifyingglass" : "globe", accessibilityDescription: label)
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityLabel(label)
        }
    }

    private func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + AddressSuggestionList.padding * 2 + 1
    }

    private func resize(rows: Int) {
        guard let panel, panel.isVisible else { return }
        position(panel, rows: rows)
    }

    func open(_ suggestion: AddressSuggestion) {
        let disposition = model.addressDisposition
        close()
        model.openSuggestion(suggestion, in: disposition)
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

    // When Chromium asks to edit an existing tab's address, it can briefly
    // reclaim key focus as that tab finishes opening.
    func windowDidResignKey(_ notification: Notification) {
        let type = NSApp.currentEvent?.type
        let clicked = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let justOpened = openedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        if model.editingAddress, model.addressDisposition == .currentTab,
           !clicked && justOpened, let panel, panel.isVisible, NSApp.isActive {
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
        if command == #selector(NSResponder.insertTab(_:)), control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            control.stringValue = "> "
            model.address = control.stringValue
            model.selectedSuggestion = nil
            model.requestSuggestions(for: control.stringValue)
            return true
        }
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
            // Action-only input never leaks into a web search when no command matches.
            if CommandBarSelection.isActionQuery(text) { NSSound.beep(); return true }
            let disposition = model.addressDisposition
            close()
            model.submitAddress(text, in: disposition)
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
    private var icon: NSImage? { suggestion.faviconValid == false ? nil : FaviconCache.image(suggestion.favicon) }
    private var subtitle: String {
        if suggestion.isCommand { return suggestion.detail ?? "Browser action" }
        guard let url = URL(string: suggestion.url), let host = url.host else { return suggestion.url }
        let path = url.path == "/" ? "" : url.path
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }
    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else {
                    Image(systemName: suggestion.isCommand ? (suggestion.symbol ?? "command") : suggestion.isTab ? "square.fill" : suggestion.kind == "history" ? "clock" : "globe")
                        .foregroundStyle(.secondary)
                }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title.isEmpty ? subtitle : suggestion.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(suggestion.isCommand ? "Run action" : suggestion.isTab
                 ? (suggestion.space.map { "Switch to tab · \($0)" } ?? "Switch to tab")
                 : suggestion.kind == "history" ? "History" : suggestion.kind == "search" ? "Search" : "Open address")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
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
private typealias SidebarButtonStyle = BarkControlStyle

// A pale, gently raised surface marks selected tabs, Favorites and spaces.
private struct SidebarSelectionBackground: View {
    let tint: Color
    var cornerRadius: CGFloat = 9
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(scheme == .dark ? 0.14 : 0.70))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(scheme == .dark ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.06 : 0.04), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.05), radius: 1.5, y: 1)
    }
}

private struct ChromiumTabRow: View {
    @ObservedObject var model: ChromiumSidebarModel
    let tab: ChromiumTab
    var indent: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var faviconHovered = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool
    private var favicon: NSImage? { tab.faviconImage }
    private var title: String { tab.displayTitle }
    private var pageTitle: String { tab.pageTitle }
    private var drifted: Bool { tab.pinned && tab.drifted == true }

    // Double-click a tab, or choose Rename, to give it a title of its own.
    private func startRenaming() {
        guard !model.isIncognito else { return }
        draftTitle = title
        renaming = true
        DispatchQueue.main.async { titleFocused = true }
    }
    private func finishRenaming(save: Bool) {
        guard renaming else { return }
        renaming = false
        guard save else { return }
        let text = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title, or the page's own, goes back to following the page.
        model.send("renameTab", id: tab.id, text: text == pageTitle ? "" : text)
    }

    @ViewBuilder private var menuItems: some View {
                if !tab.isBlank {
                    Button("Copy Link") { model.copyLink(tab) }
                    Button("Duplicate") { model.send("duplicate", id: tab.id) }
                }
                if !model.isIncognito {
                    Button("Rename…") { startRenaming() }
                    if tab.customTitle != nil {
                        Button("Use Page Title") { model.send("renameTab", id: tab.id, text: "") }
                    }
                }
                if drifted {
                    Divider()
                    Button("Go Back to Pinned Page") { model.send("resetPin", id: tab.id) }
                    Button("Pin This Page Instead") { model.send("setPinURL", id: tab.id) }
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
                if !model.isIncognito {
                    Menu("Move to Folder") {
                        ForEach(model.folders) { folder in
                            Button((tab.folder == folder.id ? "✓ " : "") + ChromiumFolderTree.path(folder, in: model.folders)) {
                                model.send("moveToFolder", id: tab.id, metadata: ["folder": folder.id])
                            }
                        }
                        if !model.folders.isEmpty { Divider() }
                        Button("New Folder") { model.requestNewFolder(containing: tab.id) }
                        if tab.folder != nil {
                            Button("Remove from Folder") { model.send("moveToFolder", id: tab.id, metadata: ["folder": ""]) }
                        }
                    }
                }
                Button("Move to New Window") { model.send("detachTab", id: tab.id) }
                if !model.moveTargets.isEmpty {
                    Menu("Move to Space") {
                        ForEach(model.moveTargets) { space in
                            Button((model.emoji(for: space).isEmpty ? "" : model.emoji(for: space) + " ") + space.displayName) {
                                model.send("moveTabToSpace", id: tab.id, text: space.id)
                            }
                        }
                    }
                }
                Divider()
                Button(tab.closeLabel) { model.close(tab) }.disabled(tab.sessionClosed == true)
                // Pinned tabs are kept, as in Chromium's own tab menu.
                Button("Close Other Tabs") { model.send("closeOthers", id: tab.id) }
                    .disabled(!model.snapshot.sidebarTabs.contains { !$0.pinned && $0.id != tab.id })
                Button("Close Tabs Below") { model.send("closeBelow", id: tab.id) }
                    .disabled(!(model.snapshot.sidebarTabs.drop { $0.id != tab.id }.dropFirst().contains { !$0.pinned }))
    }

    @ViewBuilder private var icon: some View {
        Group {
            if drifted && faviconHovered {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            } else if tab.loading { ProgressView().controlSize(.mini) }
            else if !tab.isBlank, let favicon { Image(nsImage: favicon).resizable().scaledToFit() }
            else { Image(systemName: "square.fill").foregroundStyle(.secondary) }
        }.frame(width: 16, height: 16)
    }
    private var muteLabel: String { tab.muted == true ? "Unmute tab" : "Mute tab" }
    private var audioDescription: String { tab.muted == true ? "Muted. " : tab.audible == true ? "Playing audio. " : "" }
    private var accessibilityDescription: String {
        let parts: [String] = [tab.active ? "Selected. " : "", tab.split != nil ? "In a split view. " : "",
                               audioDescription, tab.pinned ? "Pinned" : ""]
        return parts.joined() + (tab.sessionClosed == true ? ". Session closed" : "")
    }
    private var rowFill: Color {
        // The other half of the split on screen.
        if tab.splitActive == true { return Color.white.opacity(scheme == .dark ? 0.06 : 0.30) }
        return Color.primary.opacity(hovered ? 0.045 : 0)
    }

    @ViewBuilder private var leading: some View {
        if drifted {
            // A pinned tab away from its page: the icon takes it back.
            Button { model.send("resetPin", id: tab.id) } label: { icon.contentShape(Rectangle()) }
                .buttonStyle(.plain).onHover { faviconHovered = $0 }
                .help("Go back to the pinned page").accessibilityLabel("Go back to the pinned page")
            Text("/").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, -4).accessibilityHidden(true)
        } else {
            icon.accessibilityHidden(true)
        }
    }

    @ViewBuilder private var titleView: some View {
        if renaming {
            TextField("Tab name", text: $draftTitle)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                .focused($titleFocused).onSubmit { finishRenaming(save: true) }
                .onExitCommand { finishRenaming(save: false) }
                .onChange(of: titleFocused) { focused in if !focused { finishRenaming(save: true) } }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(title).font(.system(size: 13, weight: tab.active ? .medium : .regular))
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var trailing: some View {
        if tab.audible == true || tab.muted == true {
            Button { model.send("mute", id: tab.id) } label: {
                Image(systemName: tab.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10)).frame(width: 22, height: 24)
            }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                .help(muteLabel).accessibilityLabel(muteLabel)
        }
        // Keep one close-button slot so hovering never reflows the title.
        // Split membership uses the same space until the close button fades in.
        // Pinning remains available through the context menu and drag actions.
        ZStack(alignment: .trailing) {
            if tab.split != nil {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).opacity(hovered ? 0 : 1)
                    .help("In a split view").accessibilityHidden(true)
            }
            if tab.sessionClosed != true {
                Button { model.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
                }.help(tab.closeLabel).accessibilityLabel(Text(tab.closeLabel))
                    .buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                    .opacity(hovered ? 1 : 0)
                    .disabled(!hovered).allowsHitTesting(hovered).accessibilityHidden(!hovered)
            }
        }.frame(width: 24, height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }

    private var row: some View {
        HStack(spacing: 9) {
            leading
            titleView
            trailing
        }.padding(.leading, 11 + indent).padding(.trailing, 5).frame(height: 36)
            .background {
                if tab.active {
                    SidebarSelectionBackground(tint: model.theme.accent)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(rowFill)
                }
            }
    }

    var body: some View {
        row
            .contentShape(RoundedRectangle(cornerRadius: 9)).onTapGesture { if !renaming { model.send("select", id: tab.id) } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if !renaming { startRenaming() } })
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityLabel(title)
            .accessibilityValue(accessibilityDescription)
            .accessibilityAction { model.send("select", id: tab.id) }
            .accessibilityActions {
                if tab.sessionClosed != true { Button(tab.closeLabel) { model.close(tab) } }
            }
            .accessibilityAction(named: "Move to New Window") { model.send("detachTab", id: tab.id) }
            .accessibilityAction(named: tab.pinned ? "Unpin tab" : "Pin tab") { model.send("pin", id: tab.id) }
            .accessibilityAction(named: muteLabel) { model.send("mute", id: tab.id) }
            .accessibilityAction(named: "Rename tab") { startRenaming() }
            .contextMenu { menuItems }
    }

}

// A folder of pinned tabs. Click to open or close it; double-click to rename.
private struct SidebarFolderHeader: View {
    @ObservedObject var model: ChromiumSidebarModel
    let folder: ChromiumFolder
    let count: Int
    @Binding var renameTarget: String?
    @State private var hovered = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    private var collapsed: Bool { folder.collapsed == true }
    private var renaming: Bool { renameTarget == folder.id }

    private func startRenaming() {
        draftName = folder.name
        renameTarget = folder.id
        DispatchQueue.main.async { nameFocused = true }
    }
    private func finish(save: Bool) {
        guard renaming else { return }
        renameTarget = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if save, !name.isEmpty, name != folder.name {
            model.send("renameFolder", text: String(name.prefix(64)), metadata: ["folder": folder.id])
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: collapsed ? "folder" : "folder.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            if renaming {
                TextField("Folder name", text: $draftName).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .focused($nameFocused).onSubmit { finish(save: true) }.onExitCommand { finish(save: false) }
                    .onChange(of: nameFocused) { focused in if !focused { finish(save: true) } }
                    .onAppear { if draftName.isEmpty { draftName = folder.name }; DispatchQueue.main.async { nameFocused = true } }
            } else {
                Text(folder.name).font(.system(size: 13)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90)).opacity(hovered || collapsed ? 1 : 0)
        }.padding(.horizontal, 11).frame(height: 34)
            .background(Color.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture { if !renaming { model.send("toggleFolder", metadata: ["folder": folder.id]) } }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if !renaming { startRenaming() } })
            .onHover { hovered = $0 }
            .accessibilityElement(children: .combine).accessibilityLabel("Folder " + folder.name)
            .accessibilityValue((collapsed ? "Closed" : "Open") + ", \(count) " + (count == 1 ? "tab" : "tabs"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.send("toggleFolder", metadata: ["folder": folder.id]) }
            .contextMenu {
                Button(collapsed ? "Open Folder" : "Close Folder") { model.send("toggleFolder", metadata: ["folder": folder.id]) }
                Button("Rename Folder…") { startRenaming() }
                Button("New Folder Inside…") {
                    model.renameNextFolder = true
                    model.send("newFolder", metadata: ["parent": folder.id])
                }
                Menu("Move Folder To") {
                    Button("Top Level") { model.send("moveFolder", metadata: ["folder": folder.id, "parent": ""]) }
                        .disabled(folder.parent == nil || folder.parent == "")
                    ForEach(model.folders.filter { !ChromiumFolderTree.descendants(of: folder.id, folders: model.folders).contains($0.id) }) { destination in
                        Button(ChromiumFolderTree.path(destination, in: model.folders)) {
                            model.send("moveFolder", metadata: ["folder": folder.id, "parent": destination.id])
                        }.disabled(folder.parent == destination.id)
                    }
                }
                Divider()
                Button("Delete Folder") { model.send("deleteFolder", metadata: ["folder": folder.id]) }
            }
            .onChange(of: renameTarget) { target in if target == folder.id && draftName.isEmpty { draftName = folder.name } }
    }
}

// A Favorites tile: a tab shown as its icon above every space of the profile.
private struct FavoriteTile: View {
    @ObservedObject var model: ChromiumSidebarModel
    let tab: ChromiumTab
    @State private var hovered = false
    private var title: String { tab.displayTitle }
    var body: some View {
        ZStack {
            if tab.active {
                SidebarSelectionBackground(tint: model.theme.accent, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.09 : 0.055))
            }
            Group {
                if tab.loading { ProgressView().controlSize(.small) }
                else if !tab.isBlank, let icon = tab.faviconImage { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "square.fill").foregroundStyle(.secondary) }
            }.frame(width: 18, height: 18)
        }.frame(height: 46)
            .contentShape(RoundedRectangle(cornerRadius: 10)).onTapGesture { model.send("select", id: tab.id) }
            .onHover { hovered = $0 }.help(title)
            .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityValue(tab.active ? "Selected. Favorite" : "Favorite")
            .accessibilityAction { model.send("select", id: tab.id) }
            .contextMenu {
                Button(tab.muted == true ? "Unmute tab" : "Mute tab") { model.send("mute", id: tab.id) }
                Button("Remove from Favorites") { model.send("moveTab", id: tab.id, metadata: ["zone": "unpinned", "before": ""]) }
                Button("Move to New Window") { model.send("detachTab", id: tab.id) }
                Button(tab.closeLabel) { model.close(tab) }.disabled(tab.sessionClosed == true)
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

private struct ChromiumAddressBar: View {
    @ObservedObject var model: ChromiumSidebarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?
    private enum Control: Hashable { case address, siteInfo, extensions }

    private var showControls: Bool {
        hovered || focusedControl != nil || accessibleControl != nil || model.editingAddress || model.siteControlsOpen
    }
    private var hasSecurityWarning: Bool {
        ["warning", "dangerous"].contains(model.snapshot.securityLevel ?? "")
    }

    var body: some View {
        // The full surface opens the composer; visible utility buttons intercept
        // only their own clicks. Fixed insets keep the origin steady on hover.
        Button { model.composeAddress() } label: {
            Text(model.addressSummary.isEmpty ? "Search or enter address" : model.addressSummary)
                .font(.system(size: 12.5))
                .foregroundStyle(model.addressSummary.isEmpty ? .tertiary : .primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 11).padding(.trailing, 65).frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
            .focused($focusedControl, equals: .address)
            .accessibilityFocused($accessibleControl, equals: .address)
            .help("Search or open a new tab (⌘T)").accessibilityLabel("Address")
            .accessibilityValue(model.sidebarAddress)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    Button {
                        model.setSiteControlsOpen(false)
                        model.send("extensionMenu")
                    } label: {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 12)).frame(width: 24, height: 28)
                            .opacity(showControls ? 1 : 0)
                    }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                        .focused($focusedControl, equals: .extensions)
                        .accessibilityFocused($accessibleControl, equals: .extensions)
                        .help("Extensions").accessibilityLabel("Extensions")
                        .allowsHitTesting(showControls)
                    Button { model.setSiteControlsOpen(!model.siteControlsOpen) } label: {
                        Image(systemName: hasSecurityWarning ? "exclamationmark.triangle" : "slider.horizontal.3")
                            .font(.system(size: 12)).frame(width: 24, height: 28)
                            .opacity(showControls || hasSecurityWarning ? 1 : 0)
                    }.buttonStyle(SidebarButtonStyle())
                        .background(Color.primary.opacity(model.siteControlsOpen ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(model.snapshot.securityLevel == "dangerous" ? Color.red : hasSecurityWarning ? Color.orange : Color.secondary)
                        .focused($focusedControl, equals: .siteInfo)
                        .accessibilityFocused($accessibleControl, equals: .siteInfo)
                        .help("Site controls and permissions").accessibilityLabel("Site controls")
                        .accessibilityValue(model.snapshot.securityDescription ?? "")
                        .disabled(model.activeTab == nil)
                        .allowsHitTesting(showControls || hasSecurityWarning)
                        .popover(isPresented: Binding(get: { model.siteControlsOpen }, set: { model.setSiteControlsOpen($0) }),
                                 arrowEdge: .bottom) {
                            SiteControlsView(model: model)
                        }
                }.padding(.trailing, 7)
            }
            .background(Color.primary.opacity(showControls ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(model.editingAddress ? 0.13 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showControls)
            .onChange(of: model.activeTab?.id) { _ in model.setSiteControlsOpen(false) }
            .onChange(of: model.activeTab?.url) { _ in model.setSiteControlsOpen(false) }
            .onChange(of: model.snapshot.windowVisible) { visible in if visible == false { model.setSiteControlsOpen(false) } }
            .onDisappear { model.setSiteControlsOpen(false) }
            .accessibilityElement(children: .contain)
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
            // The native host reveals the whole row together. Changing its
            // contents on snapshot acknowledgement makes controls pop mid-slide.
            Spacer(minLength: 0)
            control("chevron.left", "Back") { model.send("back") }.disabled(!model.snapshot.canGoBack)
            control("chevron.right", "Forward") { model.send("forward") }.disabled(!model.snapshot.canGoForward)
            control(model.activeTabLoading ? "xmark" : "arrow.clockwise",
                    model.activeTabLoading ? "Stop loading" : "Reload") {
                model.send(model.activeTabLoading ? "stop" : "reload")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 28) }
            .buttonStyle(SidebarButtonStyle()).help(label).accessibilityLabel(label)
    }
}

private enum DropZone: String { case favorites, pinned, unpinned }

private enum TabDropTarget: Equatable {
    case sidebar(zone: DropZone, before: Int?)
    case split(SplitDropController.Side)
    case newWindow
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
    var newWindow = false
    /// Last destination announced with haptics; reset for each new drag.
    var feedbackTarget: TabDropTarget?
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct EnclosingScrollView: NSViewRepresentable {
    let configure: (NSScrollView) -> Void
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { view.configure = configure; view.resolve() }

    final class Reader: NSView {
        var configure: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.resolve() }
        }
        func resolve() {
            if let scrollView = enclosingScrollView { configure?(scrollView) }
        }
    }
}

/// A separate native host places this target across the sidebar/page boundary.
/// Its width never becomes padding inside the sidebar or covers its scrollbar.
private struct SidebarResizeHandle: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var startWidth: Double?
    @State private var hovered = false
    private var width: Double { model.hostView.map { Double($0.bounds.width) } ?? model.snapshot.sidebarWidth ?? 260 }

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Color.primary.opacity(hovered || startWidth != nil ? 0.15 : 0)
                    .frame(width: 2).allowsHitTesting(false)
            }
            .onHover {
                hovered = $0
                if $0 { NSCursor.resizeLeftRight.set() }
                else if startWidth == nil { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                if startWidth == nil { startWidth = width }
                model.resizingSidebar = true
                model.send("resize", width: min(400, max(200, (startWidth ?? width) + value.translation.width)))
            }.onEnded { _ in
                startWidth = nil
                model.resizingSidebar = false
                NSCursor.arrow.set()
            })
            .onDisappear { startWidth = nil; model.resizingSidebar = false }
            .accessibilityLabel("Resize sidebar").help("Drag to resize sidebar")
            .accessibilityAdjustableAction { model.send("resize", width: min(400, max(200, width + ($0 == .increment ? 20 : -20)))) }
    }
}

@MainActor private final class SidebarResizeHostingView: NSHostingView<SidebarResizeHandle> {
    init(model: ChromiumSidebarModel) {
        super.init(rootView: SidebarResizeHandle(model: model))
        sizingOptions = []
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }
    @available(*, unavailable) required init(rootView: SidebarResizeHandle) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
}

private struct ChromiumSidebar: View {
    @ObservedObject var model: ChromiumSidebarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: SpaceDraft?
    @State private var settingsSpace: SpaceSettingsTarget?
    @State private var settingsProfileID = ""
    @State private var draftProfileID = ""
    @State private var creatingProfile = false
    @State private var showingImport = false
    @State private var profileName = ""
    @State private var tabDrag: TabDrag?
    @GestureState private var tabGestureActive = false
    @State private var tabFrames: [Int: CGRect] = [:]
    @State private var archiveNotice: ArchiveNotice?
    @State private var folderToRename: String?
    @State private var knownFolders: Set<String> = []
    private var floating: Bool { model.snapshot.sidebarCollapsed == true }
    // Docked pages already contribute a 7 pt frame beside the sidebar. Count
    // that toward the visible 8 pt margin instead of adding it a second time.
    private var trailingInset: CGFloat { floating ? 8 : 1 }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ChromiumAddressBar(model: model).padding(.leading, 8).padding(.trailing, trailingInset).padding(.top, 5).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(frameReporter(Self.addressKey))
                    .overlay { if showFavoritesHint { favoritesHint.padding(.leading, 8).padding(.trailing, trailingInset).padding(.top, 5).padding(.bottom, 8) } }
                if !favorites.isEmpty {
                    favoritesGrid.padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ZStack(alignment: .top) {
                    activePage
                        .allowsHitTesting(!model.spaceInMotion)
                    if let neighbor = model.swipeNeighbor {
                        previewPage(neighbor)
                            .offset(x: -model.swipeDirection * geometry.size.width)
                            .transition(.identity)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .offset(x: model.spaceSwipeOffset)
                // minHeight 0: a long preview list must be clipped here, not
                // make the sidebar taller than its window (which shifts and
                // squeezes the whole sidebar while swiping).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                BrowserNoticeSummary(model: model).padding(.horizontal, 10).padding(.top, model.activeNotices.isEmpty ? 0 : 6)
                if let media = model.snapshot.media {
                    SidebarMediaPlayer(model: model, media: media).padding(.horizontal, 10).padding(.top, 6)
                        .transition(.opacity)
                }
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
                // The native backdrop spans this content and the caption row.
                .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0, style: .continuous))
        }.accessibilityHidden(model.snapshot.sidebarCollapsed == true && model.snapshot.sidebarRevealed != true)
            .onChange(of: tabGestureActive) { dragging in
                if !dragging {
                    model.draggingTab = false
                    model.splitDrop.end()
                    if tabDrag?.dropped == false { tabDrag = nil }
                }
            }
            .onDisappear { model.draggingTab = false; model.resizingSidebar = false; model.splitDrop.end() }
            .onChange(of: draft?.id) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: settingsSpace?.id) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.activeSpaceId) { _ in archiveNotice = nil; knownFolders = Set(model.folders.map(\.id)) }
            .onChange(of: model.folders) { folders in
                // Offer to name a folder the person just made.
                let ids = Set(folders.map(\.id))
                if model.renameNextFolder, let added = folders.last(where: { !knownFolders.contains($0.id) }) {
                    model.renameNextFolder = false
                    folderToRename = added.id
                }
                knownFolders = ids
            }
            .onAppear { knownFolders = Set(model.folders.map(\.id)) }
            .onChange(of: model.browserImportRequests) { _ in if !model.isIncognito { showingImport = true } }
            .onChange(of: showingImport) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: creatingProfile) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.sidebarRevealed) { revealed in
            if floating && revealed != true && !model.editingAddress { model.cancelAddressEditing() }
        }
            .sheet(item: $settingsSpace) { target in
                SpaceEditor(draft: SpaceDraft(Space(id: target.space.id, name: target.space.displayName,
                                                    color: target.space.theme ?? "gray", icon: model.emoji(for: target.space)),
                                              style: target.space.style),
                            profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) },
                            profileID: $settingsProfileID, originalProfileID: target.space.profile) { name, theme, emoji, style in
                    model.saveSpaceSettings(target.space, name: name, theme: theme, emoji: emoji, style: style, profile: settingsProfileID)
                    settingsSpace = nil
                }
            }
            .sheet(item: $draft) { draft in
                SpaceEditor(draft: draft, profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) }, profileID: $draftProfileID) { name, theme, emoji, style in
                    model.send("createSpace", text: name, metadata: ["theme": theme.rawValue, "emoji": emoji, "profile": draftProfileID]
                        .merging(style.metadata) { $1 })
                    self.draft = nil
                }
            }
            .sheet(isPresented: $model.archivePresented) { ArchiveBrowserView(model: model) }
            .onChange(of: model.archivePresented) { _ in model.presentingSidebarUI = model.archivePresented || showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .sheet(isPresented: $showingImport) { ChromiumBarkImportView(model: model) }
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
            if let space = model.outgoingSpace, !model.isIncognito {
                spaceHeading(space, emoji: model.outgoingEmoji, tint: model.outgoingTheme.accent)
                    .contextMenu {
                        Button("New Folder") { model.requestNewFolder() }
                        Button("New space…", action: newSpace)
                        Menu("Switch Space") {
                            ForEach(model.snapshot.spaces) { other in
                                Button((other.active ? "✓ " : "") + other.displayName) { model.requestSpaceSelection(other) }
                            }
                        }.disabled(model.switchingSpaceProfile)
                        Divider()
                        spaceMenu(for: space)
                    }
            } else {
                HStack(spacing: 8) {
                    if model.isIncognito { Image(systemName: "eyeglasses") }
                    else { SpaceIcon(emoji: model.outgoingEmoji, tint: model.outgoingTheme.accent) }
                    Text(model.activeSpaceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.foregroundStyle(.secondary).padding(.leading, 18)
                    .frame(height: 36).padding(.bottom, 4)
            }
            ScrollView(.vertical) {
                tabList(model.outgoingTabs, space: model.outgoingSpace, interactive: true)
                    .background(EnclosingScrollView { scrollView in
                        model.tabScrollView = scrollView
                        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
                        scrollView.autohidesScrollers = true
                        if let scroller = scrollView.verticalScroller, scroller.controlSize != .small {
                            scroller.controlSize = .small
                            scrollView.tile()
                        }
                    }.allowsHitTesting(false))
            }.scrollIndicators(.automatic)
                // The scrollbar overlays only the tabs; the resize target is
                // hosted on the outer boundary, without reserving row width.
                .frame(minHeight: 0, maxHeight: .infinity)
                .id(model.outgoingSpace?.id)
                .onChange(of: tabOrder) { _ in settleTabDrag() }
        }
    }

    // A non-interactive copy of an adjacent space, revealed during a swipe.
    private func previewPage(_ space: ChromiumSpace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            spaceHeading(space, emoji: model.emoji(for: space), tint: space.themeValue.accent)
            ScrollView(.vertical) {
                tabList(model.previewTabs(for: space), space: space, interactive: false)
            }.scrollIndicators(.hidden)
                .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private func spaceHeading(_ space: ChromiumSpace, emoji: String, tint: Color) -> some View {
        SpaceHeaderRow(name: space.displayName, emoji: emoji, tint: tint, pinsCollapsed: space.pinsCollapsed == true) {
            guard !model.spaceInMotion, model.activeSpace?.id == space.id else { return }
            model.send("togglePinnedSection", metadata: ["space": space.id])
        } openSettings: {
            guard !model.spaceInMotion, model.activeSpace?.id == space.id else { return }
            showSettings(for: space)
        }
        .padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tabList(_ tabs: [ChromiumTab], space: ChromiumSpace?, interactive: Bool) -> some View {
        let pinned = tabs.filter(\.pinned)
        let folders = space?.folders ?? []
        let pinsCollapsed = space?.pinsCollapsed == true
        let entries = ChromiumFolderTree.entries(folders: folders, tabs: pinned)
        let showAllPins = !pinsCollapsed || tabDrag != nil
        let unpinned = tabs.filter { !$0.pinned }
        let hasUnpinned = !unpinned.isEmpty
        let animation: Animation? = interactive && !reduceMotion && tabDrag == nil && !model.spaceInMotion
            ? .easeInOut(duration: 0.20) : nil
        // Reuse the divider as the pin target so rows stay under the pointer.
        let pinZone = interactive && tabDrag?.dropped == false && pinned.isEmpty
        return VStack(spacing: 0) {
            if !entries.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        SidebarFoldingRows(expanded: showAllPins || entry.tab?.visibleWhenCollapsed == true) {
                            Group {
                                if let folder = entry.folder {
                                    SidebarFolderHeader(model: model, folder: folder, count: entry.count, renameTarget: $folderToRename)
                                        .padding(.leading, CGFloat(entry.depth) * 14)
                                } else if let tab = entry.tab {
                                    tabRow(tab, interactive: interactive, indent: showAllPins ? CGFloat(entry.depth) * 14 : 0)
                                }
                            }.padding(.bottom, 3)
                        }
                    }
                }
            }
            // The divider below the pins hosts the Clear button for unpinned tabs.
            if !pinned.isEmpty || !folders.isEmpty || hasUnpinned || pinZone {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    if hasUnpinned {
                        Button { if interactive { archiveTabs() } } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold))
                                Text("Clear").font(.system(size: 11, weight: .medium))
                            }.padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
                        }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                            .help("Archive unpinned tabs (⇧⌘K)").accessibilityLabel("Archive unpinned tabs")
                    }
                }.padding(.leading, 9).padding(.trailing, 2).padding(.vertical, hasUnpinned ? 6 : 12)
                    .frame(minHeight: pinZone ? 32 : nil)
                    .opacity(pinZone ? 0 : 1)
                    .overlay { if pinZone { dropHint("pin", "Drop here to pin", targeted: dropZone == .pinned) } }
                    .background { if interactive { frameReporter(Self.pinBoundaryKey) } }
            }
            Button { model.send("new") } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").frame(width: 16).accessibilityHidden(true)
                    Text("New tab")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).help("New tab (⌘T)")
            SidebarFoldingRows(expanded: hasUnpinned) {
                LazyVStack(spacing: 3) {
                    ForEach(unpinned) { tabRow($0, interactive: interactive) }
                }.padding(.top, 3)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 12)
            .animation(animation, value: pinsCollapsed)
            .animation(animation, value: model.snapshot.archiveGeneration)
    }

    // MARK: Favorites and tab dragging
    // Drag across the divider to pin or unpin, or into Favorites to show a tab in every space.

    private var favorites: [ChromiumTab] { model.isIncognito ? [] : model.snapshot.favorites ?? [] }

    private var favoritesGrid: some View {
        // Keep one to three favorites tile-sized instead of stretching them
        // across the sidebar. Four columns also align subsequent rows.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
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
    private static let pinBoundaryKey = -1
    private static let addressKey = -2
    private static let gridKey = -3

    private func frameReporter(_ key: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TabFramesKey.self, value: [key: geometry.frame(in: .named(Self.dragSpace))])
        }
    }

    @ViewBuilder private func tabRow(_ tab: ChromiumTab, interactive: Bool, indent: CGFloat = 0) -> some View {
        if interactive {
            ChromiumTabRow(model: model, tab: tab, indent: indent)
                .overlay { MiddleClickCatcher { model.close(tab) }.accessibilityHidden(true) }
                .opacity(tabDrag?.id == tab.id ? 0 : 1)
                .background(frameReporter(tab.id))
                .simultaneousGesture(tabDragGesture(tab.id, fromFavorites: false))
        } else {
            ChromiumTabRow(model: model, tab: tab, indent: indent)
        }
    }

    private func draggedTab(_ id: Int) -> ChromiumTab? {
        favorites.first { $0.id == id } ?? model.snapshot.sidebarTabs.first { $0.id == id }
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
            .opacity(drag.dropped || drag.newWindow ? 0 : 1)
            .offset(x: drag.pointer.x - drag.grab.width, y: drag.pointer.y - drag.grab.height)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var dropZone: DropZone? { tabDrag.flatMap { $0.splitSide == nil && !$0.newWindow ? dropTarget(for: $0).zone : nil } }

    /// Dragging a tab out of the sidebar onto the page opens it alongside the
    /// active tab, on the half it is dropped on. Favorites and the tabs
    /// already on screen cannot be split.
    private func splitSide(for drag: TabDrag) -> SplitDropController.Side? {
        guard !drag.fromFavorites, let tab = draggedTab(drag.id), !tab.active, tab.splitActive != true,
              model.snapshot.sidebarTabs.contains(where: { $0.active }) else {
            model.splitDrop.end()
            return nil
        }
        return model.splitDrop.update(from: model.hostView, floating: floating,
                                      title: tab.displayTitle)
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
        let divider = tabFrames[Self.pinBoundaryKey]
        let hasPins = model.snapshot.sidebarTabs.contains(where: \.pinned)
        let boundary = (hasPins ? divider?.midY : divider?.maxY) ?? -.infinity
        let pinned = y < boundary
        for tab in model.snapshot.sidebarTabs where tab.pinned == pinned && tab.id != drag.id {
            if let frame = tabFrames[tab.id], y < frame.midY { return (pinned ? .pinned : .unpinned, tab.id) }
        }
        return (pinned ? .pinned : .unpinned, nil)
    }

    /// The accent line showing where the dragged tab will land.
    private var dropIndicator: CGRect? {
        guard let drag = tabDrag, !drag.dropped, !drag.newWindow, drag.splitSide == nil else { return nil }
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
        if let last = model.snapshot.sidebarTabs.last(where: { $0.pinned == pinned && $0.id != drag.id }), let frame = tabFrames[last.id] {
            return line(frame.maxY + 1.5, frame)
        }
        if pinned { return nil }  // The divider shows the pin target.
        return tabFrames[Self.pinBoundaryKey].map { line($0.maxY + 1.5, $0) }
    }

    private func tabDragGesture(_ id: Int, fromFavorites: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .updating($tabGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                model.draggingTab = true
                if tabDrag?.id == id, tabDrag?.dropped == false {
                    tabDrag?.pointer = value.location
                } else {
                    let frame = tabFrames[id] ?? CGRect(origin: value.startLocation, size: CGSize(width: 200, height: 36))
                    tabDrag = TabDrag(id: id, fromFavorites: fromFavorites,
                                      grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                                      size: frame.size, pointer: value.location)
                }
                if var drag = tabDrag {
                    drag.newWindow = model.splitDrop.updateNewWindow(from: model.hostView,
                        title: draggedTab(id)?.displayTitle ?? "Tab")
                    drag.splitSide = drag.newWindow ? nil : splitSide(for: drag)
                    let target: TabDropTarget
                    if drag.newWindow {
                        target = .newWindow
                    } else if let side = drag.splitSide {
                        target = .split(side)
                    } else {
                        let destination = dropTarget(for: drag)
                        target = .sidebar(zone: destination.zone, before: destination.before)
                    }
                    // Tick once on entering a split half or insertion slot,
                    // not on every pointer update within the same target.
                    if drag.feedbackTarget != target {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        drag.feedbackTarget = target
                    }
                    tabDrag = drag
                }
            }
            .onEnded { value in
                model.draggingTab = false
                guard var drag = tabDrag, drag.id == id, !drag.dropped else { model.splitDrop.end(); return }
                drag.pointer = value.location
                let newWindowPoint = SplitDropController.newWindowPoint(from: model.hostView)
                let side = newWindowPoint == nil ? splitSide(for: drag) : nil
                model.splitDrop.end()
                drag.splitSide = nil
                drag.dropped = true
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                if let point = newWindowPoint {
                    tabDrag = nil
                    model.send("detachTab", id: id, metadata: ["screenX": String(Double(point.x)), "screenY": String(Double(point.y))])
                    return
                }
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
        (favorites.map { "f\($0.id)" } + model.snapshot.sidebarTabs.map { "\($0.id)\($0.pinned ? "p" : "")" }).joined(separator: ",")
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
        let count = model.snapshot.sidebarTabs.filter { !$0.pinned && !$0.isBlank }.count
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
        defer { model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
        return alert.runModal() == .alertFirstButtonReturn
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
                Button("Import into Bark…") { showingImport = true }
                Divider()
                Button("Bookmarks") { model.send("bookmarks") }
                Button("History") { model.send("history") }
                Button("Downloads") { model.send("downloads") }
                if !model.isIncognito {
                    Button("Archived Tabs…") { model.showArchive() }
                    if let label = model.snapshot.organizationUndoLabel {
                        Button("Undo " + label) { model.send("undoOrganization") }
                            .keyboardShortcut("z", modifiers: [.command, .option])
                    }
                }
                if !model.isIncognito, let features = model.snapshot.features {
                    Menu("Archive Tabs After") {
                        Picker("Archive tabs after", selection: Binding(
                            get: { features.archiveAfterHours },
                            set: { model.send("setArchiveAfter", text: String($0)) })) {
                            Text("12 Hours").tag(12)
                            Text("24 Hours").tag(24)
                            Text("7 Days").tag(168)
                            Text("30 Days").tag(720)
                            Text("Never").tag(0)
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    Toggle("Open Pinned Tab Links in Peek", isOn: Binding(
                        get: { features.peek }, set: { model.send("setPeek", text: $0 ? "on" : "off") }))
                    Toggle("Open Links from Other Apps in a Little Window", isOn: Binding(
                        get: { features.littleWindow }, set: { model.send("setLittleWindow", text: $0 ? "on" : "off") }))
                    Toggle("Picture in Picture When Switching Tabs", isOn: Binding(
                        get: { features.autoPictureInPicture }, set: { model.send("setAutoPictureInPicture", text: $0 ? "on" : "off") }))
                    Divider()
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
            spaceDockIcons
            Spacer(minLength: 0)
            Button(action: newSpace) { Image(systemName: "plus").font(.system(size: 14)).frame(width: 28, height: 30) }
                .buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary).help("New space").accessibilityLabel("New space")
        }
    }

    private var spaceDockIcons: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.snapshot.spaces) { space in
                        Button { model.requestSpaceSelection(space) } label: {
                            SpaceIcon(emoji: model.emoji(for: space), tint: model.tint(for: space))
                                .font(.system(size: 15)).frame(width: 34, height: 34)
                                .opacity(space.active ? 1 : 0.75)
                                .background {
                                    if space.active {
                                        SidebarSelectionBackground(tint: model.tint(for: space))
                                    }
                                }
                        }.buttonStyle(SidebarButtonStyle()).help(space.displayName).accessibilityLabel("Space " + space.displayName)
                            .accessibilityValue(space.active ? "Selected" : "")
                            .contextMenu { spaceMenu(for: space) }
                            .disabled(model.switchingSpaceProfile)
                            .id(space.id)
                    }
                }.background(EnclosingScrollView { model.spaceDockScrollView = $0 }.allowsHitTesting(false))
            }.scrollIndicators(.never)
                .onAppear { if let id = model.snapshot.activeSpaceId { proxy.scrollTo(id) } }
                .onChange(of: model.snapshot.activeSpaceId) { id in if let id { proxy.scrollTo(id) } }
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func spaceMenu(for space: ChromiumSpace) -> some View {
        Button("Space settings…") { showSettings(for: space) }
        profileMenu(for: space)
        Divider()
        Button("Manage spaces…") { model.send("manageSpaces") }
        Button("Delete space…") { confirmDelete(space) }.disabled(!model.canDelete(space))
    }

    private func confirmDelete(_ space: ChromiumSpace) {
        let profile = model.snapshot.profiles?.first { $0.id == space.profile }?.name
        let lastInProfile = model.snapshot.spaces.filter { $0.profile == space.profile }.count == 1
        let details = lastInProfile
            ? "The space is removed from the sidebar. Its profile, tabs, sign-ins, and saved data are kept. To use them again, create a space in this profile."
            : "The space is removed from the sidebar. Its open tabs move to another space"
                + (profile.map { " in the “\($0)” profile." } ?? " of its profile.")
        if confirm("Delete “\(space.displayName)”?",
                   details,
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
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var lastPointer: NSPoint?
    private var presentationSubscription: AnyCancellable?
    private var wasCollapsed = false
    private var wasRevealed = false
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
        presentationSubscription = model.$snapshot.sink { [weak self] snapshot in self?.presentationChanged(snapshot) }
    }
    private func presentationChanged(_ snapshot: ChromiumSnapshot) {
        let collapsed = snapshot.sidebarCollapsed == true
        let revealed = snapshot.sidebarRevealed == true
        guard collapsed != wasCollapsed || revealed != wasRevealed else { return }
        let changedMode = collapsed != wasCollapsed
        wasCollapsed = collapsed
        wasRevealed = revealed
        cancelPendingReveal()
        // An acknowledgement of the reveal may arrive after the pointer has
        // already left. Keep its pending dismissal in that case.
        if changedMode || !revealed { hideWork?.cancel(); hideWork = nil }
        requestedReveal = collapsed && revealed
    }
    // Chromium already places this host inside its caption row. Applying the
    // window titlebar inset again would move the Swift controls out of line.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var isOpaque: Bool { false }
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseDown { self.reportHeaderHit(event.locationInWindow) }
            if event.type == .leftMouseUp {
                // Let SwiftUI finish the resize and update its bounds before
                // deciding whether the pointer has left the floating panel.
                let point = event.locationInWindow
                DispatchQueue.main.async { [weak self] in self?.trackPointer(point) }
            } else {
                self.trackPointer(event.locationInWindow)
            }
            return event
        }
    }
    override func layout() {
        super.layout()
        reportWindowGeometry()
    }
    @objc private func windowGeometryChanged(_ notification: Notification) { reportWindowGeometry() }
    @objc private func windowBecameKey(_ notification: Notification) {
        // Tracking areas can queue an exit while Settings or another Bark
        // window takes focus. That old exit must not dismiss a restored panel.
        hideWork?.cancel(); hideWork = nil
        model.send("hostActivated")
    }
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
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
    }
    @objc private func menuEndedTracking(_ notification: Notification) {
        trackingMenus = max(0, trackingMenus - 1)
        if trackingMenus == 0, let window { trackPointer(window.mouseLocationOutsideOfEventStream) }
    }
    func stopObserving() {
        windowDragStart = nil
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let trackingArea { trackedContent?.removeTrackingArea(trackingArea); self.trackingArea = nil }
        trackedContent = nil
        NotificationCenter.default.removeObserver(self)
        trackingMenus = 0
    }
    private func containsPointer(_ point: NSPoint, in window: NSWindow, revealed: Bool) -> Bool {
        // Include the inset, the spring's overshoot, and a small exit grace
        // region so the panel's rightmost controls stay inside its hover area.
        let panelRight = model.hostView.map { $0.convert($0.bounds, to: nil).maxX } ?? 0
        return point.y >= 0 && point.y < window.frame.height &&
            point.x >= 0 && point.x <= (revealed ? max(panelRight, (model.snapshot.sidebarWidth ?? 260) + 8) + 12 : 16)
    }
    private func trackPointer(_ point: NSPoint) {
        lastPointer = point
        defer { reportHover("pointer", point: point) }
        guard model.snapshot.sidebarCollapsed == true, let window, window.isKeyWindow,
              !window.styleMask.contains(.fullScreen) else {
            cancelPendingReveal()
            hideWork?.cancel(); hideWork = nil; requestedReveal = false; return
        }
        if trackingMenus > 0 || model.presentingSidebarUI || model.siteControlsOpen || model.noticesOpen || model.draggingTab || model.resizingSidebar {
            cancelPendingReveal()
            hideWork?.cancel(); hideWork = nil; return
        }
        let revealed = requestedReveal || model.snapshot.sidebarRevealed == true
        if containsPointer(point, in: window, revealed: revealed) {
            hideWork?.cancel(); hideWork = nil
            if !revealed && showWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.window?.isKeyWindow == true,
                          self.model.snapshot.sidebarCollapsed == true else { return }
                    self.showWork = nil
                    self.requestedReveal = true
                    self.model.send("revealSidebar", text: "true")
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
            }
        } else {
            cancelPendingReveal()
            if revealed && hideWork == nil && !model.editingAddress { scheduleDismissal() }
        }
    }
    private func cancelPendingReveal() { showWork?.cancel(); showWork = nil }
    override func mouseExited(with event: NSEvent) {
        // SwiftUI tracks the buttons inside this host independently of our
        // window-wide tracking area. Let it clear the button under the pointer.
        super.mouseExited(with: event)
        guard let trackingArea, event.trackingArea === trackingArea else { return }
        lastPointer = nil
        cancelPendingReveal()
        if model.snapshot.sidebarCollapsed == true && !model.editingAddress && !model.presentingSidebarUI && !model.siteControlsOpen && !model.noticesOpen && !model.draggingTab && !model.resizingSidebar && trackingMenus == 0 { scheduleDismissal() }
    }
    private func scheduleDismissal() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard !self.model.draggingTab, !self.model.resizingSidebar, !self.model.siteControlsOpen, !self.model.noticesOpen,
                  !self.model.presentingSidebarUI, !self.model.editingAddress,
                  self.trackingMenus == 0, self.window?.isKeyWindow == true else { return }
            // Chromium applies resize commands asynchronously. A mouse-up can
            // arrive before the new width; recheck after layout has caught up.
            if let point = self.lastPointer, let window = self.window,
               self.containsPointer(point, in: window, revealed: true) { return }
            self.dismissReveal()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    private func dismissReveal() {
        defer { reportHover("dismiss") }
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
        let wasRevealed = requestedReveal || model.snapshot.sidebarRevealed == true
        requestedReveal = false
        if wasRevealed { model.send("revealSidebar", text: "false") }
    }
    private func reportHover(_ phase: String, point: NSPoint? = nil) {
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report") else { return }
        var state: [String: Any] = ["phase": phase, "time": ProcessInfo.processInfo.systemUptime,
            "collapsed": model.snapshot.sidebarCollapsed == true, "revealed": model.snapshot.sidebarRevealed == true,
            "requested": requestedReveal, "editing": model.editingAddress, "presenting": model.presentingSidebarUI,
            "menus": trackingMenus, "key": window?.isKeyWindow == true,
            "showPending": showWork != nil, "hidePending": hideWork != nil]
        if let point { state["x"] = point.x; state["y"] = point.y }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data(("BARK_UI_HOVER " + json + "\n").utf8))
        }
    }
    deinit {
        showWork?.cancel()
        hideWork?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        // The main-thread ABI detaches tracking before releasing this view.
        NotificationCenter.default.removeObserver(self)
    }
}

/// Trackpad events have different cadences. Estimate points per second over
/// recent movement, including the time spent holding still before lifting.
struct SpaceSwipeVelocity {
    private var samples: [(time: TimeInterval, position: CGFloat)] = []
    private var position: CGFloat = 0
    private let interval: TimeInterval = 0.08

    mutating func begin(at time: TimeInterval) {
        position = 0
        samples = [(time, 0)]
    }

    mutating func add(_ delta: CGFloat, at time: TimeInterval) {
        position += delta
        if samples.last?.time == time {
            samples[samples.count - 1].position = position
        } else {
            samples.append((time, position))
        }
        while samples.count > 2 && samples[1].time <= time - interval {
            samples.removeFirst()
        }
    }

    func velocity(at time: TimeInterval) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time,
              time - last.time < interval else { return 0 }
        return (last.position - first.position) / max(time - first.time, 1.0 / 240)
    }
}

@MainActor private final class ChromiumHostingView: NSHostingView<ChromiumSidebar> {
    let model: ChromiumSidebarModel
    private enum SwipeState { case idle, undecided(CGSize), horizontal, passthrough }
    private var swipe: SwipeState = .idle
    private var swallowMomentum = false
    private weak var scrollingDock: NSScrollView?
    private var swipeVelocity = SpaceSwipeVelocity()
    private var scrollMonitor: Any?
    fileprivate let addressBar: AddressBarController
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
        BarkImportMenu.shared.register(model)
        model.presentAddressBar = { [weak self] in
            guard let self else { return }
            self.addressBar.show(over: self.window)
        }
        // A local monitor sees trackpad scrolls before the tab list's vertical
        // ScrollView, so the dock and Space switching can route each gesture.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event) ? nil : event
        }
    }
    @available(*, unavailable) required init(rootView: ChromiumSidebar) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Full-width tab backgrounds extend underneath the overlay scrollbar.
        // Route its narrow strip to AppKit before SwiftUI's tab-drag gestures
        // can claim it, including when the thumb is currently faded out.
        if !isHiddenOrHasHiddenAncestor, let scrollView = model.tabScrollView,
           let scroller = scrollView.verticalScroller,
           !scrollView.isHiddenOrHasHiddenAncestor,
           (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height + 1,
           scroller.bounds.contains(scroller.convert(point, from: superview)) {
            if NSApp.currentEvent?.type == .leftMouseDown { scrollView.flashScrollers() }
            return scroller
        }
        return super.hitTest(point)
    }

    func focusAddress() {
        model.focusAddress()
    }

    func openAddressSuggestion(_ json: String) {
        guard let suggestion = try? JSONDecoder().decode(AddressSuggestion.self, from: Data(json.utf8)) else { return }
        addressBar.open(suggestion)
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

    /// Route a wheel tick or an entire trackpad gesture to its starting region.
    private func handleScroll(_ event: NSEvent) -> Bool {
        // Events normally name their window. Without one, the location is in
        // screen coordinates; use the window under it.
        let eventWindow = event.window ?? NSApp.window(withWindowNumber:
            NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
        guard let window, eventWindow === window else { return false }
        let locationInWindow = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let beginsGesture = event.phase.contains(.mayBegin) || event.phase.contains(.began)
        let wheelTick = event.phase.isEmpty && event.momentumPhase.isEmpty
        if beginsGesture || wheelTick {
            scrollingDock = nil
            if let dock = model.spaceDockScrollView, dock.window === window, !dock.isHiddenOrHasHiddenAncestor,
               dock.visibleRect.contains(dock.convert(locationInWindow, from: nil)),
               let document = dock.documentView, document.frame.width > dock.contentSize.width {
                scrollingDock = dock
            }
        }
        if let dock = scrollingDock {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let clip = dock.contentView
            var bounds = clip.bounds
            bounds.origin.x -= delta * (event.hasPreciseScrollingDeltas ? 1 : dock.horizontalLineScroll)
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            dock.reflectScrolledClipView(clip)
            return true
        }
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
        if beginsGesture {
            swallowMomentum = false
            let inside = !isHiddenOrHasHiddenAncestor && bounds.contains(convert(locationInWindow, from: nil))
            swipe = inside && model.canSwipeSpaces ? .undecided(.zero) : .passthrough
            swipeVelocity.begin(at: event.timestamp)
            if event.phase.contains(.mayBegin) { return false }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { swipe = .idle }
            guard case .horizontal = swipe else { return false }
            if fingerX != 0 {
                swipeVelocity.add(fingerX, at: event.timestamp)
                model.updateSpaceSwipe(by: fingerX, width: bounds.width)
            }
            model.endSpaceSwipe(velocity: swipeVelocity.velocity(at: event.timestamp), width: bounds.width,
                                cancelled: event.phase.contains(.cancelled))
            swallowMomentum = true
            return true
        }
        switch swipe {
        case .undecided(var total):
            swipeVelocity.add(fingerX, at: event.timestamp)
            total.width += fingerX; total.height += fingerY
            guard hypot(total.width, total.height) >= 6 else { swipe = .undecided(total); return false }
            // Decide once per gesture; a mostly vertical start keeps scrolling tabs.
            guard abs(total.width) > abs(total.height) * 1.3 else { swipe = .passthrough; return false }
            swipe = .horizontal
            model.beginSpaceSwipe()
            model.updateSpaceSwipe(by: total.width, width: bounds.width)
            return true
        case .horizontal:
            swipeVelocity.add(fingerX, at: event.timestamp)
            model.updateSpaceSwipe(by: fingerX, width: bounds.width)
            return true
        case .idle, .passthrough:
            return false
        }
    }
}

// MARK: Split view drop target

/// Previews split drops over the page and a new window outside its bounds.
/// A child panel remains visible beyond the clipped sidebar and browser.
@MainActor final class SplitDropController {
    enum Side: String { case left, right, top, bottom }
    private var panel: NSPanel?
    private var label: NSTextField?
    private weak var parent: NSWindow?

    static func isOutsideWindow(_ point: NSPoint, window: NSRect) -> Bool {
        !window.contains(point)
    }

    static func pointerLocation(in window: NSWindow) -> NSPoint {
        // The captured drag event still belongs to its source window after
        // the pointer leaves it. This also handles displays with other origins.
        if let event = NSApp.currentEvent, event.window === window,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    static func newWindowPoint(from view: NSView?) -> NSPoint? {
        guard let window = view?.window else { return nil }
        let point = pointerLocation(in: window)
        return isOutsideWindow(point, window: window.frame) ? point : nil
    }

    func updateNewWindow(from view: NSView?, title: String) -> Bool {
        guard let window = view?.window, let point = Self.newWindowPoint(from: view) else { return false }
        var frame = NSRect(x: point.x + 16, y: point.y - 80, width: 260, height: 64)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        show(frame, over: window, title: "New window\n" + title)
        return true
    }

    /// The page area of `window` in screen coordinates: everything beside the
    /// sidebar, below the titlebar strip. A collapsed sidebar floats over the
    /// page, which then spans the window.
    static func pageRect(window: NSRect, sidebar: NSRect, floating: Bool) -> NSRect {
        let left = floating ? window.minX : min(max(sidebar.maxX, window.minX), window.maxX)
        let top = min(max(sidebar.maxY, window.minY), window.maxY)
        return NSRect(x: left, y: window.minY, width: window.maxX - left, height: top - window.minY)
    }

    static func side(at point: NSPoint, page: NSRect, sidebar: NSRect) -> Side? {
        guard page.width >= 200, page.height > 0, page.contains(point), !sidebar.contains(point) else { return nil }
        // Choose the nearest edge in normalized page coordinates so all four
        // directions remain reachable in both wide and tall windows.
        let x = (point.x - page.midX) / page.width
        let y = (point.y - page.midY) / page.height
        if abs(y) > abs(x) { return y > 0 ? .top : .bottom }
        return x < 0 ? .left : .right
    }

    static func halfRect(for side: Side, page: NSRect) -> NSRect {
        var half = page
        switch side {
        case .left, .right:
            half.size.width = page.width / 2
            if side == .right { half.origin.x = page.midX }
        case .top, .bottom:
            half.size.height = page.height / 2
            // AppKit screen coordinates increase upward.
            if side == .top { half.origin.y = page.midY }
        }
        return half
    }

    /// Call while dragging. Returns the half under the pointer, or nil when
    /// the pointer is not over the page.
    func update(from view: NSView?, floating: Bool, title: String) -> Side? {
        guard let view, let window = view.window else { end(); return nil }
        let sidebar = window.convertToScreen(view.convert(view.bounds, to: nil))
        let page = PageFrameHostingView.pageRect(in: window)
            ?? Self.pageRect(window: window.frame, sidebar: sidebar, floating: floating)
        guard let side = Self.side(at: Self.pointerLocation(in: window), page: page, sidebar: sidebar) else { end(); return nil }
        let half = Self.halfRect(for: side, page: page)
        show(half.insetBy(dx: 6, dy: 6), over: window, title: "Split with " + title)
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
        label?.stringValue = title
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
        label.maximumNumberOfLines = 2
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

/// Bark's keyboard shortcuts drive both key handling and the guide in the Help menu.
struct BarkShortcut {
    enum Action: Equatable {
        case toggleSidebar, togglePin, copyURL, copyMarkdown, archiveTabs, undoOrganization
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

@_cdecl("BarkSwiftSidebarSwitcher")
@MainActor func barkSwiftSidebarSwitcher(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.updateSwitcher(String(cString: json))
}

@_cdecl("BarkSwiftSidebarFocusAddress")
@MainActor func barkSwiftSidebarFocusAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().focusAddress()
}

@_cdecl("BarkSwiftSidebarComposeAddress")
@MainActor func barkSwiftSidebarComposeAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.composeAddress()
}

@_cdecl("BarkSwiftSidebarDismissAddress")
@MainActor func barkSwiftSidebarDismissAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().addressBar.close(returnFocus: false)
}

@_cdecl("BarkSwiftSidebarAddressVisible")
@MainActor func barkSwiftSidebarAddressVisible(_ handle: UnsafeMutableRawPointer) -> Bool {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().addressBar.isVisible
}

@_cdecl("BarkSwiftSidebarOpenSuggestion")
@MainActor func barkSwiftSidebarOpenSuggestion(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().openAddressSuggestion(String(cString: json))
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

@_cdecl("BarkSwiftSidebarResizeCreate")
@MainActor func barkSwiftSidebarResizeCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(SidebarResizeHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarResizeDestroy")
@MainActor func barkSwiftSidebarResizeDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<SidebarResizeHostingView>.fromOpaque(handle).takeRetainedValue()
    view.rootView.model.resizingSidebar = false
}

@_cdecl("BarkSwiftPageFrameCreate")
@MainActor func barkSwiftPageFrameCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(PageFrameHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarBackdropCreate")
@MainActor func barkSwiftSidebarBackdropCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(SidebarBackdropHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarShowPreferences")
@MainActor func barkSwiftSidebarShowPreferences(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.showPreferences()
}
