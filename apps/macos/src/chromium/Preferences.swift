import AppKit
import Combine
import SwiftUI
import BarkCore

struct ChromiumSearchEngine: Decodable, Identifiable {
    let id: String
    let name: String
}

struct ChromiumPreferences: Decodable {
    let profileId: String
    let searchEngines: [ChromiumSearchEngine]
    let searchEngine: String
    let searchEditable: Bool
    let searchLoaded: Bool
    let downloadPath: String
    let downloadEditable: Bool
    let askDownload: Bool
    let askDownloadEditable: Bool
    let pictureInPictureEditable: Bool
}

@MainActor extension ChromiumSidebarModel {
    func showPreferences() {
        setSiteControlsOpen(false)
        cancelAddressEditing()
        PreferencesPresenter.shared.show(model: self)
    }

    /// Only send edits for the profile that supplied the visible preferences.
    func setPreference(_ key: String, value: String) {
        guard !isIncognito, let preferences = snapshot.preferences,
              preferences.profileId == snapshot.profileId else { return }
        let allowed: Bool
        switch key {
        case "searchEngine": allowed = preferences.searchEditable && preferences.searchEngines.contains { $0.id == value }
        case "downloadPath": allowed = preferences.downloadEditable && value.hasPrefix("/")
        case "askDownload": allowed = preferences.askDownloadEditable && ["on", "off"].contains(value)
        default: allowed = false
        }
        guard allowed else { return }
        send("setPreference", text: value, metadata: ["key": key, "profile": preferences.profileId])
    }
}

@MainActor final class PreferencesPresenter: NSObject, NSWindowDelegate {
    static let shared = PreferencesPresenter()
    private var window: NSWindow?
    private weak var model: ChromiumSidebarModel?
    private var timer: Timer?
    private var appearanceObservation: AnyCancellable?

    func show(model: ChromiumSidebarModel) {
        if self.model !== model {
            self.model?.send("preferencesState", text: "close")
            self.model = model
            window?.contentView = NSHostingView(rootView: BarkPreferencesView(model: model))
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 570),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Bark Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: BarkPreferencesView(model: model))
            window.center()
            self.window = window
        }
        // This is a separate AppKit window, so it does not inherit the
        // Chromium browser window's profile-specific appearance.
        appearanceObservation = model.$snapshot.map(\.appearance).removeDuplicates().sink { [weak self] choice in
            switch choice {
            case "light": self?.window?.appearance = NSAppearance(named: .aqua)
            case "dark": self?.window?.appearance = NSAppearance(named: .darkAqua)
            default: self?.window?.appearance = nil
            }
        }
        model.send("preferencesState", text: "open")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.send("preferencesState", text: "open") }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func detach(_ model: ChromiumSidebarModel) {
        if self.model === model { window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        appearanceObservation = nil
        model?.send("preferencesState", text: "close")
        window?.contentView = nil
        model = nil
    }
}

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", spaces = "Spaces & Profiles"
    case tabs = "Tabs", links = "Links", shortcuts = "Shortcuts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .spaces: return "person.crop.rectangle"
        case .tabs: return "rectangle.on.rectangle"
        case .links: return "link"
        case .shortcuts: return "keyboard"
        }
    }
}

