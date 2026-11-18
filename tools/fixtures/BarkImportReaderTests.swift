import Foundation
import SQLite3
import BarkCore

func checkBarkImportReader() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bark-import-reader-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = root.appendingPathComponent("User Data/Default")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    func write(_ value: Any, _ path: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: target)
    }
    let sidebar: [String: Any] = ["sidebar": ["containers": [["global": [:]], [
        "spaces": ["source-space", ["id": "source-space", "title": "Research", "profile": ["default": true],
            "newContainerIDs": [["pinned": [:]], "pins", ["unpinned": [:]], "today"]]],
        "items": ["pins", ["data": ["itemContainer": [:]], "childrenIds": ["folder"]],
            "folder", ["title": "Reading", "data": ["list": [:]], "childrenIds": ["pin"]],
            "pin", ["title": "Pinned", "data": ["tab": ["savedURL": "https://example.test/pin"]]],
            "today", ["data": ["itemContainer": [:]], "childrenIds": ["open"]],
            "open", ["title": "Open", "data": ["tab": ["savedURL": "https://example.test/open"]]]]
    ]]]]
    try write(sidebar, "StorableSidebar.json")
    let extensionID = String(repeating: "a", count: 32)
    try write(["profile": ["name": "Personal"], "extensions": ["settings": [extensionID: ["state": 0]]]], "User Data/Default/Preferences")
    try write(["name": "Example extension", "version": "1.0"], "User Data/Default/Extensions/\(extensionID)/1.0/manifest.json")
    try write(["profile": ["name": "Work"]], "User Data/Profile 1/Preferences")
    try write(["profile": ["name": "__ARC_SYSTEM_PROFILE"]], "User Data/Profile 2/Preferences")
    try write(["roots": ["bookmark_bar": ["id": "1", "type": "folder", "name": "Bookmarks bar", "children": [
        ["id": "2", "type": "url", "name": "Bookmark", "url": "https://example.test/bookmark"],
        ["id": "3", "type": "url", "name": "Unsafe", "url": "javascript:alert(1)"]]]]], "User Data/Default/Bookmarks")
    var database: OpaquePointer?
    precondition(sqlite3_open(profile.appendingPathComponent("History").path, &database) == SQLITE_OK)
    let visited = (Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000
    precondition(sqlite3_exec(database, "CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER); INSERT INTO urls VALUES ('https://example.test/history','History',\(Int64(visited)));", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let plan = try BarkImportReader.read(root)
    precondition(plan.profileNames.count == 2 && plan.profileNames["Profile 1"] == "Work", "Profiles without spaces must be available")
    precondition(plan.history["Default"]?.count == 1 && abs(plan.history["Default"]![0].visitedAt - Date().timeIntervalSince1970 * 1000) < 10_000)
    precondition(plan.bookmarks["Default"]?.count == 2 && plan.extensions["Default"]?.first?.enabled == false)
    func payload(_ plan: BarkImportPlan, history: Bool = true, extensions: Bool = true) throws -> [String: Any] {
        let text = try ChromiumBarkImport.payload(plan: plan, root: root, profiles: ["Default", "Profile 1"], spaces: [plan.spaces[0].id],
            pinned: true, open: false, folders: true, bookmarks: true, history: history, extensions: extensions, request: "fixture")
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    let request = try payload(plan)
    let profiles = request["profiles"] as! [[String: Any]]
    let first = profiles[0], spaces = first["spaces"] as! [[String: Any]], tabs = spaces[0]["tabs"] as! [[String: Any]]
    precondition(profiles.count == 2 && tabs.count == 1 && tabs[0]["pinned"] as? Bool == true)
    let bookmarks = first["bookmarks"] as! [[String: Any]]
    precondition(bookmarks.contains { $0["title"] as? String == "Reading" && $0["url"] == nil })
    precondition(bookmarks.contains { ($0["url"] as? String)?.hasSuffix(extensionID) == true })
    let retry = try payload(plan)["profiles"] as! [[String: Any]]
    precondition(retry[0]["source"] as? String == first["source"] as? String, "Retry profile identity is stable")
    let filtered = try payload(plan, history: false, extensions: false)["profiles"] as! [[String: Any]]
    precondition((filtered[0]["history"] as! [Any]).isEmpty && filtered[0]["extensions"] as? Int == 0)
    var unavailable = plan
    unavailable.unavailableHistoryProfiles = ["Default"]
    do { _ = try payload(unavailable); preconditionFailure("Unavailable history must block the import") } catch BarkImportError.unavailableCategory { }
    _ = try payload(unavailable, history: false)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
    do { _ = try BarkImportReader.safeURL(root, "outside/History"); preconditionFailure("Symlinks cannot escape the selected installation") } catch is BarkImportReader.ReadError { }
    try Data("not sqlite".utf8).write(to: profile.appendingPathComponent("History"))
    let broken = try BarkImportReader.read(root)
    precondition(broken.unavailableHistoryProfiles.contains("Default") && !broken.spaces.isEmpty)
    print("Bark reader and import selection checks passed")
}
