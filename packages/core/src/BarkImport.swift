import Foundation

public struct BarkSpaceImport: Identifiable, Sendable {
    public var id: String { space.id }
    public var space: Space
    public var profileDirectory: String
    public var tabs: [Tab]
    public var folders: [TabFolder]
}
public struct BarkHistoryRecord: Sendable {
    public var title: String
    public var url: String
    public var visitedAt: Double
    public init(title: String, url: String, visitedAt: Double) { self.title = title; self.url = url; self.visitedAt = visitedAt }
}
public struct BarkExtensionRecord: Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public init(id: String, name: String, version: String, enabled: Bool) { self.id = id; self.name = name; self.version = version; self.enabled = enabled }
}
public struct BarkBookmarkRecord: Sendable {
    public var id: String
    public var parent: String
    public var title: String
    public var url: String?
    public init(id: String, parent: String, title: String, url: String? = nil) {
        self.id = id; self.parent = parent; self.title = title; self.url = url
    }
}
public struct BarkImportPlan: Sendable {
    public var spaces: [BarkSpaceImport]
    public var profileNames: [String: String] = [:]
    public var bookmarks: [String: [BarkBookmarkRecord]] = [:]
    public var history: [String: [BarkHistoryRecord]] = [:]
    public var extensions: [String: [BarkExtensionRecord]] = [:]
    public var warnings: [String] = []
    public var unavailableHistoryProfiles: Set<String> = []
    public var unavailableExtensionProfiles: Set<String> = []
    public var unavailableBookmarkProfiles: Set<String> = []
}
public struct BarkImportOptions: Sendable {
    public var selectedSpaces: Set<String>
    public var pinnedTabs = true
    public var openTabs = false
    public var folders = true
    public var history = true
    public var extensions = true
    public init(selectedSpaces: Set<String>) { self.selectedSpaces = selectedSpaces }
}
public struct BarkImportResult: Sendable {
    public var spaces = 0, tabs = 0, folders = 0, history = 0, extensions = 0
}
public enum BarkImportError: Error, LocalizedError {
    case invalidSidebar, noSpaces, capacity, unavailableCategory
    public var errorDescription: String? {
        switch self {
        case .invalidSidebar: return "Bark couldn’t read this sidebar file. Choose the source browser’s Application Support folder containing StorableSidebar.json."
        case .noSpaces: return "This sidebar contains no spaces that Bark can import."
        case .unavailableCategory: return "A selected category couldn’t be read. Quit the source browser and scan again, or deselect that category. No data was imported."
        case .capacity: return "This selection exceeds Bark’s limit of 100 spaces, 5,000 tabs, folders, or extension entries, or 100,000 history entries. Select fewer spaces or categories; no data was imported."
        }
    }
}

