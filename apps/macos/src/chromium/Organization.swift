import AppKit
import SwiftUI

/// Folder traversal is independent of view state so malformed imported ancestry
/// cannot hide tabs or recurse forever. Native catalog writes reject cycles.
enum ChromiumFolderTree {
    struct Entry: Identifiable {
        let folder: ChromiumFolder?
        let tab: ChromiumTab?
        let depth: Int
        let count: Int
        var id: String { folder.map { "folder:" + $0.id } ?? "tab:\(tab!.id)" }
    }

    static func descendants(of id: String, folders: [ChromiumFolder]) -> Set<String> {
        var result: Set<String> = [id]
        var changed = true
        while changed {
            changed = false
            for folder in folders where folder.parent.map(result.contains) == true {
                if result.insert(folder.id).inserted { changed = true }
            }
        }
        return result
    }

    static func path(_ folder: ChromiumFolder, in folders: [ChromiumFolder]) -> String {
        var names = [folder.name], seen: Set<String> = [folder.id], current = folder
        while let parent = current.parent, let next = folders.first(where: { $0.id == parent }), seen.insert(parent).inserted {
            names.insert(next.name, at: 0)
            current = next
        }
        return names.joined(separator: " / ")
    }

    static func entries(folders: [ChromiumFolder], tabs: [ChromiumTab]) -> [Entry] {
        let ids = Set(folders.map(\.id))
        var visited = Set<String>(), emittedTabs = Set<Int>(), result: [Entry] = []
        func appendTab(_ tab: ChromiumTab, depth: Int) {
            guard emittedTabs.insert(tab.id).inserted else { return }
            result.append(Entry(folder: nil, tab: tab, depth: depth, count: 0))
        }
        func visit(_ folder: ChromiumFolder, depth: Int) {
            guard visited.insert(folder.id).inserted else { return }
            let subtree = descendants(of: folder.id, folders: folders)
            let contents = tabs.filter { $0.folder.map(subtree.contains) == true }
            result.append(Entry(folder: folder, tab: nil, depth: min(depth, 8), count: contents.count))
            if folder.collapsed == true {
                visited.formUnion(subtree)
                for tab in contents where tab.visibleWhenCollapsed { appendTab(tab, depth: min(depth + 1, 8)) }
            } else {
                for child in folders where child.parent == folder.id { visit(child, depth: depth + 1) }
                for tab in tabs where tab.folder == folder.id { appendTab(tab, depth: min(depth + 1, 8)) }
            }
        }
        for folder in folders where folder.parent == nil || folder.parent == "" || !ids.contains(folder.parent!) {
            visit(folder, depth: 0)
        }
        for folder in folders where !visited.contains(folder.id) { visit(folder, depth: 0) }
        for tab in tabs where tab.folder == nil || !ids.contains(tab.folder!) { appendTab(tab, depth: 0) }
        return result
    }
}

struct ArchiveSearchResult: Identifiable {
    let index: Int
    let tab: ChromiumArchivedTab
    var id: Int { index }
    static func matching(_ tabs: [ChromiumArchivedTab], query: String) -> [ArchiveSearchResult] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return tabs.enumerated().compactMap { index, tab in
            let text = tab.title + " " + tab.url
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
                ? ArchiveSearchResult(index: index, tab: tab) : nil
        }
    }
}

@MainActor extension ChromiumSidebarModel {
    func showArchive() { if !isIncognito { archivePresented = true } }
}

struct ArchiveBrowserView: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var query = ""
    @State private var confirmClear = false
    // State survives body reconstruction: commands always name the space whose
    // archive opened this sheet, including a pending destructive confirmation.
    @State private var openingSpaceID: String
    @State private var openingSpaceName: String
    @Environment(\.dismiss) private var dismiss

    @MainActor init(model: ChromiumSidebarModel) {
        self.model = model
        _openingSpaceID = State(initialValue: model.snapshot.activeSpaceId ?? "")
        _openingSpaceName = State(initialValue: model.activeSpaceName)
    }

    private var tabs: [ChromiumArchivedTab] {
        guard model.snapshot.activeSpaceId == openingSpaceID else { return [] }
        return model.snapshot.archivedTabs ?? []
    }
    private var results: [ArchiveSearchResult] { ArchiveSearchResult.matching(tabs, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Archived Tabs").font(.title2.weight(.semibold))
                    Text(openingSpaceName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search titles or addresses", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search archived tabs")
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(tabs.isEmpty ? "No archived tabs in this space" : "No matching tabs")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { result in
                            Button {
                                model.send("restoreArchived", id: result.index, metadata: ["space": openingSpaceID,
                                    "url": result.tab.url, "title": result.tab.title])
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.tab.title.isEmpty ? result.tab.url : result.tab.title)
                                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(result.tab.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Restore this tab")
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(tabs.count) archived").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Archive…") { confirmClear = true }.disabled(tabs.isEmpty)
                Button("Restore All") {
                    model.send("restoreAllArchived", metadata: ["space": openingSpaceID])
                    dismiss()
                }.disabled(tabs.isEmpty)
            }
        }.padding(22).frame(width: 510, height: 420)
            .alert("Clear this space’s archive?", isPresented: $confirmClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Archive", role: .destructive) {
                    model.send("clearArchive", metadata: ["space": openingSpaceID])
                }
            } message: { Text("The archived links will be removed. This cannot be undone.") }
            .onChange(of: model.snapshot.activeSpaceId) { _ in dismiss() }
    }
}
