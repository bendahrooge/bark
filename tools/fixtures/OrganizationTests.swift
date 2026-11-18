import Foundation

func checkOrganization() throws {
    let folders = [ChromiumFolder(id: "root", name: "Research"),
                   ChromiumFolder(id: "child", name: "Reading", parent: "root"),
                   ChromiumFolder(id: "grandchild", name: "Later", parent: "child")]
    let tabs = try JSONDecoder().decode([ChromiumTab].self, from: Data(#"[{"id":1,"title":"A","url":"https://example.test/a","active":true,"pinned":true,"loading":false,"folder":"grandchild"},{"id":2,"title":"B","url":"https://example.test/b","active":false,"pinned":true,"loading":false,"folder":"root"},{"id":3,"title":"C","url":"https://example.test/c","active":false,"pinned":true,"loading":false}]"#.utf8))
    let entries = ChromiumFolderTree.entries(folders: folders, tabs: tabs)
    precondition(entries.map(\.id) == ["folder:root", "folder:child", "folder:grandchild", "tab:1", "tab:2", "tab:3"])
    precondition(entries.first?.count == 2 && entries[3].depth == 3)
    precondition(ChromiumFolderTree.path(folders[2], in: folders) == "Research / Reading / Later")
    precondition(ChromiumFolderTree.descendants(of: "child", folders: folders) == ["child", "grandchild"])
    var collapsed = folders
    collapsed[0].collapsed = true
    let collapsedEntries = ChromiumFolderTree.entries(folders: collapsed, tabs: tabs)
    precondition(collapsedEntries.map(\.id) == ["folder:root", "tab:1", "tab:3"], "Collapsed ancestor keeps its active descendant visible without repeating children")
    var retained = tabs[1]
    retained.sessionClosed = true
    retained.keepVisibleAfterClose = true
    var sibling = tabs[2]
    sibling.folder = "grandchild"
    sibling.sessionClosed = true
    let closedPins = ChromiumFolderTree.entries(folders: collapsed, tabs: [retained, sibling])
    precondition(closedPins.map(\.id) == ["folder:root", "tab:2"], "Closing a visible pin keeps its row without revealing other dormant pins")
    retained.keepVisibleAfterClose = false
    precondition(ChromiumFolderTree.entries(folders: collapsed, tabs: [retained, sibling]).map(\.id) == ["folder:root"],
                 "The collapsed folder returns to its normal contents when the close exception clears")
    let malformed = [ChromiumFolder(id: "a", name: "A", parent: "b"), ChromiumFolder(id: "b", name: "B", parent: "a"),
                     ChromiumFolder(id: "orphan", name: "Orphan", parent: "missing")]
    let recovered = ChromiumFolderTree.entries(folders: malformed, tabs: [])
    precondition(Set(recovered.map(\.id)).count == 3 && recovered.count == 3, "Malformed ancestry is finite and does not hide folders")
    let archive = [ChromiumArchivedTab(title: "Swift Reference", url: "https://swift.org/docs"),
                   ChromiumArchivedTab(title: "Reading", url: "https://example.test/notes"),
                   ChromiumArchivedTab(title: "Swift Layout", url: "https://example.test/swift")]
    let results = ArchiveSearchResult.matching(archive, query: " SWIFT example ")
    precondition(results.count == 1 && results.first?.index == 2, "Search matches title/URL case-insensitively and keeps original archive indexes")
    precondition(ArchiveSearchResult.matching(archive, query: " ").count == 3)
}
