import AppKit
import SwiftUI
import BarkCore

struct ChromiumBarkImportResult: Decodable {
    let request: String
    let success: Bool
    let profiles: Int
    let spaces: Int
    let tabs: Int
    let history: Int
    let bookmarks: Int
    let extensions: Int
    let expiredHistory: Int?
    let error: String?
}

/// A bounded, value-only request. Chromium owns the destination profiles and
/// writes through its normal history, bookmarks and space services.
enum ChromiumBarkImport {
    static func payload(plan: BarkImportPlan, root: URL, profiles: Set<String>, spaces: Set<String>,
                        pinned: Bool, open: Bool, folders: Bool, bookmarks: Bool,
                        history: Bool, extensions: Bool, request: String) throws -> String {
        guard !profiles.isEmpty,
              !history || profiles.isDisjoint(with: plan.unavailableHistoryProfiles),
              !extensions || profiles.isDisjoint(with: plan.unavailableExtensionProfiles),
              !bookmarks || profiles.isDisjoint(with: plan.unavailableBookmarkProfiles) else {
            throw BarkImportError.unavailableCategory
        }
        var output: [[String: Any]] = []
        var tabCount = 0, spaceCount = 0
        for directory in profiles.sorted() {
            let source = BarkImport.identifier(root.resolvingSymlinksInPath().standardizedFileURL.path + "/" + directory)
            let selected = plan.spaces.filter { $0.profileDirectory == directory && spaces.contains($0.id) }
            var importedSpaces: [[String: Any]] = []
            var nodes: [[String: Any]] = []
            func node(_ id: String, _ parent: String, _ title: String, _ url: String? = nil) -> [String: Any] {
                var value: [String: Any] = ["id": id, "parent": parent, "title": title]
                if let url { value["url"] = url }
                return value
            }
            for item in selected {
                let tabs = item.tabs.filter { $0.pinned ? pinned : open }
                tabCount += tabs.count
                importedSpaces.append(["id": BarkImport.identifier(source + item.id), "name": item.space.name,
                                       "theme": item.space.theme.rawValue, "emoji": item.space.emoji,
                                       "tabs": tabs.map { ["id": $0.id, "title": $0.title, "url": $0.url, "pinned": $0.pinned] as [String: Any] }])
                if folders {
                    let parent = "space/" + item.id
                    nodes.append(node(parent, "", item.space.name))
                    for folder in item.folders {
                        nodes.append(node(folder.id, folder.parentID ?? parent, folder.title))
                    }
                    // Keep the full pinned folder tree in Bookmarks even when
                    // the user elects not to reopen its tabs in the sidebar.
                    for tab in item.tabs where tab.pinned {
                        nodes.append(node("tab/" + tab.id, tab.folderID ?? parent, tab.title, tab.url))
                    }
                }
            }
            // Profiles without selected spaces still need a place in Bark's
            // space catalog, including a durable source-to-profile mapping.
            let name = plan.profileNames[directory] ?? (directory == "Default" ? "Personal" : directory)
            if importedSpaces.isEmpty {
                importedSpaces.append(["id": BarkImport.identifier(source + "/profile"), "name": String(name.prefix(32)),
                                       "theme": "gray", "emoji": "", "tabs": []])
            }
            spaceCount += importedSpaces.count
            if bookmarks {
                for item in plan.bookmarks[directory] ?? [] { nodes.append(node(item.id, item.parent, item.title, item.url)) }
            }
            var extensionCount = 0
            if extensions, let items = plan.extensions[directory], !items.isEmpty {
                nodes.append(node("extensions", "", "Extensions to reinstall"))
                for item in items {
                    nodes.append(node("extension/" + item.id, "extensions", item.name + (item.enabled ? "" : " (disabled in source browser)"),
                                      "https://chromewebstore.google.com/detail/" + item.id))
                }
                extensionCount = items.count
            }
            let visits = history ? plan.history[directory] ?? [] : []
            guard nodes.count <= 20_000, visits.count <= BrowserState.historyLimit else { throw BarkImportError.capacity }
            output.append(["source": source, "name": "Imported — " + name, "spaces": importedSpaces,
                           "bookmarks": nodes, "extensions": extensionCount,
                           "history": visits.map { ["title": $0.title, "url": $0.url, "visitedAt": $0.visitedAt] as [String: Any] }])
        }
        guard spaceCount <= 100, tabCount <= 5_000 else { throw BarkImportError.capacity }
        let data = try JSONSerialization.data(withJSONObject: ["request": request, "profiles": output])
        guard data.count <= 64 * 1024 * 1024 else { throw BarkImportError.capacity }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ChromiumBarkImportView: View {
    @ObservedObject var model: ChromiumSidebarModel
    @Environment(\.dismiss) private var dismiss
    @State private var root = BarkImportReader.defaultRoot
    @State private var plan: BarkImportPlan?
    @State private var selectedProfiles = Set<String>()
    @State private var selectedSpaces = Set<String>()
    @State private var pinned = true
    @State private var open = true
    @State private var folders = true
    @State private var bookmarks = true
    @State private var history = true
    @State private var extensions = true
    @State private var scanning = false
    @State private var importing = false
    @State private var error: String?
    @State private var request = UUID().uuidString

    private var result: ChromiumBarkImportResult? {
        guard model.snapshot.browserImportResult?.request == request else { return nil }
        return model.snapshot.browserImportResult
    }
    private var profileIDs: [String] {
        guard let plan else { return [] }
        return Set(plan.profileNames.keys).union(plan.spaces.map(\.profileDirectory)).sorted()
    }
    private var blockedCategory: Bool {
        guard let plan else { return true }
        return (history && !selectedProfiles.isDisjoint(with: plan.unavailableHistoryProfiles)) ||
            (extensions && !selectedProfiles.isDisjoint(with: plan.unavailableExtensionProfiles)) ||
            (bookmarks && !selectedProfiles.isDisjoint(with: plan.unavailableBookmarkProfiles))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result?.success == true ? "Imported into Bark" : "Import into Bark").font(.title2.bold())
            if let result {
                resultView(result)
            } else {
                Text("Bring your spaces and browser data into separate Bark profiles. Existing Bark data is kept.")
                    .foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source browser data folder").font(.caption.bold())
                        Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choose folder…", action: chooseFolder)
                    Button("Scan again") { scan() }
                }.disabled(scanning || importing)
                if scanning {
                    HStack { ProgressView().controlSize(.small); Text("Reading browser data…") }.padding(.vertical, 20)
                } else if let plan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Profiles and spaces").font(.headline)
                            ForEach(profileIDs, id: \.self) { directory in
                                profileRow(directory, plan: plan)
                            }
                            Divider()
                            Text("Data to import").font(.headline)
                            Toggle("Pinned tabs and favorites", isOn: $pinned)
                            Toggle("Open tabs", isOn: $open)
                            Toggle("Sidebar folders as bookmarks", isOn: $folders)
                            Toggle("Bookmarks", isOn: $bookmarks)
                            Toggle("Recent browsing history", isOn: $history)
                            Toggle("Extension reinstall list", isOn: $extensions)
                            Text("Bark pins favorites and tabs from sidebar folders. The imported profile’s bookmarks preserve the folder structure. Extensions get Chrome Web Store links in each imported profile’s bookmarks so you can review and reinstall them.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("The import skips saved passwords, cookies, sign-ins, extension settings, Boosts, and Easels.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                    }.frame(maxHeight: .infinity)
                    .disabled(importing)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if blockedCategory && plan != nil && !scanning {
                    Text("A selected category is unavailable. Deselect it or quit the source browser and scan again.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Divider()
            HStack {
                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(importing && result == nil)
                Spacer()
                if importing && result == nil {
                    ProgressView().controlSize(.small)
                    Text("Importing…").foregroundStyle(.secondary)
                } else if result == nil {
                    Button("Import selected data", action: startImport).keyboardShortcut(.defaultAction)
                        .disabled(scanning || plan == nil || selectedProfiles.isEmpty || blockedCategory)
                }
            }
        }.padding(24).frame(width: 560, height: 650)
            .interactiveDismissDisabled(importing && result == nil)
            .task { scan() }
    }

    private func profileRow(_ directory: String, plan: BarkImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(plan.profileNames[directory] ?? directory, isOn: Binding(
                get: { selectedProfiles.contains(directory) },
                set: { if $0 { selectedProfiles.insert(directory) } else { selectedProfiles.remove(directory) } }))
                .font(.system(.body, weight: .semibold))
            let spaces = plan.spaces.filter { $0.profileDirectory == directory }
            ForEach(spaces) { space in
                Toggle(isOn: Binding(get: { selectedSpaces.contains(space.id) },
                                     set: { if $0 { selectedSpaces.insert(space.id) } else { selectedSpaces.remove(space.id) } })) {
                    Text("\(space.space.emoji.isEmpty ? "" : space.space.emoji + " ")\(space.space.name) · \(space.tabs.count) \(space.tabs.count == 1 ? "tab" : "tabs")")
                }.padding(.leading, 24).disabled(!selectedProfiles.contains(directory))
            }
            Text("\((plan.history[directory] ?? []).count.formatted()) history entries · \((plan.extensions[directory] ?? []).count) \((plan.extensions[directory] ?? []).count == 1 ? "extension" : "extensions")")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
        }
    }
    @ViewBuilder private func resultView(_ result: ChromiumBarkImportResult) -> some View {
        Label(result.success ? "Your import is complete." : "The import could not finish.",
              systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle")
            .foregroundStyle(result.success ? Color.green : Color.orange)
        Text("Added \(result.profiles) profiles, \(result.spaces) spaces, \(result.tabs) tabs, \(result.history.formatted()) history entries, and \(result.bookmarks) bookmarks.")
        if let expired = result.expiredHistory, expired > 0 {
            Text("\(expired.formatted()) older history entries were outside Bark’s history retention period and were skipped.").font(.caption).foregroundStyle(.secondary)
        }
        if result.extensions > 0 {
            Text("\(result.extensions) extensions are listed in the “Extensions to reinstall” folder in the imported profiles’ bookmarks.")
        }
        Text("Select an imported space to open its tabs. You can import again without duplicating items already imported.")
            .foregroundStyle(.secondary)
        if let error = result.error { Text(error).foregroundStyle(.red) }
        Spacer()
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the source browser’s Application Support folder"
        panel.message = "Choose the folder containing StorableSidebar.json and User Data."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url; scan() }
    }
    private func scan() {
        guard !scanning, !importing else { return }
        scanning = true; error = nil; plan = nil
        let folder = root
        Task { @MainActor in
            do {
                let scanned = try await Task.detached(priority: .userInitiated) { try BarkImportReader.read(folder) }.value
                plan = scanned
                selectedProfiles = Set(scanned.profileNames.keys).union(scanned.spaces.map(\.profileDirectory))
                selectedSpaces = Set(scanned.spaces.map(\.id))
            } catch {
                self.error = "Bark couldn’t read the selected folder. Quit the source browser and try again, or choose its Application Support folder. \(error.localizedDescription)"
            }
            scanning = false
        }
    }
    private func startImport() {
        guard let plan else { return }
        do {
            let payload = try ChromiumBarkImport.payload(plan: plan, root: root, profiles: selectedProfiles, spaces: selectedSpaces,
                pinned: pinned, open: open, folders: folders, bookmarks: bookmarks, history: history, extensions: extensions, request: request)
            importing = true; error = nil
            model.send("importBrowserData", text: payload)
        } catch { self.error = error.localizedDescription }
    }
}

/// Keep import discoverable even when the sidebar is collapsed.
@MainActor final class BarkImportMenu: NSObject, NSMenuItemValidation {
    static let shared = BarkImportMenu()
    private let models = NSHashTable<ChromiumSidebarModel>.weakObjects()
    private var item: NSMenuItem?
    func register(_ model: ChromiumSidebarModel) {
        models.add(model)
        guard item?.menu == nil, let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        let entry = NSMenuItem(title: "Import into Bark…", action: #selector(showImport(_:)), keyEquivalent: "")
        entry.target = self
        menu.insertItem(entry, at: min(3, menu.numberOfItems))
        item = entry
    }
    private var current: ChromiumSidebarModel? {
        models.allObjects.first { $0.hostView?.window != nil && $0.hostView?.window === NSApp.keyWindow && !$0.isIncognito }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { current != nil }
    @objc private func showImport(_ sender: Any?) { current?.browserImportRequests += 1 }
}
