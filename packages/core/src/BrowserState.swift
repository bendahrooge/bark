import Foundation

public struct Space: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var icon: String
    public init(id: String = UUID().uuidString, name: String, color: String = "gray", icon: String = "🍃") {
        self.id = id; self.name = name; self.color = color; self.icon = icon
    }
}

public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var spaceId: String
    public var title: String
    public var url: String
    public var pinned: Bool
    public var folderID: String?
    public var sidebarOrder: Int?
    public init(id: String = UUID().uuidString, spaceId: String, title: String = "New tab", url: String = Navigation.blank, pinned: Bool = false, folderID: String? = nil, sidebarOrder: Int? = nil) {
        self.id = id; self.spaceId = spaceId; self.title = title; self.url = url; self.pinned = pinned
        self.folderID = folderID; self.sidebarOrder = sidebarOrder
    }
}

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var visitedAt: Double
    public var spaceId: String
    public init(id: String = UUID().uuidString, title: String, url: String, visitedAt: Double, spaceId: String) {
        self.id = id; self.title = title; self.url = url; self.visitedAt = visitedAt; self.spaceId = spaceId
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var theme = "system"
    public var searchEngine: SearchEngine = .duckduckgo
    public var restoreSession = true
    public init() {}
}

public struct BrowserState: Codable, Equatable, Sendable {
    public var version = 1
    public var spaces = [Space(id: "personal", name: "Personal"), Space(id: "work", name: "Work", color: "clay", icon: "💼")]
    public var tabs: [Tab] = []
    public var activeSpaceId = "personal"
    public var activeTabs: [String: String] = [:]
    public var closedTabs: [Tab] = []
    public var history: [HistoryEntry] = []
    public var settings = Settings()
    public var sidebarCollapsed = false
    public var sidebarWidth: Double = 260
    public var setupCompleted = false
    public var folders: [TabFolder] = []
    public var importedExtensions: [ImportedExtension] = []
    public static let tabLimit = 5_000
    public static let historyLimit = 100_000
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, spaces, tabs, activeSpaceId, activeTabs, closedTabs, history, settings, sidebarCollapsed
        case sidebarWidth, setupCompleted, folders, importedExtensions
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? spaces
        tabs = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        activeSpaceId = try c.decodeIfPresent(String.self, forKey: .activeSpaceId) ?? "personal"
        activeTabs = try c.decodeIfPresent([String: String].self, forKey: .activeTabs) ?? [:]
        closedTabs = try c.decodeIfPresent([Tab].self, forKey: .closedTabs) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? settings
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? false
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 260
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? false
        folders = try c.decodeIfPresent([TabFolder].self, forKey: .folders) ?? []
        importedExtensions = try c.decodeIfPresent([ImportedExtension].self, forKey: .importedExtensions) ?? []
        // Only migrate the untouched stock Personal theme from older previews.
        if !c.contains(.sidebarWidth), let i = spaces.firstIndex(where: { $0.id == "personal" && $0.name == "Personal" && $0.color == "sage" && ["leaf", "🍃"].contains($0.icon) }) {
            spaces[i].color = "gray"
        }
    }

    public var activeTab: Tab? { tabs.first { $0.id == activeTabs[activeSpaceId] } }
    public var activeSpace: Space { spaces.first { $0.id == activeSpaceId } ?? spaces[0] }
    public var spaceTabs: [Tab] { tabs.filter { $0.spaceId == activeSpaceId }.sorted { $0.pinned && !$1.pinned } }

    public mutating func validateForRestore() {
        if version != 1 { self = BrowserState(); return }
        func validID(_ value: String) -> Bool {
            value.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil
        }
        var ids = Set<String>()
        spaces = Array(spaces.filter { validID($0.id) && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && ids.insert($0.id).inserted }.prefix(100))
        if spaces.isEmpty { spaces = BrowserState().spaces }
        for i in spaces.indices { spaces[i].name = String(spaces[i].name.prefix(32)) }
        let spaceIDs = Set(spaces.map(\.id))
        ids = []
        func clean(_ tab: Tab) -> Bool {
            validID(tab.id) && spaceIDs.contains(tab.spaceId) && (tab.url == Navigation.blank || Navigation.isWebURL(tab.url)) && ids.insert(tab.id).inserted
        }
        tabs = Array(tabs.filter { clean($0) && (settings.restoreSession || $0.pinned) }.prefix(Self.tabLimit))
        closedTabs = Array(closedTabs.filter { clean($0) }.prefix(30))
        if !spaceIDs.contains(activeSpaceId) { activeSpaceId = spaces[0].id }
        let previouslySelectedSpaces = Set(activeTabs.keys)
        activeTabs = activeTabs.filter { key, value in tabs.contains { $0.spaceId == key && $0.id == value } }
        // Repair stale selections while preserving intentionally blank spaces,
        // including imported spaces whose tabs have never been opened.
        for space in spaces where previouslySelectedSpaces.contains(space.id) && activeTabs[space.id] == nil {
            activeTabs[space.id] = tabs.first { $0.spaceId == space.id }?.id
        }
        history = Array(history.filter { spaceIDs.contains($0.spaceId) && Navigation.isWebURL($0.url) && $0.visitedAt.isFinite }.prefix(Self.historyLimit))
        if !["light", "dark", "system"].contains(settings.theme) { settings.theme = "system" }
        sidebarWidth = sidebarWidth.isFinite ? min(400, max(200, sidebarWidth)) : 260
        validateFoldersAndExtensions()
    }

    @discardableResult public mutating func newTab(_ input: String = "") -> String? {
        guard tabs.count < Self.tabLimit else { return nil }
        let url = Navigation.resolve(input, engine: settings.searchEngine)
        let tab = Tab(spaceId: activeSpaceId, title: Navigation.display(url), url: url)
        tabs.append(tab); activeTabs[activeSpaceId] = tab.id
        return tab.id
    }
    public mutating func selectTab(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeSpaceId = tab.spaceId; activeTabs[tab.spaceId] = id
    }
    public mutating func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        closedTabs.insert(tab, at: 0); closedTabs = Array(closedTabs.prefix(30))
        if activeTabs[tab.spaceId] == id {
            activeTabs[tab.spaceId] = tabs.dropFirst(min(index, tabs.count)).first { $0.spaceId == tab.spaceId }?.id
                ?? tabs.last { $0.spaceId == tab.spaceId }?.id
        }
    }
    public mutating func reopenTab() {
        guard tabs.count < Self.tabLimit, !closedTabs.isEmpty else { return }
        var tab = closedTabs.removeFirst()
        guard spaces.contains(where: { $0.id == tab.spaceId }) else { return }
        tab.id = UUID().uuidString; tabs.append(tab); selectTab(tab.id)
    }
    public mutating func togglePin(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pinned.toggle()
        if !tabs[index].pinned { tabs[index].folderID = nil }
    }
    public mutating func reorder(_ id: String, before targetID: String) {
        guard id != targetID, let tab = tabs.first(where: { $0.id == id }), let target = tabs.first(where: { $0.id == targetID }), tab.spaceId == target.spaceId, tab.pinned == target.pinned, tab.folderID == target.folderID else { return }
        tabs.removeAll { $0.id == id }
        if let index = tabs.firstIndex(where: { $0.id == targetID }) { tabs.insert(tab, at: index) }
        for (order, i) in tabs.indices.filter({ tabs[$0].spaceId == tab.spaceId && tabs[$0].folderID == tab.folderID }).enumerated() { tabs[i].sidebarOrder = order }
    }
    public mutating func addSpace(name: String, color: String = "gray", icon: String = "🍃") {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !name.isEmpty, spaces.count < 100 else { return }
        let space = Space(name: name, color: color, icon: icon)
        spaces.append(space); activeSpaceId = space.id
    }
    public mutating func updateSpace(_ id: String, name: String, theme: SpaceTheme, emoji: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !name.isEmpty, let emoji = Space.normalizedEmoji(emoji),
              let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[index].name = name
        spaces[index].color = theme.rawValue
        spaces[index].icon = emoji
    }
    public mutating func deleteSpace(_ id: String) {
        guard spaces.count > 1 else { return }
        spaces.removeAll { $0.id == id }; tabs.removeAll { $0.spaceId == id }
        closedTabs.removeAll { $0.spaceId == id }; history.removeAll { $0.spaceId == id }
        folders.removeAll { $0.spaceID == id }; importedExtensions.removeAll { $0.spaceID == id }
        activeTabs[id] = nil
        if activeSpaceId == id { activeSpaceId = spaces[0].id }
    }
    public mutating func updateTab(_ id: String, url: String? = nil, title: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url, Navigation.isWebURL(url) { tabs[index].url = url }
        if let title, !title.isEmpty { tabs[index].title = String(title.prefix(300)) }
    }
    public mutating func visit(_ id: String) {
        guard let tab = tabs.first(where: { $0.id == id }), Navigation.isWebURL(tab.url) else { return }
        history.removeAll { $0.url == tab.url && $0.spaceId == tab.spaceId }
        history.insert(HistoryEntry(id: UUID().uuidString, title: tab.title, url: tab.url, visitedAt: Date().timeIntervalSince1970 * 1_000, spaceId: tab.spaceId), at: 0)
        history = Array(history.prefix(Self.historyLimit))
    }
}
