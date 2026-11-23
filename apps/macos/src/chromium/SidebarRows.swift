import AppKit
import Combine
import SwiftUI
import BarkCore

// A shared, understated hover treatment for navigation, tab actions and spaces.
typealias SidebarButtonStyle = BarkControlStyle

// A pale, gently raised surface marks selected tabs, Favorites and spaces.
struct SidebarSelectionBackground: View {
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

struct TabLoadingDot: View {
    var body: some View {
        Circle().fill(.primary.opacity(0.72)).frame(width: 5, height: 5)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ChromiumTabRow: View {
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
                    Button(tab.pinned ? "Unpin tab" : "Pin tab") { model.send("pin", id: tab.id) }
                }
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
                Button(tab.closeLabel) { model.close(tab) }
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
            } else if !tab.isBlank, let favicon { Image(nsImage: favicon).resizable().scaledToFit() }
            else { Image(systemName: "square.fill").foregroundStyle(.secondary) }
        }.frame(width: 16, height: 16)
    }
    private var muteLabel: String { tab.muted == true ? "Unmute tab" : "Mute tab" }
    private var audioDescription: String { tab.muted == true ? "Muted. " : tab.audible == true ? "Playing audio. " : "" }
    private var accessibilityDescription: String {
        let parts: [String] = [tab.active ? "Selected. " : "", tab.loading ? "Loading. " : "", tab.split != nil ? "In a split view. " : "",
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
            Button { model.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
            }.help(tab.closeLabel).accessibilityLabel(Text(tab.closeLabel))
                .buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                .opacity(hovered ? 1 : 0)
                .disabled(!hovered).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }.frame(width: 24, height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }

    private var row: some View {
        HStack(spacing: 9) {
            leading
            titleView
            trailing
        }.padding(.leading, 11 + indent).padding(.trailing, 12).frame(height: 36)
            .overlay(alignment: .trailing) {
                if tab.loading { TabLoadingDot().padding(.trailing, 7) }
            }
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
            .accessibilityAction(named: Text(tab.closeLabel)) { model.close(tab) }
            .accessibilityAction(named: "Move to New Window") { model.send("detachTab", id: tab.id) }
            .accessibilityAction(named: tab.pinned ? "Unpin tab" : "Pin tab") { model.send("pin", id: tab.id) }
            .accessibilityAction(named: muteLabel) { model.send("mute", id: tab.id) }
            .accessibilityAction(named: "Rename tab") { startRenaming() }
            .contextMenu { menuItems }
    }

}

// A folder of pinned tabs. Click to open or close it; double-click to rename.
struct SidebarFolderHeader: View {
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
struct FavoriteTile: View {
    @ObservedObject var model: ChromiumSidebarModel
    let tab: ChromiumTab
    let showsTitle: Bool
    @State private var hovered = false
    private var title: String { tab.displayTitle }
    var body: some View {
        ZStack {
            if tab.active {
                SidebarSelectionBackground(tint: model.theme.accent, cornerRadius: 12)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.13 : 0.10))
            }
            HStack(spacing: 8) {
                Group {
                    if !tab.isBlank, let icon = tab.faviconImage { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "square.fill").foregroundStyle(.secondary) }
                }.frame(width: 14, height: 14)
                if showsTitle {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
            }.padding(.horizontal, showsTitle ? 16 : 0)
        }.frame(height: 46)
            .overlay(alignment: .topTrailing) {
                if tab.loading { TabLoadingDot().padding(7) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).onTapGesture { model.send("select", id: tab.id) }
            .onHover { hovered = $0 }.help(title)
            .accessibilityElement().accessibilityLabel(title).accessibilityAddTraits(.isButton)
            .accessibilityValue((tab.active ? "Selected. Favorite" : "Favorite") + (tab.loading ? ". Loading" : ""))
            .accessibilityAction { model.send("select", id: tab.id) }
            .contextMenu {
                Button(tab.muted == true ? "Unmute tab" : "Mute tab") { model.send("mute", id: tab.id) }
                Button("Remove from Favorites") { model.send("moveTab", id: tab.id, metadata: ["zone": "unpinned", "before": ""]) }
                Button("Move to New Window") { model.send("detachTab", id: tab.id) }
                Button(tab.closeLabel) { model.close(tab) }
            }
    }
}

// Closes a tab on middle click, which SwiftUI gestures cannot observe. The
// view takes part in hit testing only for that button, so clicks, hover,
// drags and context menus still reach the row beneath it.
struct MiddleClickCatcher: NSViewRepresentable {
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

struct ChromiumAddressBar: View {
    @ObservedObject var model: ChromiumSidebarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?
    private enum Control: Hashable { case address, siteInfo, extensions }
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

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
                .foregroundStyle(model.addressSummary.isEmpty ? Color.secondary : Color.primary.opacity(contrast == .increased ? 1 : 0.78))
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13).padding(.trailing, 65).frame(height: 36)
                .contentShape(Self.shape)
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
            .background(Color.primary.opacity(showControls ? 0.16 : 0.12), in: Self.shape)
            .overlay {
                Self.shape
                    .strokeBorder(Color.primary.opacity(model.editingAddress || contrast == .increased ? 0.30 : 0.10), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Self.shape)
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
struct ChromiumSidebarHeader: View {
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
