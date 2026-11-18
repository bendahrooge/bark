import Foundation
import SQLite3
import BarkCore

enum BarkImportReader {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arc", isDirectory: true)
    }
    struct ReadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func safeURL(_ root: URL, _ relative: String) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let components = relative.split(separator: "/")
        guard !relative.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw ReadError(message: "A browser data path points outside the selected folder.")
        }
        var result = base
        // Resolve each parent separately: Foundation may leave a symlink
        // unresolved when the final file in the path does not exist.
        for component in components {
            result = result.appendingPathComponent(String(component)).resolvingSymlinksInPath().standardizedFileURL
            guard result.path.hasPrefix(base.path + "/") else { throw ReadError(message: "A browser data path points outside the selected folder.") }
        }
        return result
    }
    static func json(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> [String: Any] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw ReadError(message: "A browser data file exceeds the import size limit.") }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }
    static func read(_ root: URL) throws -> BarkImportPlan {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let sidebar = try safeURL(root, "StorableSidebar.json")
        let size = try sidebar.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw BarkImportError.invalidSidebar }
        var plan = try BarkImport.sidebar(Data(contentsOf: sidebar))
        let userData = ["User Data", "UserData"].first { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard let userData else {
            plan.unavailableHistoryProfiles = Set(plan.spaces.map(\.profileDirectory))
            plan.unavailableExtensionProfiles = plan.unavailableHistoryProfiles
            plan.unavailableBookmarkProfiles = plan.unavailableHistoryProfiles
            plan.warnings.append("Bark couldn’t find the source profiles. Deselect bookmarks, history, and extensions to import spaces, tabs, and folders.")
            return plan
        }
        let profileRoot = try safeURL(root, userData)
        let directories = try FileManager.default.contentsOfDirectory(atPath: profileRoot.path)
            .filter(BarkImport.validProfileDirectory)
        for directory in Set(directories + plan.spaces.map(\.profileDirectory)).sorted() {
            guard BarkImport.validProfileDirectory(directory) else { continue }
            let profile = try safeURL(root, userData + "/" + directory)
            plan.profileNames[directory] = directory == "Default" ? "Personal" : directory
            guard FileManager.default.fileExists(atPath: profile.path) else {
                plan.unavailableHistoryProfiles.insert(directory)
                plan.unavailableExtensionProfiles.insert(directory)
                plan.unavailableBookmarkProfiles.insert(directory)
                plan.warnings.append("\(directory): the browser profile wasn’t found. Bookmarks, history, and extensions aren’t available.")
                continue
            }
            let preferences = try safeURL(profile, "Preferences")
            if let prefs = try? json(preferences), let info = prefs["profile"] as? [String: Any],
               let name = info["name"] as? String, !name.isEmpty {
                if name == "__ARC_SYSTEM_PROFILE", !plan.spaces.contains(where: { $0.profileDirectory == directory }) {
                    plan.profileNames.removeValue(forKey: directory)
                    continue
                }
                plan.profileNames[directory] = String(name.prefix(64))
            }
            do {
                let bookmarks = try safeURL(profile, "Bookmarks")
                if FileManager.default.fileExists(atPath: bookmarks.path) {
                    plan.bookmarks[directory] = try readBookmarks(bookmarks)
                }
            } catch {
                plan.unavailableBookmarkProfiles.insert(directory)
                plan.warnings.append("\(directory): bookmarks couldn’t be read. Uncheck bookmarks or choose another browser data folder.")
            }
            do {
                let history = try safeURL(profile, "History")
                if FileManager.default.fileExists(atPath: history.path) {
                    let records = try readHistory(history)
                    plan.history[directory] = Array(records.prefix(BrowserState.historyLimit))
                    if records.count > BrowserState.historyLimit { plan.warnings.append("\(directory): only the newest \(BrowserState.historyLimit.formatted()) history entries are available in this import.") }
                }
            } catch {
                plan.unavailableHistoryProfiles.insert(directory)
                plan.warnings.append("\(directory): history couldn’t be read. Quit the source browser and scan again.")
            }
            do { plan.extensions[directory] = try readExtensions(profile) }
            catch { plan.unavailableExtensionProfiles.insert(directory); plan.warnings.append("\(directory): the extension list couldn’t be read.") }
        }
        return plan
    }
    static func readBookmarks(_ path: URL) throws -> [BarkBookmarkRecord] {
        let data = try json(path)
        guard let roots = data["roots"] as? [String: Any] else {
            throw ReadError(message: "Bark couldn’t recognize the bookmarks format.")
        }
        var records: [BarkBookmarkRecord] = []
        func walk(_ node: [String: Any], parent: String, path: String, depth: Int) throws {
            guard depth < 64, records.count < 20_000 else { throw ReadError(message: "The selected bookmarks exceed the import limit.") }
            let id = "bookmark/" + (node["guid"] as? String ?? node["id"] as? String ?? path)
            let title = String((node["name"] as? String ?? "Bookmark").prefix(300))
            if node["type"] as? String == "folder" {
                records.append(.init(id: id, parent: parent, title: title))
                for (index, child) in (node["children"] as? [[String: Any]] ?? []).enumerated() {
                    try walk(child, parent: id, path: path + "/\(index)", depth: depth + 1)
                }
            } else if let url = node["url"] as? String, Navigation.isWebURL(url) {
                records.append(.init(id: id, parent: parent, title: title, url: url))
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { try walk(node, parent: "", path: key, depth: 0) }
        }
        return records
    }
    static func readHistory(_ path: URL) throws -> [BarkHistoryRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = database else {
            if let database { sqlite3_close(database) }
            throw ReadError(message: "The source browser’s history is unavailable.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN;", nil, nil, nil) == SQLITE_OK else { throw ReadError(message: "The source browser’s history database is busy.") }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var statement: OpaquePointer?
        let sql = "SELECT url, title, last_visit_time FROM urls WHERE last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(BrowserState.historyLimit + 1)"
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let query = statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ReadError(message: prepared == SQLITE_BUSY || prepared == SQLITE_LOCKED ? "The history database is in use. Quit the source browser and try again." : "Bark couldn’t recognize the history format.")
        }
        defer { sqlite3_finalize(query) }
        func string(_ column: Int32) -> String { sqlite3_column_text(query, column).map { String(cString: $0) } ?? "" }
        var records: [BarkHistoryRecord] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            let url = string(0), title = string(1)
            // Chromium stores microseconds since 1601; Bark uses Unix milliseconds.
            let timestamp = Double(sqlite3_column_int64(query, 2)) / 1_000 - 11_644_473_600_000
            if Navigation.isWebURL(url), timestamp.isFinite, timestamp >= 0 {
                records.append(BarkHistoryRecord(title: String((title.isEmpty ? Navigation.display(url) : title).prefix(300)), url: url, visitedAt: timestamp))
            }
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw ReadError(message: "Bark couldn’t finish reading the source browser’s history.") }
        return records
    }
    static func readExtensions(_ profile: URL) throws -> [BarkExtensionRecord] {
        var settings: [String: Any] = [:]
        for name in ["Preferences", "Secure Preferences"] {
            let path = try safeURL(profile, name)
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try json(path)
                let extensions = data["extensions"] as? [String: Any]
                settings.merge(extensions?["settings"] as? [String: Any] ?? [:]) { _, new in new }
            }
        }
        let root = try safeURL(profile, "Extensions")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [BarkExtensionRecord] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).prefix(1_000) {
            let id = folder.lastPathComponent
            guard id.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil else { continue }
            let safe = try safeURL(root, id)
            let entry = settings[id] as? [String: Any] ?? [:]
            // Do not resurrect orphaned extension files left after uninstall.
            guard settings[id] != nil else { continue }
            let versions = try FileManager.default.contentsOfDirectory(at: safe, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            guard let versionFolder = versions.first else { continue }
            let manifestURL = try safeURL(safe, versionFolder.lastPathComponent + "/manifest.json")
            let manifest = try json(manifestURL, limit: 2 * 1024 * 1024)
            guard manifest["theme"] == nil, let name = manifest["name"] as? String else { continue }
            var display = name
            if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
                let key = String(name.dropFirst(6).dropLast(2))
                let locale = manifest["default_locale"] as? String ?? "en"
                if locale.range(of: #"^[A-Za-z_-]{1,32}$"#, options: .regularExpression) != nil {
                    let messagesURL = try safeURL(safe, versionFolder.lastPathComponent + "/_locales/" + locale + "/messages.json")
                    if let messages = try? json(messagesURL, limit: 2 * 1024 * 1024), let message = messages.first(where: { $0.key.lowercased() == key.lowercased() })?.value as? [String: Any], let value = message["message"] as? String { display = value }
                }
            }
            result.append(BarkExtensionRecord(id: id, name: String(display.prefix(200)), version: String((manifest["version"] as? String ?? "").prefix(64)), enabled: (entry["state"] as? Int ?? 1) == 1))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