struct BarkPreferencesView: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var section: PreferencesSection = .general
    @State private var editingSpace: SpaceSettingsTarget?
    @State private var spaceProfile = ""
    @State private var newProfileName = ""
    @State private var profileToDelete: ChromiumProfile?
    @State private var newSpace = false
    @AppStorage(EyeRestReminder.defaultsKey) private var eyeRest = false
    private var preferences: ChromiumPreferences? { model.snapshot.preferences }
    private var features: ChromiumFeatures { model.snapshot.features ?? ChromiumFeatures() }
    private var profiles: [SpaceProfileChoice] {
        (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(PreferencesSection.allCases) { item in
                    Button { section = item } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.system(size: 22, weight: .regular)).frame(height: 25)
                            Text(item.rawValue).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(section == item ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                        .foregroundStyle(section == item ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if model.isIncognito {
                VStack(spacing: 12) {
                    Image(systemName: "eyeglasses").font(.largeTitle)
                    Text("Open Settings from a regular window").font(.headline)
                    Text("Private windows keep their browsing separate from saved profile settings.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    switch section {
                    case .general: general
                    case .appearance: appearance
                    case .spaces: spaces
                    case .tabs: tabs
                    case .links: links
                    case .shortcuts: shortcuts
                    }
                }.formStyle(.grouped)
            }
        }.frame(width: 720, height: 570)
            .preferredColorScheme(model.snapshot.appearance == "light" ? .light : model.snapshot.appearance == "dark" ? .dark : nil)
            .sheet(item: $editingSpace) { target in
                SpaceEditor(draft: SpaceDraft(Space(id: target.space.id, name: target.space.displayName,
                    color: target.space.theme ?? "gray", icon: model.emoji(for: target.space)), style: target.space.style),
                    profiles: profiles, profileID: $spaceProfile, originalProfileID: target.space.profile) { name, theme, emoji, style in
                    model.saveSpaceSettings(target.space, name: name, theme: theme, emoji: emoji, style: style, profile: spaceProfile)
                    editingSpace = nil
                }
            }
            .sheet(isPresented: $newSpace) {
                SpaceEditor(draft: SpaceDraft(), profiles: profiles, profileID: $spaceProfile) { name, theme, emoji, style in
                    model.send("createSpace", text: name, metadata: ["theme": theme.rawValue, "emoji": emoji, "profile": spaceProfile]
                        .merging(style.metadata) { $1 })
                    newSpace = false
                }
            }
            .alert(item: $profileToDelete) { profile in
                let message = "This permanently deletes this profile’s Spaces, tabs, bookmarks, saved passwords, and browsing history from this Mac."
                let lastProfile = model.snapshot.profiles?.count == 1
                return Alert(title: Text("Delete “\(profile.name)”?"),
                             message: Text(lastProfile ? message + " Bark will open a new, empty profile." : message),
                             primaryButton: .cancel(),
                             secondaryButton: .destructive(Text("Delete Profile")) {
                                 model.send("deleteProfile", text: profile.id)
                             })
            }
    }

    @ViewBuilder private var general: some View {
        Section("Profile: \(model.activeProfileName)") {
            if let preferences {
                Picker("Search engine", selection: Binding(get: { preferences.searchEngine }, set: { model.setPreference("searchEngine", value: $0) })) {
                    ForEach(preferences.searchEngines) { Text($0.name).tag($0.id) }
                    if preferences.searchEngines.isEmpty { Text(preferences.searchLoaded ? "Unavailable" : "Loading…").tag("") }
                }.disabled(!preferences.searchEditable || !preferences.searchLoaded)
                if !preferences.searchEditable { managedNote }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Download location")
                        Text(preferences.downloadPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choose…") { chooseDownloadFolder() }.disabled(!preferences.downloadEditable)
                }
                Toggle("Ask where to save each download", isOn: Binding(get: { preferences.askDownload }, set: { model.setPreference("askDownload", value: $0 ? "on" : "off") }))
                    .disabled(!preferences.askDownloadEditable)
                if !preferences.downloadEditable || !preferences.askDownloadEditable { managedNote }
            } else { ProgressView().controlSize(.small).accessibilityLabel("Loading preferences") }
        }
        Section("Eye comfort · All profiles") {
            Toggle("Remind me to rest my focus", isOn: Binding(get: { eyeRest }, set: { EyeRestReminder.shared.setEnabled($0) }))
            Text("Every 20 minutes, look at something about 20 feet away for 20 seconds. Your focusing muscles tire from holding at screen distance.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Advanced") {
            advanced("Search engine settings", path: "searchEngines")
            advanced("Privacy and security", path: "privacy")
            advanced("Passwords and autofill", path: "autofill")
            advanced("Default browser", path: "defaultBrowser")
            advanced("All Chromium settings", path: "")
        }
        Section("Factory reset") {
            Button("Reset Bark to factory settings…", role: .destructive) {
                model.send("showFactoryReset")
                PreferencesPresenter.shared.detach(model)
            }
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Profile: \(model.activeProfileName)") {
            Picker("Appearance", selection: Binding(get: { model.snapshot.appearance ?? "system" }, set: { model.send("appearance", text: $0) })) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
        }
        Section("Current space") {
            if let space = model.activeSpace {
                HStack {
                    SpaceIcon(emoji: model.emoji(for: space), tint: space.themeValue.accent)
                    Text(space.displayName)
                    Spacer()
                    Button("Edit theme…") { edit(space) }
                }
            }
        }
        Section("Sidebar · All profiles") {
            HStack {
                Text("Width")
                Slider(value: Binding(get: { model.snapshot.sidebarWidth ?? 260 }, set: { model.send("resize", width: $0) }), in: 200...400, step: 1)
                    .accessibilityLabel("Sidebar width")
                Text("\(Int(model.snapshot.sidebarWidth ?? 260)) pt").monospacedDigit().frame(width: 48)
            }
        }
    }

    @ViewBuilder private var spaces: some View {
        Section {
            Text("Spaces organize tabs. Spaces using the same profile share sign-ins, history, downloads, and extensions.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.snapshot.spaces) { space in
                HStack(spacing: 10) {
                    SpaceIcon(emoji: model.emoji(for: space), tint: space.themeValue.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(space.displayName)
                        Text(model.snapshot.profiles?.first(where: { $0.id == space.profile })?.name ?? "Profile")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { edit(space) }
                }
            }
            Button("New space…") { spaceProfile = model.snapshot.profileId ?? ""; newSpace = true }
        } header: { Text("Spaces") }
        Section("Profiles") {
            ForEach(model.snapshot.profiles ?? []) { profile in
                let count = model.snapshot.spaces.filter { $0.profile == profile.id }.count
                HStack {
                    Text(profile.name)
                    Spacer()
                    Text(count == 1 ? "1 space" : "\(count) spaces").foregroundStyle(.secondary)
                    Button("Delete…", role: .destructive) { profileToDelete = profile }
                        .accessibilityLabel("Delete profile \(profile.name)")
                }
            }
            HStack {
                TextField("New profile name", text: $newProfileName)
                Button("Create") {
                    model.send("createProfile", text: String(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)))
                    newProfileName = ""
                }.disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Advanced profile management…") { model.send("manageSpaces") }
        }
    }

    @ViewBuilder private var tabs: some View {
        Section("Automatic archive · All profiles") {
            Picker("Archive inactive tabs after", selection: Binding(get: { features.archiveAfterHours }, set: { model.send("setArchiveAfter", text: String($0)) })) {
                Text("Never").tag(0)
                Text("12 hours").tag(12)
                Text("24 hours").tag(24)
                Text("7 days").tag(168)
                Text("30 days").tag(720)
                if ![0, 12, 24, 168, 720].contains(features.archiveAfterHours) { Text("\(features.archiveAfterHours) hours").tag(features.archiveAfterHours) }
            }
            Text("Pinned tabs, favorites, the active tab, and tabs playing audio stay open.").font(.caption).foregroundStyle(.secondary)
            Button("View this space’s archive…") { model.showArchive(); model.hostView?.window?.makeKeyAndOrderFront(nil) }
        }
        Section("New tabs") {
            Text("Click New tab in the sidebar, click the address bar, or press ⌘T to search or enter an address. The new tab appears in the sidebar when you open a page.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var links: some View {
        Section("Link previews · All profiles") {
            Toggle("Preview links from pinned tabs in Peek", isOn: Binding(get: { features.peek }, set: { model.send("setPeek", text: $0 ? "on" : "off") }))
            Toggle("Open links from other apps in a Little window", isOn: Binding(get: { features.littleWindow }, set: { model.send("setLittleWindow", text: $0 ? "on" : "off") }))
            GlobalLittleShortcutSetting(features: features) { model.send("setGlobalLittleShortcut", text: $0 ? "on" : "off") }
        }
        Section("Profile: \(model.activeProfileName)") {
            Toggle("Picture in Picture when switching tabs", isOn: Binding(get: { features.autoPictureInPicture }, set: { model.send("setAutoPictureInPicture", text: $0 ? "on" : "off") }))
                .disabled(preferences?.pictureInPictureEditable != true)
            if preferences?.pictureInPictureEditable == false { managedNote }
            Text("Individual websites can override this in Site controls.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcuts: some View {
        ForEach(["Sidebar and tabs", "Spaces", "Split view"], id: \.self) { title in
            Section(title) {
                ForEach(Array(BarkShortcut.all.filter { $0.section == title && !$0.keys.isEmpty }.enumerated()), id: \.offset) { _, shortcut in
                    HStack { Text(shortcut.title); Spacer(minLength: 20); Text(shortcut.keys).foregroundStyle(.secondary).fixedSize() }
                }
            }
        }
        Section("Browser") {
            ForEach(Array(BarkShortcut.builtIn.enumerated()), id: \.offset) { _, shortcut in
                HStack { Text(shortcut.title); Spacer(); Text(shortcut.keys).foregroundStyle(.secondary) }
            }
            HStack { Text("Open Settings"); Spacer(); Text("⌘ ,").foregroundStyle(.secondary) }
        }
    }

    private var managedNote: some View { Text("Some settings are controlled by your organization or an extension.").font(.caption).foregroundStyle(.secondary) }
    private func advanced(_ title: String, path: String) -> some View {
        Button { model.send("advancedSettings", text: path) } label: {
            HStack { Text(title); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
        }.buttonStyle(.plain)
    }
    private func edit(_ space: ChromiumSpace) {
        spaceProfile = space.profile ?? model.snapshot.profileId ?? ""
        editingSpace = SpaceSettingsTarget(space: space)
    }
    private func chooseDownloadFolder() {
        let profile = model.snapshot.profileId
        let panel = NSOpenPanel()
        panel.title = "Download location"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.map { URL(fileURLWithPath: $0.downloadPath, isDirectory: true) }
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, model.snapshot.profileId == profile, let url = panel.url else { return }
            model.setPreference("downloadPath", value: url.path)
        }
    }
}
