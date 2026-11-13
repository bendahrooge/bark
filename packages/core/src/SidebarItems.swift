import Foundation

public struct TabFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var spaceID: String
    public var parentID: String?
    public var title: String
    public var isCollapsed: Bool
    public var order: Int
    public init(id: String = UUID().uuidString, spaceID: String, parentID: String? = nil, title: String, order: Int = 0, isCollapsed: Bool = false) {
        self.id = id; self.spaceID = spaceID; self.parentID = parentID; self.title = title; self.order = order; self.isCollapsed = isCollapsed
    }
}

// Inventory for explicit reinstallation. Never contains extension code,
// credentials, browser permission grants, or a claim that it is installed.
public struct ImportedExtension: Codable, Equatable, Identifiable, Sendable {
    public var id: String { spaceID + "-" + extensionID }
    public var spaceID: String
    public var extensionID: String
    public var name: String
    public var version: String
    public var wasEnabled: Bool
    public init(spaceID: String, extensionID: String, name: String, version: String, wasEnabled: Bool) {
        self.spaceID = spaceID; self.extensionID = extensionID; self.name = name; self.version = version; self.wasEnabled = wasEnabled
    }
}

public struct SidebarItem: Identifiable {
    public let tab: Tab?
    public let folder: TabFolder?
    public let depth: Int
    public var id: String { tab.map { "tab-" + $0.id } ?? "folder-" + folder!.id }
}

extension BrowserState {
    public var sidebarItems: [SidebarItem] {
        var result: [SidebarItem] = []
        var visited = Set<String>()
        func walk(_ parent: String?, _ depth: Int) {
            guard depth < 32 else { return }
            let childFolders = folders.filter { $0.spaceID == activeSpaceId && $0.parentID == parent }
            let childTabs = tabs.filter { $0.spaceId == activeSpaceId && $0.folderID == parent }
            var entries = childFolders.map { SidebarItem(tab: nil, folder: $0, depth: depth) }
            entries += childTabs.map { SidebarItem(tab: $0, folder: nil, depth: depth) }
            entries = entries.enumerated().sorted { left, right in
                let lp = left.element.tab?.pinned ?? true, rp = right.element.tab?.pinned ?? true
                if lp != rp { return lp }
                let lo = left.element.folder?.order ?? left.element.tab?.sidebarOrder ?? Int.max
                let ro = right.element.folder?.order ?? right.element.tab?.sidebarOrder ?? Int.max
                if lo != ro { return lo < ro }
                return left.offset < right.offset
            }.map(\.element)
            for entry in entries {
                guard visited.insert(entry.id).inserted else { continue }
                result.append(entry)
                if let folder = entry.folder, !folder.isCollapsed { walk(folder.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return result
    }
    public mutating func toggleFolder(_ id: String) {
        if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].isCollapsed.toggle() }
    }
    mutating func validateFoldersAndExtensions() {
        let spaceIDs = Set(spaces.map(\.id))
        var used = Set<String>()
        folders = Array(folders.filter { spaceIDs.contains($0.spaceID) && $0.id.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil && used.insert($0.id).inserted }.prefix(5_000))
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for i in folders.indices {
            folders[i].title = String(folders[i].title.prefix(300))
            var seen: Set<String> = [folders[i].id]
            var parent = folders[i].parentID
            while let id = parent {
                guard seen.insert(id).inserted, seen.count < 32, let folder = byID[id], folder.spaceID == folders[i].spaceID else { folders[i].parentID = nil; break }
                parent = folder.parentID
            }
        }
        for i in tabs.indices {
            if let id = tabs[i].folderID, byID[id]?.spaceID != tabs[i].spaceId { tabs[i].folderID = nil }
        }
        for i in closedTabs.indices {
            if let id = closedTabs[i].folderID, byID[id]?.spaceID != closedTabs[i].spaceId { closedTabs[i].folderID = nil }
        }
        used = []
        importedExtensions = Array(importedExtensions.filter {
            spaceIDs.contains($0.spaceID) && $0.extensionID.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil && used.insert($0.id).inserted
        }.prefix(5_000))
    }
}