public enum BarkImport {
    // Stable IDs make retries additive without duplicating imported items.
    public static func identifier(_ value: String) -> String {
        var a: UInt64 = 14695981039346656037, b: UInt64 = 7809847782465536322
        for byte in value.utf8 { a = (a ^ UInt64(byte)) &* 1099511628211; b = (b ^ UInt64(byte)) &* 1099511628211 }
        return "arc-" + String(a, radix: 16) + "-" + String(b, radix: 16)
    }
    public static func validProfileDirectory(_ value: String) -> Bool {
        value == "Default" || value.range(of: #"^Profile [0-9]{1,6}$"#, options: .regularExpression) != nil
    }
    static func pairs(_ value: Any?) -> [(Any, Any)] {
        if let dictionary = value as? [String: Any] { return dictionary.map { ($0.key, $0.value) } }
        guard let array = value as? [Any], array.count % 2 == 0 else { return [] }
        return stride(from: 0, to: array.count, by: 2).map { (array[$0], array[$0 + 1]) }
    }
    static func profile(_ value: Any?) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if dictionary["default"] != nil { return "Default" }
        let custom = dictionary["custom"] as? [String: Any]
        let object = custom?["_0"] as? [String: Any] ?? custom
        guard let name = object?["directoryBasename"] as? String, validProfileDirectory(name) else { return nil }
        return name
    }
    static func text(_ value: Any?, fallback: String) -> String {
        guard let value = value as? String else { return fallback }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : String(clean.prefix(300))
    }
    static func theme(_ info: [String: Any]) -> SpaceTheme {
        let window = info["windowTheme"] as? [String: Any]
        let palette = window?["primaryColorPalette"] as? [String: Any]
        guard let color = palette?["midTone"] as? [String: Any], let r = color["red"] as? Double, let g = color["green"] as? Double, let b = color["blue"] as? Double else { return .gray }
        if max(r,max(g,b)) - min(r,min(g,b)) < 0.08 { return .gray }
        let candidates: [(SpaceTheme, Double, Double, Double)] = [(.sage,0.35,0.46,0.31),(.clay,0.65,0.41,0.31),(.lavender,0.49,0.41,0.65),(.ocean,0.28,0.49,0.61),(.rose,0.67,0.38,0.49),(.amber,0.58,0.45,0.14),(.mint,0.24,0.51,0.44),(.slate,0.39,0.45,0.54)]
        return candidates.min { pow($0.1-r,2)+pow($0.2-g,2)+pow($0.3-b,2) < pow($1.1-r,2)+pow($1.2-g,2)+pow($1.3-b,2) }!.0
    }
    public static func sidebar(_ data: Data) throws -> BarkImportPlan {
        guard data.count <= 64 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let container = pairs(sidebar["containers"]).first(where: { ($0.0 as? [String: Any])?["global"] != nil })?.1 as? [String: Any] else { throw BarkImportError.invalidSidebar }
        var items: [String: [String: Any]] = [:]
        for (key, value) in pairs(container["items"]) { if let key = key as? String, let value = value as? [String: Any] { items[key] = value } }
        var result = BarkImportPlan(spaces: [])
        var seenSpaces = Set<String>(), skipped = 0
        let favorites = pairs(container["topAppsContainerIDs"])
        for (sourceID, value) in pairs(container["spaces"]) {
            guard let object = value as? [String: Any], let sourceID = object["id"] as? String ?? sourceID as? String, seenSpaces.insert(sourceID).inserted else { continue }
            guard let directory = profile(object["profile"]) else { skipped += 1; continue }
            let spaceID = identifier("space/" + sourceID)
            let info = object["customInfo"] as? [String: Any] ?? [:]
            let icon = info["iconType"] as? [String: Any] ?? [:]
            var emoji = (icon["emoji_v2"] as? String).flatMap(Space.normalizedEmoji)
            if emoji == nil, let scalar = icon["emoji"] as? Int, let unicode = UnicodeScalar(scalar) { emoji = Space.normalizedEmoji(String(unicode)) }
            let space = Space(id: spaceID, name: String(text(object["title"], fallback: "Imported space").prefix(32)), color: theme(info).rawValue, icon: emoji ?? "")
            var imported = BarkSpaceImport(space: space, profileDirectory: directory, tabs: [], folders: [])
            var seen = Set<String>(), order = 0
            func walk(_ id: String, folder: String?, pinned: Bool, depth: Int) {
                guard depth < 32, seen.insert(id).inserted, let node = items[id], let payload = node["data"] as? [String: Any] else { return }
                order += 1
                let newID = identifier(sourceID + "/" + id)
                var parent = folder
                if let tab = payload["tab"] as? [String: Any] {
                    if let url = tab["savedURL"] as? String, Navigation.isWebURL(url) {
                        imported.tabs.append(Tab(id: newID, spaceId: spaceID, title: text(node["title"] as? String ?? tab["savedTitle"] as? String, fallback: Navigation.display(url)), url: url, pinned: pinned, folderID: folder, sidebarOrder: order))
                    } else { skipped += 1 }
                } else if payload["list"] != nil {
                    imported.folders.append(TabFolder(id: newID, spaceID: spaceID, parentID: folder, title: text(node["title"], fallback: "Folder"), order: order))
                    parent = newID
                } else if payload["itemContainer"] == nil { skipped += 1 }
                for child in node["childrenIds"] as? [String] ?? [] { walk(child, folder: parent, pinned: pinned, depth: depth + 1) }
            }
            for (key, value) in favorites where profile(key) == directory { if let id = value as? String { walk(id, folder: nil, pinned: true, depth: 0) } }
            let containers = pairs(object["newContainerIDs"]).isEmpty ? pairs(object["containerIDs"]) : pairs(object["newContainerIDs"])
            for (key, value) in containers {
                let kind = (key as? [String: Any])?.keys.first ?? key as? String ?? ""
                guard ["pinned", "unpinned"].contains(kind), let id = value as? String else { continue }
                walk(id, folder: nil, pinned: kind == "pinned", depth: 0)
            }
            result.spaces.append(imported)
        }
        guard !result.spaces.isEmpty else { throw BarkImportError.noSpaces }
        if skipped > 0 { result.warnings.append("\(skipped) unsupported or non-web items were skipped. Live folders import as ordinary folders.") }
        return result
    }
}

extension BrowserState {
    @discardableResult public mutating func importBrowserData(_ plan: BarkImportPlan, options: BarkImportOptions) throws -> BarkImportResult {
        var next = self, result = BarkImportResult(), historyProfiles = Set<String>()
        let profiles = Set(plan.spaces.filter { options.selectedSpaces.contains($0.id) }.map(\.profileDirectory))
        guard !(options.history && !profiles.isDisjoint(with: plan.unavailableHistoryProfiles)),
              !(options.extensions && !profiles.isDisjoint(with: plan.unavailableExtensionProfiles)) else { throw BarkImportError.unavailableCategory }
        var tabIDs = Set(next.tabs.map(\.id)), folderIDs = Set(next.folders.map(\.id))
        var historyIDs = Set(next.history.map(\.id)), extensionIDs = Set(next.importedExtensions.map(\.id))
        for source in plan.spaces where options.selectedSpaces.contains(source.id) {
            let id = source.id
            if !next.spaces.contains(where: { $0.id == id }) { next.spaces.append(source.space); result.spaces += 1 }
            if options.folders {
                for folder in source.folders where folderIDs.insert(folder.id).inserted { next.folders.append(folder); result.folders += 1 }
            }
            for var tab in source.tabs where (tab.pinned ? options.pinnedTabs : options.openTabs) && tabIDs.insert(tab.id).inserted {
                if !options.folders { tab.folderID = nil }
                next.tabs.append(tab); result.tabs += 1
            }
            if options.history && historyProfiles.insert(source.profileDirectory).inserted {
                // The source database stores history per Chromium profile.
                var existing = Set(next.history.filter { $0.spaceId == id }.map(\.url))
                for record in plan.history[source.profileDirectory] ?? [] where Navigation.isWebURL(record.url) && record.visitedAt.isFinite {
                    if existing.insert(record.url).inserted {
                        let entryID = BarkImport.identifier("history/" + source.profileDirectory + "/" + record.url)
                        if historyIDs.insert(entryID).inserted {
                            next.history.append(HistoryEntry(id: entryID, title: record.title, url: record.url, visitedAt: record.visitedAt, spaceId: id)); result.history += 1
                        }
                    }
                }
            }
            if options.extensions {
                for item in plan.extensions[source.profileDirectory] ?? [] where item.id.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil {
                    let entry = ImportedExtension(spaceID: id, extensionID: item.id, name: item.name, version: item.version, wasEnabled: item.enabled)
                    if extensionIDs.insert(entry.id).inserted { next.importedExtensions.append(entry); result.extensions += 1 }
                }
            }
        }
        guard next.spaces.count <= 100, next.tabs.count <= Self.tabLimit, next.folders.count <= 5_000,
              next.importedExtensions.count <= 5_000, next.history.count <= Self.historyLimit else { throw BarkImportError.capacity }
        next.history.sort { $0.visitedAt > $1.visitedAt }
        next.setupCompleted = true
        if let first = plan.spaces.first(where: { options.selectedSpaces.contains($0.id) }) { next.activeSpaceId = first.id }
        // Imported tabs stay lazy and don't contact websites until selected.
        next.validateFoldersAndExtensions()
        self = next
        return result
    }
}
