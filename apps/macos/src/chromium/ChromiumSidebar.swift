import AppKit
import Combine
import SwiftUI
import BarkCore

private enum DropZone: String { case favorites, pinned, unpinned }

private enum TabDropTarget: Equatable {
    case sidebar(zone: DropZone, before: Int?)
    case split(SplitDropController.Side)
    case newWindow
}

/// Map a reorder onto the original layout slots. Only the contents move, so
/// an animating neighbor never changes the hit test for the next mouse event.
struct TabReorderPreview {
    let landing: CGRect
    let before: Int?
    let changed: Bool
    var offsets: [Int: CGSize] = [:]

    init?(id: Int, order: [Int], frames: [Int: CGRect], center: CGPoint, grid: Bool) {
        guard let source = order.firstIndex(of: id) else { return nil }
        let slots = order.indices.compactMap { index in frames[order[index]].map { (index: index, frame: $0) } }
        // In a wrapped Favorites grid, choose the row first. The last row
        // can have fewer tiles than the one above it.
        guard let (destination, frame) = slots.min(by: { lhs, rhs in
            if grid && lhs.frame.midY == rhs.frame.midY {
                return abs(lhs.frame.midX - center.x) < abs(rhs.frame.midX - center.x)
            }
            return abs(lhs.frame.midY - center.y) < abs(rhs.frame.midY - center.y)
        }) else { return nil }
        landing = frame
        changed = source != destination
        let next = destination < source ? destination : destination + 1
        before = next < order.count ? order[next] : nil
        // A collapsed folder can hide siblings between two visible slots.
        // Keep their logical order for the command and shift the visible rows.
        for (earlier, later) in zip(slots, slots.dropFirst()) {
            let (row, slot) = source < destination ? (later, earlier) : (earlier, later)
            guard row.index != source,
                  (min(source, destination)...max(source, destination)).contains(row.index) else { continue }
            offsets[order[row.index]] = CGSize(width: slot.frame.minX - row.frame.minX,
                                               height: slot.frame.minY - row.frame.minY)
        }
    }
}

/// A tab being dragged in the sidebar. Positions are in the sidebar's
/// coordinate space.
private struct TabDrag {
    let session = UUID()
    let id: Int
    let fromFavorites: Bool
    /// Pointer position within the tab when the drag began.
    let grab: CGSize
    let sourceFrame: CGRect
    let indent: CGFloat
    var pointer: CGPoint
    var origin: CGPoint { CGPoint(x: pointer.x - grab.width, y: pointer.y - grab.height) }
    var center: CGPoint { CGPoint(x: origin.x + sourceFrame.width / 2, y: origin.y + sourceFrame.height / 2) }
    var preview: TabReorderPreview?
    var revealsPins = false
    /// Released; waiting for Chromium's new tab order.
    var releasedAt: TimeInterval?
    var dropped: Bool { releasedAt != nil }
    var target: TabDropTarget?
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct EnclosingScrollView: NSViewRepresentable {
    let configure: (NSScrollView) -> Void
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { view.configure = configure; view.resolve() }

    final class Reader: NSView {
        var configure: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.resolve() }
        }
        func resolve() {
            if let scrollView = enclosingScrollView { configure?(scrollView) }
        }
    }
}

/// A separate native host places this target across the sidebar/page boundary.
/// Its width never becomes padding inside the sidebar or covers its scrollbar.
private struct SidebarResizeHandle: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var startWidth: Double?
    @State private var hovered = false
    private var width: Double { model.hostView.map { Double($0.bounds.width) } ?? model.snapshot.sidebarWidth ?? 260 }

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Color.primary.opacity(hovered || startWidth != nil ? 0.15 : 0)
                    .frame(width: 2).allowsHitTesting(false)
            }
            .onHover {
                hovered = $0
                if $0 { NSCursor.resizeLeftRight.set() }
                else if startWidth == nil { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                if startWidth == nil { startWidth = width }
                model.resizingSidebar = true
                model.send("resize", width: min(400, max(200, (startWidth ?? width) + value.translation.width)))
            }.onEnded { _ in
                startWidth = nil
                model.resizingSidebar = false
                NSCursor.arrow.set()
            })
            .onDisappear { startWidth = nil; model.resizingSidebar = false }
            .accessibilityLabel("Resize sidebar").help("Drag to resize sidebar")
            .accessibilityAdjustableAction { model.send("resize", width: min(400, max(200, width + ($0 == .increment ? 20 : -20)))) }
    }
}

@MainActor private final class SidebarResizeHostingView: NSHostingView<SidebarResizeHandle> {
    init(model: ChromiumSidebarModel) {
        super.init(rootView: SidebarResizeHandle(model: model))
        sizingOptions = []
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }
    @available(*, unavailable) required init(rootView: SidebarResizeHandle) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
}

struct ChromiumSidebar: View {
    @ObservedObject var model: ChromiumSidebarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: SpaceDraft?
    @State private var settingsSpace: SpaceSettingsTarget?
    @State private var settingsProfileID = ""
    @State private var draftProfileID = ""
    @State private var creatingProfile = false
    @State private var showingImport = false
    @State private var profileName = ""
    @State private var tabDrag: TabDrag?
    @GestureState private var tabGestureActive = false
    // Frames reported outside the pager, and by the active page inside it.
    @State private var sidebarFrames: [Int: CGRect] = [:]
    @State private var pageFrames: [Int: CGRect] = [:]
    private var pagerOrigin: CGPoint { sidebarFrames[Self.pagerKey]?.origin ?? .zero }
    /// Every reported frame, in the sidebar's coordinate space.
    private var tabFrames: [Int: CGRect] {
        let origin = pagerOrigin
        return sidebarFrames.merging(pageFrames.mapValues { $0.offsetBy(dx: origin.x, dy: origin.y) }) { $1 }
    }
    @State private var archiveNotice: ArchiveNotice?
    @State private var folderToRename: String?
    @State private var knownFolders: Set<String> = []
    private var floating: Bool { model.snapshot.sidebarCollapsed == true }
    // Docked pages already contribute a 7 pt frame beside the sidebar. Count
    // that toward the visible 8 pt margin instead of adding it a second time.
    private var trailingInset: CGFloat { floating ? 8 : 1 }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ChromiumAddressBar(model: model).padding(.leading, 8).padding(.trailing, trailingInset).padding(.top, 5).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(frameReporter(Self.addressKey))
                    .overlay { if showFavoritesHint { favoritesHint.padding(.leading, 8).padding(.trailing, trailingInset).padding(.top, 5).padding(.bottom, 8) } }
                if !favorites.isEmpty && !model.crossProfileMotion {
                    favoritesGrid.padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The pages slide as a Core Animation layer.
                SpacePager(driver: model.pager, pages: pagerPages)
                    // minHeight 0: a long preview list must be clipped here, not
                    // make the sidebar taller than its window (which shifts and
                    // squeezes the whole sidebar while swiping).
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .background(frameReporter(Self.pagerKey))
                BrowserNoticeSummary(model: model).padding(.horizontal, 10).padding(.top, model.activeNotices.isEmpty ? 0 : 6)
                if let media = model.snapshot.media {
                    SidebarMediaPlayer(model: model, media: media).padding(.horizontal, 10).padding(.top, 6)
                        .transition(.opacity)
                }
                if !model.isIncognito {
                    if let notice = archiveNotice {
                        archiveBanner(notice).padding(.horizontal, 10).padding(.top, 6).transition(.opacity)
                    }
                    spaceDock.padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 11)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: Self.dragSpace)
                .onPreferenceChange(TabFramesKey.self) { sidebarFrames = $0 }
                .onChange(of: tabOrder) { _ in tabOrderChanged() }
                .onChange(of: model.archiveRequests) { _ in archiveTabs() }
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) { dragOverlay }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                // The native backdrop spans this content and the caption row.
                .clipShape(RoundedRectangle(cornerRadius: floating ? 12 : 0, style: .continuous))
        }.accessibilityHidden(model.snapshot.sidebarCollapsed == true && model.snapshot.sidebarRevealed != true)
            .onChange(of: tabGestureActive) { dragging in
                if !dragging {
                    model.draggingTab = false
                    model.splitDrop.end()
                    if tabDrag?.dropped == false { tabDrag = nil }
                }
            }
            .onDisappear { model.draggingTab = false; model.resizingSidebar = false; model.splitDrop.end() }
            .onChange(of: draft?.id) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: settingsSpace?.id) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.activeSpaceId) { _ in archiveNotice = nil; knownFolders = Set(model.folders.map(\.id)) }
            .onChange(of: model.folders) { folders in
                // Offer to name a folder the person just made.
                let ids = Set(folders.map(\.id))
                if model.renameNextFolder, let added = folders.last(where: { !knownFolders.contains($0.id) }) {
                    model.renameNextFolder = false
                    folderToRename = added.id
                }
                knownFolders = ids
            }
            .onAppear { knownFolders = Set(model.folders.map(\.id)) }
            .onChange(of: model.browserImportRequests) { _ in if !model.isIncognito { showingImport = true } }
            .onChange(of: showingImport) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: creatingProfile) { _ in model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .onChange(of: model.snapshot.sidebarRevealed) { revealed in
            if floating && revealed != true && !model.editingAddress { model.cancelAddressEditing() }
        }
            .sheet(item: $settingsSpace) { target in
                SpaceEditor(draft: SpaceDraft(Space(id: target.space.id, name: target.space.displayName,
                                                    color: target.space.theme ?? "gray", icon: model.emoji(for: target.space)),
                                              style: target.space.style),
                            profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) },
                            profileID: $settingsProfileID, originalProfileID: target.space.profile) { name, theme, emoji, style in
                    model.saveSpaceSettings(target.space, name: name, theme: theme, emoji: emoji, style: style, profile: settingsProfileID)
                    settingsSpace = nil
                }
            }
            .sheet(item: $draft) { draft in
                SpaceEditor(draft: draft, profiles: (model.snapshot.profiles ?? []).map { SpaceProfileChoice(id: $0.id, name: $0.name) }, profileID: $draftProfileID) { name, theme, emoji, style in
                    model.send("createSpace", text: name, metadata: ["theme": theme.rawValue, "emoji": emoji, "profile": draftProfileID]
                        .merging(style.metadata) { $1 })
                    self.draft = nil
                }
            }
            .sheet(isPresented: $model.archivePresented) { ArchiveBrowserView(model: model) }
            .onChange(of: model.archivePresented) { _ in model.presentingSidebarUI = model.archivePresented || showingImport || creatingProfile || settingsSpace != nil || draft != nil }
            .sheet(isPresented: $showingImport) { ChromiumBarkImportView(model: model) }
            .sheet(isPresented: $creatingProfile) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("New profile").font(.headline)
                    TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder)
                    Text("Spaces assigned to this profile share its sign-ins, history, and extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { creatingProfile = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Create") {
                            model.send("createProfile", text: String(profileName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)))
                            creatingProfile = false
                        }.keyboardShortcut(.defaultAction).disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 340)
            }

    }

    // The pager's pages: the Space on screen, and the neighbors a swipe or
    // slide reveals. Each is keyed by its Space, and the incoming page is
    // built exactly like the active one, so landing on it changes which page
    // takes input without rebuilding its rows.
    private var pagerPages: [SpacePager.Page] {
        let active = model.outgoingSpace
        var pages = [SpacePager.Page(id: active?.id ?? "", slot: 0,
                                     content: spacePage(active, tabs: model.outgoingTabs, emoji: model.outgoingEmoji,
                                                        tint: model.outgoingTheme.accent, interactive: true))]
        for direction in [CGFloat(1), -1] {
            guard let neighbor = model.swipePage(in: direction), neighbor.id != active?.id else { continue }
            pages.append(SpacePager.Page(id: neighbor.id, slot: direction > 0 ? -1 : 1,
                                         content: spacePage(neighbor, tabs: model.previewTabs(for: neighbor),
                                                            emoji: model.emoji(for: neighbor),
                                                            tint: neighbor.themeValue.accent, interactive: false)))
        }
        return pages
    }

    // A Space's heading and tabs. This is the part that moves while swiping
    // between spaces; the address field and dock stay in place. Only the
    // active page is interactive. Each page is its own SwiftUI host, so the
    // active one reports its row frames and drag locations in its own space
    // (see `pagerOrigin`).
    private func spacePage(_ space: ChromiumSpace?, tabs: [ChromiumTab], emoji: String, tint: Color,
                           interactive: Bool) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            // Across profiles, Favorites slide with their space, in the
            // same place as the fixed grid they stand in for.
            if model.crossProfileMotion {
                let pageFavorites = model.previewFavorites(for: space)
                if !pageFavorites.isEmpty {
                    previewFavoritesGrid(pageFavorites)
                        .padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let space, !model.isIncognito {
                spaceHeading(space, emoji: emoji, tint: tint)
                    .contextMenu {
                        Button("New Folder") { model.requestNewFolder() }
                        Button("New space…", action: newSpace)
                        Menu("Switch Space") {
                            ForEach(model.snapshot.spaces) { other in
                                Button((other.active ? "✓ " : "") + other.displayName) { model.requestSpaceSelection(other) }
                            }
                        }.disabled(model.switchingSpaceProfile)
                        Divider()
                        spaceMenu(for: space)
                    }
            } else {
                HStack(spacing: 8) {
                    if model.isIncognito { Image(systemName: "eyeglasses") }
                    else { SpaceIcon(emoji: emoji, tint: tint) }
                    Text(model.activeSpaceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.foregroundStyle(.secondary).padding(.leading, 18)
                    .frame(height: 36).padding(.bottom, 4)
            }
            ScrollView(.vertical) {
                tabList(tabs, space: space, interactive: interactive)
                    .background(EnclosingScrollView { scrollView in
                        guard interactive else { return }
                        model.tabScrollView = scrollView
                        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
                        scrollView.autohidesScrollers = true
                        if let scroller = scrollView.verticalScroller, scroller.controlSize != .small {
                            scroller.controlSize = .small
                            scrollView.tile()
                        }
                    }.allowsHitTesting(false))
            }.scrollIndicators(interactive ? .automatic : .hidden)
                // The scrollbar overlays only the tabs; the resize target is
                // hosted on the outer boundary, without reserving row width.
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(interactive && !model.spaceInMotion)
        .accessibilityHidden(!interactive)
        .coordinateSpace(name: Self.dragSpace)
        .onPreferenceChange(TabFramesKey.self) { if interactive { pageFrames = $0 } })
    }

    private func spaceHeading(_ space: ChromiumSpace, emoji: String, tint: Color) -> some View {
        SpaceHeaderRow(name: space.displayName, emoji: emoji, tint: tint, pinsCollapsed: space.pinsCollapsed == true) {
            guard !model.spaceInMotion, model.activeSpace?.id == space.id else { return }
            model.send("togglePinnedSection", metadata: ["space": space.id])
        } openSettings: {
            guard !model.spaceInMotion, model.activeSpace?.id == space.id else { return }
            showSettings(for: space)
        }
        .padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tabList(_ tabs: [ChromiumTab], space: ChromiumSpace?, interactive: Bool) -> some View {
        let pinned = tabs.filter(\.pinned)
        let folders = space?.folders ?? []
        let pinsCollapsed = space?.pinsCollapsed == true
        let entries = ChromiumFolderTree.entries(folders: folders, tabs: pinned)
        let showAllPins = !pinsCollapsed || (interactive && tabDrag?.revealsPins == true)
        let unpinned = tabs.filter { !$0.pinned }
        let hasUnpinned = !unpinned.isEmpty
        let animation: Animation? = interactive && !reduceMotion && tabDrag == nil && !model.spaceInMotion
            ? .easeInOut(duration: 0.20) : nil
        let fading = animation != nil && !hasUnpinned && !model.clearingTabs.isEmpty
        let showClear = hasUnpinned || fading
        // Reuse the divider as the pin target so rows stay under the pointer.
        let pinZone = interactive && tabDrag?.dropped == false && pinned.isEmpty && (dropZone == .pinned || !hasUnpinned)
        return VStack(spacing: 0) {
            if !entries.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        let expanded = showAllPins || entry.tab?.visibleWhenCollapsed == true
                        reorderSlot(interactive && expanded ? entry.tab?.id : nil) {
                            SidebarFoldingRows(expanded: expanded) {
                                if let folder = entry.folder {
                                    SidebarFolderHeader(model: model, folder: folder, count: entry.count, renameTarget: $folderToRename)
                                        .padding(.leading, CGFloat(entry.depth) * 14)
                                } else if let tab = entry.tab {
                                    tabRow(tab, interactive: interactive, indent: showAllPins ? CGFloat(entry.depth) * 14 : 0)
                                }
                            }
                        }
                        .padding(.bottom, expanded ? 3 : 0)
                    }
                }
            }
            // The divider below the pins hosts the Clear button for unpinned tabs.
            // Incognito windows cannot pin, so they have nothing to divide.
            if !model.isIncognito && (!pinned.isEmpty || !folders.isEmpty || showClear || pinZone) {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    if showClear {
                        Button { if interactive { archiveTabs() } } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold))
                                Text("Clear").font(.system(size: 11, weight: .medium))
                            }.padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
                        }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
                            .help("Archive unpinned tabs (⇧⌘K)").accessibilityLabel("Archive unpinned tabs")
                            .opacity(fading ? 0 : 1).disabled(fading).accessibilityHidden(fading)
                    }
                }.padding(.leading, 9).padding(.trailing, 2).padding(.vertical, showClear ? 6 : 12)
                    .frame(minHeight: pinZone ? 32 : nil)
                    .opacity(pinZone ? 0 : 1)
                    .overlay { if pinZone { dropHint("pin", "Drop here to pin", targeted: dropZone == .pinned) } }
                    .background { if interactive { frameReporter(Self.pinBoundaryKey) } }
            }
            Button { model.send("new") } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus").frame(width: 16).accessibilityHidden(true)
                    Text("New tab")
                }.font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(SidebarButtonStyle()).help("New tab (⌘T)")
                .background { if interactive { frameReporter(Self.newTabKey) } }
            LazyVStack(spacing: 3) {
                ForEach(fading ? model.clearingTabs : unpinned) { tab in
                    reorderSlot(interactive ? tab.id : nil) { tabRow(tab, interactive: interactive) }
                }
            }
            .padding(.top, hasUnpinned || fading ? 3 : 0)
            .opacity(fading ? 0 : 1)
            .offset(y: fading ? -10 : 0)
            .animation(fading ? .timingCurve(0.25, 0.1, 0.25, 1, duration: ChromiumSidebarModel.clearFadeDuration) : nil,
                       value: fading)
            .allowsHitTesting(!fading).accessibilityHidden(fading)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8).padding(.trailing, trailingInset).padding(.bottom, 12)
            .animation(animation, value: pinsCollapsed)
            .animation(animation, value: fading)
    }

    // MARK: Favorites and tab dragging
    // Drag across the divider to pin or unpin, or into Favorites to show a tab in every space.

    private var favorites: [ChromiumTab] { model.isIncognito ? [] : model.snapshot.favorites ?? [] }

    private var favoritesGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(favorites.count, 4))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(favorites) { tab in
                reorderSlot(tab.id) {
                    FavoriteTile(model: model, tab: tab, showsTitle: favorites.count == 1)
                        .opacity(tabDrag?.id == tab.id ? 0 : 1)
                        .simultaneousGesture(tabDragGesture(tab.id, fromFavorites: true),
                                             including: tab.isElsewhere ? .subviews : .all)
                }
            }
        }.background(frameReporter(Self.gridKey))
    }

    private func previewFavoritesGrid(_ tabs: [ChromiumTab]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: min(tabs.count, 4))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tabs) { tab in FavoriteTile(model: model, tab: tab, showsTitle: tabs.count == 1) }
        }.allowsHitTesting(false)
    }

    // With no Favorites yet, the address field shows where to drop a tab.
    private var showFavoritesHint: Bool {
        !model.isIncognito && favorites.isEmpty && tabDrag?.dropped == false && dropZone == .favorites
    }
    private var favoritesHint: some View {
        dropHint("star", "Drop here to add to Favorites", targeted: dropZone == .favorites, shape: ChromiumAddressBar.shape)
            .background(.regularMaterial, in: ChromiumAddressBar.shape)
    }

    private func dropHint(_ symbol: String, _ label: String, targeted: Bool,
                          shape: RoundedRectangle = RoundedRectangle(cornerRadius: 9, style: .continuous)) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(label).font(.system(size: 12))
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(Color.primary.opacity(targeted ? 0.06 : 0))
                shape.strokeBorder(Color.primary.opacity(targeted ? 0.35 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }.accessibilityHidden(true)
    }

    private static let dragSpace = "BarkSidebar"
    private static let pinBoundaryKey = -1
    private static let addressKey = -2
    private static let gridKey = -3
    private static let newTabKey = -4
    private static let pagerKey = -5
    private static let settleDuration = 0.16

    private func frameReporter(_ key: Int) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TabFramesKey.self, value: [key: geometry.frame(in: .named(Self.dragSpace))])
        }
    }

    private func reorderSlot<Content: View>(_ id: Int?, @ViewBuilder content: () -> Content) -> some View {
        content()
            .offset(id.flatMap { tabDrag?.preview?.offsets[$0] } ?? .zero)
            .animation(reduceMotion ? nil : .easeOut(duration: Self.settleDuration), value: id == tabDrag?.id ? nil : tabDrag?.target)
            .background { if let id { frameReporter(id) } }
    }

    @ViewBuilder private func tabRow(_ tab: ChromiumTab, interactive: Bool, indent: CGFloat = 0) -> some View {
        // One structure for both, so a row survives its page becoming active.
        ChromiumTabRow(model: model, tab: tab, indent: indent)
            .overlay {
                if interactive && !tab.isElsewhere {
                    MiddleClickCatcher {
                        if tab.sessionClosed != true { model.close(tab) }
                    }.accessibilityHidden(true)
                }
            }
            .opacity(interactive && tabDrag?.id == tab.id ? 0 : 1)
            .simultaneousGesture(tabDragGesture(tab.id, fromFavorites: false, indent: indent),
                                 including: interactive && !tab.isElsewhere ? .all : .subviews)
    }

    private func draggedTab(_ id: Int) -> ChromiumTab? {
        favorites.first { $0.id == id } ?? model.snapshot.sidebarTabs.first { $0.id == id }
    }

    /// The dragged tab follows the pointer above everything else, so it stays
    /// visible outside the (clipped) tab list.
    @ViewBuilder private var dragOverlay: some View {
        if let drag = tabDrag, let tab = draggedTab(drag.id) {
            let frame = drag.sourceFrame
            let landing = drag.dropped ? drag.preview?.landing : nil
            let x = drag.preview != nil && !drag.fromFavorites
                ? frame.minX + max(0, drag.pointer.x - frame.maxX) : drag.origin.x
            Group {
                if drag.fromFavorites { FavoriteTile(model: model, tab: tab, showsTitle: favorites.count == 1) }
                else { ChromiumTabRow(model: model, tab: tab, indent: drag.indent) }
            }
            .frame(width: frame.width, height: frame.height)
            .background {
                RoundedRectangle(cornerRadius: drag.fromFavorites ? 12 : 9, style: .continuous)
                    .fill(.regularMaterial).opacity(drag.dropped ? 0 : 1)
            }
            .shadow(color: .black.opacity(drag.dropped ? 0 : 0.16), radius: 4, y: 2)
            .opacity(drag.target == .newWindow || (drag.dropped && landing == nil) ? 0 : 1)
            .offset(x: landing?.minX ?? x, y: landing?.minY ?? drag.origin.y)
            .animation(reduceMotion ? nil : .easeOut(duration: Self.settleDuration), value: drag.dropped)
            if let line = dropIndicator {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor)
                    .frame(width: line.width, height: line.height).offset(x: line.minX, y: line.minY)
            }
        }
    }

    private var dropZone: DropZone? {
        if case let .sidebar(zone, _) = tabDrag?.target { return zone }
        return nil
    }

    /// Dragging a tab out of the sidebar onto the page opens it alongside the
    /// active tab, on the half it is dropped on. Favorites and the tabs
    /// already on screen cannot be split.
    private func splitSide(for drag: TabDrag) -> SplitDropController.Side? {
        guard !drag.fromFavorites, let tab = draggedTab(drag.id), !tab.active, tab.splitActive != true,
              model.snapshot.sidebarTabs.contains(where: { $0.active }) else {
            model.splitDrop.end()
            return nil
        }
        return model.splitDrop.update(from: model.hostView, floating: floating,
                                      title: tab.displayTitle)
    }

    /// Where the dragged tab would land, and before which tab (nil for the
    /// end of that zone).
    private func sidebarTarget(for drag: inout TabDrag) -> TabDropTarget {
        let pointer = drag.pointer
        drag.preview = nil
        if !model.isIncognito {
            let favoritesBottom = favorites.isEmpty ? tabFrames[Self.addressKey]?.maxY : tabFrames[Self.gridKey].map { $0.maxY + 7 }
            if let favoritesBottom, pointer.y < favoritesBottom {
                if drag.fromFavorites {
                    drag.preview = TabReorderPreview(id: drag.id, order: favorites.map(\.id), frames: tabFrames,
                                                     center: drag.center, grid: true)
                    if let preview = drag.preview { return .sidebar(zone: .favorites, before: preview.before) }
                }
                for tab in favorites where tab.id != drag.id {
                    guard let frame = tabFrames[tab.id] else { continue }
                    if pointer.y < frame.minY || (pointer.y <= frame.maxY && pointer.x < frame.midX) {
                        return .sidebar(zone: .favorites, before: tab.id)
                    }
                }
                return .sidebar(zone: .favorites, before: nil)
            }
        }
        // In the list, a row lands by its center; a tile by the pointer.
        let y = drag.fromFavorites ? pointer.y : drag.center.y
        let divider = tabFrames[Self.pinBoundaryKey]
        let tabs = model.snapshot.sidebarTabs
        let hasPins = tabs.contains(where: \.pinned)
        let boundary = (hasPins ? divider?.midY : divider?.maxY) ?? tabFrames[Self.newTabKey]?.minY ?? -.infinity
        let pinned = !model.isIncognito && y < boundary
        let zone: DropZone = pinned ? .pinned : .unpinned
        let sourceTab = draggedTab(drag.id)
        // Expanding under a pin picked up in a collapsed section would move
        // its original slot away from the pointer before the first reorder.
        if pinned && (drag.fromFavorites || sourceTab?.pinned == false) {
            drag.revealsPins = true
        }
        // Chromium keeps a pin in its folder when reordering. Only its
        // siblings can occupy the slot it vacates in the sidebar.
        let folder = sourceTab?.folder
        let siblings = tabs.filter { $0.pinned == pinned && (!pinned || $0.folder == folder) }
        if !drag.fromFavorites {
            drag.preview = TabReorderPreview(id: drag.id, order: siblings.map(\.id), frames: tabFrames,
                                             center: drag.center, grid: false)
            if let preview = drag.preview { return .sidebar(zone: zone, before: preview.before) }
        }
        let before = siblings.first { tab in tabFrames[tab.id].map { y < $0.midY } ?? false }
        return .sidebar(zone: zone, before: before?.id)
    }

    /// The accent line showing where the dragged tab will land.
    private var dropIndicator: CGRect? {
        guard let drag = tabDrag, !drag.dropped,
              case let .sidebar(zone, before) = drag.target else { return nil }
        // During a reorder the landing slot stays fixed as its neighbors slide.
        let insertionFrame = drag.preview?.landing ?? before.flatMap { tabFrames[$0] }
        if zone == .favorites {
            if let frame = insertionFrame {
                return CGRect(x: frame.minX - 4, y: frame.minY + 6, width: 2, height: frame.height - 12)
            }
            guard let last = favorites.last(where: { $0.id != drag.id }), let frame = tabFrames[last.id] else { return nil }
            return CGRect(x: frame.maxX - 2, y: frame.minY + 6, width: 2, height: frame.height - 12)
        }
        let pinned = zone == .pinned
        func line(_ y: CGFloat, _ frame: CGRect) -> CGRect { CGRect(x: frame.minX + 4, y: y - 1, width: frame.width - 8, height: 2) }
        if let frame = insertionFrame { return line(frame.minY - 1.5, frame) }
        let folder = draggedTab(drag.id)?.folder
        if let last = model.snapshot.sidebarTabs.last(where: { $0.pinned == pinned && (!pinned || $0.folder == folder) && $0.id != drag.id }),
           let frame = tabFrames[last.id] {
            return line(frame.maxY + 1.5, frame)
        }
        if pinned { return nil }  // The divider shows the pin target.
        return tabFrames[Self.newTabKey].map { line($0.maxY + 1.5, $0) }
    }

    private func tabDragGesture(_ id: Int, fromFavorites: Bool, indent: CGFloat = 0) -> some Gesture {
        // Rows inside the pager report locations in the active page's space.
        func location(_ point: CGPoint) -> CGPoint {
            let origin = fromFavorites ? .zero : pagerOrigin
            return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        }
        return DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .updating($tabGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                model.draggingTab = true
                var drag: TabDrag
                if let current = tabDrag, current.id == id, !current.dropped {
                    drag = current
                } else {
                    guard let frame = tabFrames[id] else { return }
                    let start = location(value.startLocation)
                    drag = TabDrag(id: id, fromFavorites: fromFavorites,
                                   grab: CGSize(width: start.x - frame.minX, height: start.y - frame.minY),
                                   sourceFrame: frame, indent: indent, pointer: location(value.location))
                }
                drag.pointer = location(value.location)
                let target: TabDropTarget
                if model.splitDrop.updateNewWindow(from: model.hostView, title: draggedTab(id)?.displayTitle ?? "Tab") {
                    target = .newWindow
                    drag.preview = nil
                } else if let side = splitSide(for: drag) {
                    target = .split(side)
                    drag.preview = nil
                } else {
                    target = sidebarTarget(for: &drag)
                }
                if let previous = drag.target, previous != target {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                drag.target = target
                tabDrag = drag
            }
            .onEnded { value in
                model.draggingTab = false
                guard var drag = tabDrag, drag.id == id, !drag.dropped else { model.splitDrop.end(); return }
                drag.pointer = location(value.location)
                let newWindowPoint = SplitDropController.newWindowPoint(from: model.hostView)
                let side = newWindowPoint == nil ? splitSide(for: drag) : nil
                model.splitDrop.end()
                drag.releasedAt = ProcessInfo.processInfo.systemUptime
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                if let point = newWindowPoint {
                    tabDrag = nil
                    model.send("detachTab", id: id, metadata: ["screenX": String(Double(point.x)), "screenY": String(Double(point.y))])
                    return
                }
                if let side {
                    drag.target = .split(side)
                    drag.preview = nil
                    tabDrag = drag
                    model.send("splitTab", id: id, text: side.rawValue)
                } else {
                    let target = sidebarTarget(for: &drag)
                    drag.target = target
                    tabDrag = drag
                    if drag.preview?.changed == false {
                        finishDrag(drag, after: reduceMotion ? 0 : Self.settleDuration)
                        return
                    }
                    if case let .sidebar(zone, before) = target {
                        model.send("moveTab", id: id, metadata: ["zone": zone.rawValue, "before": before.map(String.init) ?? ""])
                    }
                }
                // Chromium may reject a move (for example a split constraint).
                finishDrag(drag, after: 0.5)
            }
    }

    private var tabOrder: String {
        (favorites.map { "f\($0.id)" } + model.snapshot.sidebarTabs.map { "\($0.id)\($0.pinned ? "p" : "")" }).joined(separator: ",")
    }

    private func tabOrderChanged() {
        guard var drag = tabDrag, let released = drag.releasedAt else { return }
        // The real rows now occupy the preview slots. Keep the carried tab
        // visible for the remainder of its landing animation.
        drag.preview?.offsets = [:]
        tabDrag = drag
        let remaining = released + Self.settleDuration - ProcessInfo.processInfo.systemUptime
        finishDrag(drag, after: reduceMotion || drag.preview == nil ? 0 : max(0, remaining))
    }

    private func finishDrag(_ drag: TabDrag, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if tabDrag?.session == drag.session { tabDrag = nil }
        }
    }

    // MARK: Archive

    private struct ArchiveNotice: Equatable {
        let id = UUID()
        let count: Int
    }

    // Archiving is one click, so it offers an immediate way back.
    private func archiveTabs() {
        // Blank tabs are closed but not kept, so they cannot be restored.
        let count = model.snapshot.sidebarTabs.filter { !$0.pinned && !$0.isBlank }.count
        model.send("archiveTabs")
        guard !model.isIncognito, count > 0 else { return }
        let notice = ArchiveNotice(count: count)
        withAnimation(.easeOut(duration: 0.15)) { archiveNotice = notice }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if archiveNotice == notice { withAnimation(.easeOut(duration: 0.2)) { archiveNotice = nil } }
        }
    }

    private func archiveBanner(_ notice: ArchiveNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(notice.count == 1 ? "Archived 1 tab" : "Archived \(notice.count) tabs")
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") {
                model.send("undoArchive")
                withAnimation(.easeOut(duration: 0.15)) { archiveNotice = nil }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Undo archiving tabs")
        }.padding(.horizontal, 11).frame(height: 34)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .contain)
    }

    /// A modal confirmation that keeps a floating sidebar open while shown.
    private func confirm(_ message: String, _ detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        model.presentingSidebarUI = true
        defer { model.presentingSidebarUI = showingImport || creatingProfile || settingsSpace != nil || draft != nil }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Shown while downloading (with progress) and briefly after a download
    // finishes. Opens chrome://downloads.
    private func downloadButton(_ downloads: ChromiumDownloads) -> some View {
        let label = downloads.active > 0
            ? (downloads.active == 1 ? "1 download in progress" : "\(downloads.active) downloads in progress")
            : "Download finished"
        return Button { model.send("downloads") } label: {
            ZStack {
                if downloads.active > 0 {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    if downloads.progress >= 0 {
                        Circle().trim(from: 0, to: max(0.03, downloads.progress))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.4), value: downloads.progress)
                    }
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
                } else {
                    Image(systemName: "checkmark.circle").font(.system(size: 14))
                }
            }.frame(width: 18, height: 18).frame(width: 28, height: 30)
        }.buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary)
            .help(label).accessibilityLabel("Downloads").accessibilityValue(label)
    }

    private var spaceDock: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Import into Bark…") { showingImport = true }
                Divider()
                Button("Bookmarks") { model.send("bookmarks") }
                Button("History") { model.send("history") }
                Button("Downloads") { model.send("downloads") }
                if !model.isIncognito {
                    Button("Archived Tabs…") { model.showArchive() }
                    if let label = model.snapshot.organizationUndoLabel {
                        Button("Undo " + label) { model.send("undoOrganization") }
                            .keyboardShortcut("z", modifiers: [.command, .option])
                    }
                }
                if !model.isIncognito, let features = model.snapshot.features {
                    Menu("Archive Tabs After") {
                        Picker("Archive tabs after", selection: Binding(
                            get: { features.archiveAfterHours },
                            set: { model.send("setArchiveAfter", text: String($0)) })) {
                            Text("12 Hours").tag(12)
                            Text("24 Hours").tag(24)
                            Text("7 Days").tag(168)
                            Text("30 Days").tag(720)
                            Text("Never").tag(0)
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    Toggle("Open Pinned Tab Links in Peek", isOn: Binding(
                        get: { features.peek }, set: { model.send("setPeek", text: $0 ? "on" : "off") }))
                    Toggle("Open Links from Other Apps in a Little Window", isOn: Binding(
                        get: { features.littleWindow }, set: { model.send("setLittleWindow", text: $0 ? "on" : "off") }))
                    GlobalLittleShortcutSetting(features: features) { model.send("setGlobalLittleShortcut", text: $0 ? "on" : "off") }
                    Toggle("Picture in Picture When Switching Tabs", isOn: Binding(
                        get: { features.autoPictureInPicture }, set: { model.send("setAutoPictureInPicture", text: $0 ? "on" : "off") }))
                    Divider()
                }
                Button("Extensions") { model.send("extensions") }
                Button("Settings") { model.send("settings") }
                Button("Keyboard Shortcuts") { ShortcutGuide.shared.show() }
                Divider()
                Button("New profile…") { profileName = ""; creatingProfile = true }
                if !model.isIncognito {
                    Divider()
                    // An inline picker shows a checkmark on the current mode.
                    Picker("Appearance", selection: Binding(
                        get: { model.snapshot.appearance ?? "system" },
                        set: { model.send("appearance", text: $0) })) {
                        Text("System appearance").tag("system")
                        Text("Light appearance").tag("light")
                        Text("Dark appearance").tag("dark")
                    }.pickerStyle(.inline).labelsHidden()
                }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)).frame(width: 28, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).accessibilityLabel("Library and settings")
            if let downloads = model.snapshot.downloads, downloads.active > 0 || downloads.recent {
                downloadButton(downloads)
            }
            spaceDockIcons
            Button(action: newSpace) { Image(systemName: "plus").font(.system(size: 14)).frame(width: 28, height: 30) }
                .buttonStyle(SidebarButtonStyle()).foregroundStyle(.secondary).help("New space").accessibilityLabel("New space")
        }
    }

    private var spaceDockIcons: some View {
        GeometryReader { geometry in
            let spaces = model.snapshot.spaces
            let count = CGFloat(max(1, spaces.count))
            let slot = min(38, geometry.size.width / count)
            let compact = slot < 21
            // Keep the selected icon readable, sharing the remaining width among dots.
            let hasSelectedIcon = compact && spaces.contains(where: { $0.active })
            let dotWidth = max(14, (geometry.size.width - (hasSelectedIcon ? 24 : 0)) /
                               max(1, count - (hasSelectedIcon ? 1 : 0)))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(spaces) { space in
                            let dot = compact && !space.active
                            let width = compact ? (dot ? dotWidth : 24) : slot
                            Button { model.requestSpaceSelection(space) } label: {
                                Group {
                                    if dot {
                                        Circle().fill(Color.secondary.opacity(0.65)).frame(width: 4, height: 4)
                                    } else {
                                        SpaceIcon(emoji: model.emoji(for: space), tint: model.tint(for: space))
                                            .font(.system(size: 12))
                                            .opacity(space.active ? 1 : 0.75)
                                    }
                                }
                                .frame(width: min(width, 34), height: 34)
                                .background {
                                    if space.active { SidebarSelectionBackground(tint: model.tint(for: space)) }
                                }
                                .frame(width: width, height: 34)
                                .contentShape(Rectangle())
                            }.buttonStyle(SidebarButtonStyle()).help(space.displayName).accessibilityLabel("Space " + space.displayName)
                                .accessibilityValue(space.active ? "Selected" : "")
                                .contextMenu { spaceMenu(for: space) }
                                .disabled(model.switchingSpaceProfile)
                                .id(space.id)
                        }
                    }.frame(minWidth: geometry.size.width)
                        .background(EnclosingScrollView { model.spaceDockScrollView = $0 }.allowsHitTesting(false))
                }.scrollIndicators(.never)
                    .onAppear { if let id = model.snapshot.activeSpaceId { proxy.scrollTo(id) } }
                    .onChange(of: model.snapshot.activeSpaceId) { id in if let id { proxy.scrollTo(id) } }
                    .onChange(of: geometry.size.width) { _ in if let id = model.snapshot.activeSpaceId { proxy.scrollTo(id) } }
            }
        }.frame(height: 34)
    }

    @ViewBuilder private func spaceMenu(for space: ChromiumSpace) -> some View {
        Button("Space settings…") { showSettings(for: space) }
        profileMenu(for: space)
        Divider()
        Button("Manage spaces…") { model.send("manageSpaces") }
        Button("Delete space…") { confirmDelete(space) }.disabled(!model.canDelete(space))
    }

    private func confirmDelete(_ space: ChromiumSpace) {
        let profile = model.snapshot.profiles?.first { $0.id == space.profile }?.name
        let lastInProfile = model.snapshot.spaces.filter { $0.profile == space.profile }.count == 1
        let details = lastInProfile
            ? "The space is removed from the sidebar. Its profile, tabs, sign-ins, and saved data are kept. To use them again, create a space in this profile."
            : "The space is removed from the sidebar. Its open tabs move to another space"
                + (profile.map { " in the “\($0)” profile." } ?? " of its profile.")
        if confirm("Delete “\(space.displayName)”?",
                   details,
                   button: "Delete") {
            model.send("deleteSpace", text: space.id)
        }
    }

    private func showSettings(for space: ChromiumSpace) {
        settingsProfileID = space.profile ?? model.snapshot.profileId ?? ""
        settingsSpace = SpaceSettingsTarget(space: space)
    }

    // Shows the space's profile, and moves the space to another one.
    @ViewBuilder private func profileMenu(for space: ChromiumSpace) -> some View {
        let profiles = model.snapshot.profiles ?? []
        let current = profiles.first { $0.id == space.profile }?.name ?? "Unknown"
        if profiles.count > 1 {
            Menu("Profile: " + current) {
                ForEach(profiles) { profile in
                    Button((profile.id == space.profile ? "✓ " : "") + profile.name) {
                        if profile.id != space.profile { confirmProfileChange(space, to: profile) }
                    }
                }
            }
        } else {
            Text("Profile: " + current)
        }
    }

    private func confirmProfileChange(_ space: ChromiumSpace, to profile: ChromiumProfile) {
        if confirm("Move “\(space.displayName)” to \(profile.name)?",
                   "This space's tabs will reopen in \(profile.name). Sign-ins and site data stay with the current profile.",
                   button: "Move") {
            model.moveSpace(space, toProfile: profile.id)
        }
    }

    private func newSpace() {
        draftProfileID = model.snapshot.profileId ?? model.snapshot.profiles?.first?.id ?? ""
        draft = SpaceDraft()
    }
}

// Observe the window edge and give the empty header a native drag surface.
// Button hit targets and web-page clicks are left to their own views.
@MainActor private final class ChromiumHeaderHostingView: NSHostingView<ChromiumSidebarHeader> {
    let model: ChromiumSidebarModel
    private var monitor: Any?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var lastPointer: NSPoint?
    private var presentationSubscription: AnyCancellable?
    private var wasCollapsed = false
    private var wasRevealed = false
    private var requestedReveal = false
    private var trackingMenus = 0
    private weak var trackedContent: NSView?
    private var trackingArea: NSTrackingArea?
    private var lastGeometryReport = ""
    private var windowDragStart: (pointer: NSPoint, origin: NSPoint)?
    init(model: ChromiumSidebarModel) {
        self.model = model
        super.init(rootView: ChromiumSidebarHeader(model: model))
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
        presentationSubscription = model.$snapshot.sink { [weak self] snapshot in self?.presentationChanged(snapshot) }
    }
    private func presentationChanged(_ snapshot: ChromiumSnapshot) {
        let collapsed = snapshot.sidebarCollapsed == true
        let revealed = snapshot.sidebarRevealed == true
        guard collapsed != wasCollapsed || revealed != wasRevealed else { return }
        let changedMode = collapsed != wasCollapsed
        wasCollapsed = collapsed
        wasRevealed = revealed
        cancelPendingReveal()
        // An acknowledgement of the reveal may arrive after the pointer has
        // already left. Keep its pending dismissal in that case.
        if changedMode || !revealed { hideWork?.cancel(); hideWork = nil }
        requestedReveal = collapsed && revealed
    }
    // Chromium already places this host inside its caption row. Applying the
    // window titlebar inset again would move the Swift controls out of line.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview, isWindowDragPoint(superview.convert(point, to: nil)) {
            return self
        }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard isWindowDragPoint(event.locationInWindow), let window else {
            super.mouseDown(with: event)
            return
        }
        // Chromium forwards events through its own frame view. Track the
        // AppKit drag here instead of asking that frame to start another loop.
        windowDragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = windowDragStart, let window, window.isMovable else {
            super.mouseDragged(with: event)
            return
        }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                      y: start.origin.y + pointer.y - start.pointer.y))
    }
    override func mouseUp(with event: NSEvent) {
        if windowDragStart != nil { windowDragStart = nil }
        else { super.mouseUp(with: event) }
    }
    @available(*, unavailable) required init(rootView: ChromiumSidebarHeader) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        if let content = window.contentView {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            content.addTrackingArea(area)
            trackedContent = content
            trackingArea = area
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResignedActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)),
                                               name: NSWindow.didMoveNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .leftMouseDown { self.reportHeaderHit(event.locationInWindow) }
            if event.type == .leftMouseUp {
                // Let SwiftUI finish the resize and update its bounds before
                // deciding whether the pointer has left the floating panel.
                let point = event.locationInWindow
                DispatchQueue.main.async { [weak self] in self?.trackPointer(point) }
            } else {
                self.trackPointer(event.locationInWindow)
            }
            return event
        }
    }
    override func layout() {
        super.layout()
        reportWindowGeometry()
    }
    @objc private func windowGeometryChanged(_ notification: Notification) { reportWindowGeometry() }
    @objc private func windowBecameKey(_ notification: Notification) {
        // Tracking areas can queue an exit while Settings or another Bark
        // window takes focus. That old exit must not dismiss a restored panel.
        hideWork?.cancel(); hideWork = nil
        model.send("hostActivated")
    }
    private func reportHeaderHit(_ point: NSPoint) {
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report"), let window else { return }
        let local = convert(point, from: nil)
        guard local.y >= -10, local.y <= bounds.height + 10 else { return }
        let report: [String: Any] = ["localX": local.x, "localY": local.y,
                                    "headerWidth": bounds.width, "headerHeight": bounds.height,
                                    "movable": window.isMovable, "drag": isWindowDragPoint(point)]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data(("BARK_UI_HEADER_HIT " + json + "\n").utf8))
        }
    }
    private func reportWindowGeometry() {
        // Opt-in validation of the real window, including movement and native
        // caption-button alignment. No profile or page data is recorded.
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report"),
              let window, bounds.width > 0 else { return }
        let header = convert(bounds, to: nil)
        let centers = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            window.standardWindowButton(type).map { $0.convert($0.bounds, to: nil).midY }
        }
        let report: [String: Any] = ["originX": window.frame.minX, "originY": window.frame.minY,
                                    "width": window.frame.width, "height": window.frame.height,
                                    "headerCenterY": header.midY, "trafficLightCentersY": centers]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8), json != lastGeometryReport else { return }
        lastGeometryReport = json
        FileHandle.standardError.write(Data(("BARK_UI_GEOMETRY " + json + "\n").utf8))
    }
    private func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, model.snapshot.sidebarCollapsed != true else { return false }
        let local = convert(point, from: nil)
        // The header host starts after the traffic lights. Keep its collapse
        // button and the three navigation controls fully interactive.
        guard local.x >= 0, local.x < bounds.width,
              local.y >= -4, local.y < bounds.height + 4 else { return false }
        if local.y < 0 || local.y >= bounds.height { return true }
        return local.x >= (model.isIncognito ? 54 : 28) && local.x < bounds.width - 80
    }
    @objc private func applicationResignedActive(_ notification: Notification) {
        // Dismiss on app switching, but keep native menus and popovers anchored.
        windowDragStart = nil
        dismissReveal()
    }
    @objc private func menuBeganTracking(_ notification: Notification) {
        trackingMenus += 1
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
    }
    @objc private func menuEndedTracking(_ notification: Notification) {
        trackingMenus = max(0, trackingMenus - 1)
        if trackingMenus == 0, let window { trackPointer(window.mouseLocationOutsideOfEventStream) }
    }
    func stopObserving() {
        windowDragStart = nil
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let trackingArea { trackedContent?.removeTrackingArea(trackingArea); self.trackingArea = nil }
        trackedContent = nil
        NotificationCenter.default.removeObserver(self)
        trackingMenus = 0
    }
    private func containsPointer(_ point: NSPoint, in window: NSWindow, revealed: Bool) -> Bool {
        // Include the inset, the spring's overshoot, and a small exit grace
        // region so the panel's rightmost controls stay inside its hover area.
        let panelRight = model.hostView.map { $0.convert($0.bounds, to: nil).maxX } ?? 0
        return point.y >= 0 && point.y < window.frame.height &&
            point.x >= 0 && point.x <= (revealed ? max(panelRight, (model.snapshot.sidebarWidth ?? 260) + 8) + 12 : 16)
    }
    private func trackPointer(_ point: NSPoint) {
        lastPointer = point
        defer { reportHover("pointer", point: point) }
        guard model.snapshot.sidebarCollapsed == true, let window, window.isKeyWindow,
              model.pageFrameView?.isHiddenOrHasHiddenAncestor == false else {
            cancelPendingReveal()
            hideWork?.cancel(); hideWork = nil; requestedReveal = false; return
        }
        if trackingMenus > 0 || model.presentingSidebarUI || model.siteControlsOpen || model.noticesOpen || model.draggingTab || model.resizingSidebar {
            cancelPendingReveal()
            hideWork?.cancel(); hideWork = nil; return
        }
        let revealed = requestedReveal || model.snapshot.sidebarRevealed == true
        if containsPointer(point, in: window, revealed: revealed) {
            hideWork?.cancel(); hideWork = nil
            if !revealed && showWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.showWork = nil
                    guard self.window?.isKeyWindow == true,
                          self.model.snapshot.sidebarCollapsed == true,
                          self.model.pageFrameView?.isHiddenOrHasHiddenAncestor == false else { return }
                    self.requestedReveal = true
                    self.model.send("revealSidebar", text: "true")
                }
                showWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
            }
        } else {
            cancelPendingReveal()
            if revealed && hideWork == nil && !model.editingAddress { scheduleDismissal() }
        }
    }
    private func cancelPendingReveal() { showWork?.cancel(); showWork = nil }
    override func mouseExited(with event: NSEvent) {
        // SwiftUI tracks the buttons inside this host independently of our
        // window-wide tracking area. Let it clear the button under the pointer.
        super.mouseExited(with: event)
        guard let trackingArea, event.trackingArea === trackingArea else { return }
        lastPointer = nil
        cancelPendingReveal()
        if model.snapshot.sidebarCollapsed == true && !model.editingAddress && !model.presentingSidebarUI && !model.siteControlsOpen && !model.noticesOpen && !model.draggingTab && !model.resizingSidebar && trackingMenus == 0 { scheduleDismissal() }
    }
    private func scheduleDismissal() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard !self.model.draggingTab, !self.model.resizingSidebar, !self.model.siteControlsOpen, !self.model.noticesOpen,
                  !self.model.presentingSidebarUI, !self.model.editingAddress,
                  self.trackingMenus == 0, self.window?.isKeyWindow == true else { return }
            // Chromium applies resize commands asynchronously. A mouse-up can
            // arrive before the new width; recheck after layout has caught up.
            if let point = self.lastPointer, let window = self.window,
               self.containsPointer(point, in: window, revealed: true) { return }
            self.dismissReveal()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    private func dismissReveal() {
        defer { reportHover("dismiss") }
        cancelPendingReveal()
        hideWork?.cancel(); hideWork = nil
        let wasRevealed = requestedReveal || model.snapshot.sidebarRevealed == true
        requestedReveal = false
        if wasRevealed { model.send("revealSidebar", text: "false") }
    }
    private func reportHover(_ phase: String, point: NSPoint? = nil) {
        guard ProcessInfo.processInfo.arguments.contains("--bark-ui-layout-report") else { return }
        var state: [String: Any] = ["phase": phase, "time": ProcessInfo.processInfo.systemUptime,
            "collapsed": model.snapshot.sidebarCollapsed == true, "revealed": model.snapshot.sidebarRevealed == true,
            "requested": requestedReveal, "editing": model.editingAddress, "presenting": model.presentingSidebarUI,
            "menus": trackingMenus, "key": window?.isKeyWindow == true,
            "showPending": showWork != nil, "hidePending": hideWork != nil]
        if let point { state["x"] = point.x; state["y"] = point.y }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
           let json = String(data: data, encoding: .utf8) {
            FileHandle.standardError.write(Data(("BARK_UI_HOVER " + json + "\n").utf8))
        }
    }
    deinit {
        showWork?.cancel()
        hideWork?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        // The main-thread ABI detaches tracking before releasing this view.
        NotificationCenter.default.removeObserver(self)
    }
}

/// Trackpad events have different cadences. Estimate points per second over
/// recent movement, including the time spent holding still before lifting.
struct SpaceSwipeVelocity {
    private var samples: [(time: TimeInterval, position: CGFloat)] = []
    private var position: CGFloat = 0
    private let interval: TimeInterval = 0.08

    mutating func begin(at time: TimeInterval) {
        position = 0
        samples = [(time, 0)]
    }

    mutating func add(_ delta: CGFloat, at time: TimeInterval) {
        position += delta
        if samples.last?.time == time {
            samples[samples.count - 1].position = position
        } else {
            samples.append((time, position))
        }
        while samples.count > 2 && samples[1].time <= time - interval {
            samples.removeFirst()
        }
    }

    func velocity(at time: TimeInterval) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time,
              time - last.time < interval else { return 0 }
        return (last.position - first.position) / max(time - first.time, 1.0 / 240)
    }
}

@MainActor final class ChromiumHostingView: NSHostingView<ChromiumSidebar> {
    let model: ChromiumSidebarModel
    private enum SwipeState { case idle, mayBegin, undecided(CGSize), horizontal, passthrough }
    private var swipe: SwipeState = .idle
    private var swallowMomentum = false
    private weak var scrollingDock: NSScrollView?
    private var swipeVelocity = SpaceSwipeVelocity()
    private var scrollMonitor: Any?
    fileprivate let addressBar: AddressBarController
    init(context: UnsafeMutableRawPointer?, callback: ChromiumCommand?) {
        let model = ChromiumSidebarModel(context: context, callback: callback)
        self.model = model
        addressBar = AddressBarController(model: model)
        super.init(rootView: ChromiumSidebar(model: model))
        // Chromium sets this view's frame; the content must never resize it.
        sizingOptions = []
        model.hostView = self
        ShortcutMonitor.shared.install()
        ShortcutGuide.shared.installHelpMenuItem()
        BarkImportMenu.shared.register(model)
        model.presentAddressBar = { [weak self] in
            guard let self else { return }
            self.addressBar.show(over: self.window)
        }
        // A local monitor sees trackpad scrolls before the tab list's vertical
        // ScrollView, so the dock and Space switching can route each gesture.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event) ? nil : event
        }
    }
    @available(*, unavailable) required init(rootView: ChromiumSidebar) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Full-width tab backgrounds extend underneath the overlay scrollbar.
        // Route its narrow strip to AppKit before SwiftUI's tab-drag gestures
        // can claim it, including when the thumb is currently faded out.
        if !isHiddenOrHasHiddenAncestor, let scrollView = model.tabScrollView,
           let scroller = scrollView.verticalScroller,
           !scrollView.isHiddenOrHasHiddenAncestor,
           (scrollView.documentView?.bounds.height ?? 0) > scrollView.contentView.bounds.height + 1,
           scroller.bounds.contains(scroller.convert(point, from: superview)) {
            if NSApp.currentEvent?.type == .leftMouseDown { scrollView.flashScrollers() }
            return scroller
        }
        return super.hitTest(point)
    }

    func focusAddress() {
        model.focusAddress()
    }

    func openAddressSuggestion(_ json: String) {
        guard let suggestion = try? JSONDecoder().decode(AddressSuggestion.self, from: Data(json.utf8)) else { return }
        addressBar.open(suggestion)
    }

    /// The sidebar model of a browser window, if it has a sidebar.
    static func model(in window: NSWindow) -> ChromiumSidebarModel? {
        func find(_ view: NSView) -> ChromiumHostingView? {
            if let host = view as? ChromiumHostingView { return host }
            for child in view.subviews { if let host = find(child) { return host } }
            return nil
        }
        return window.contentView.flatMap(find)?.model
    }

    func stopTracking() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        model.presentAddressBar = nil
        model.splitDrop.end()
        addressBar.tearDown()
    }

    /// Route a wheel tick or an entire trackpad gesture to its starting region.
    private func handleScroll(_ event: NSEvent) -> Bool {
        // Events normally name their window. Without one, the location is in
        // screen coordinates; use the window under it.
        let eventWindow = event.window ?? NSApp.window(withWindowNumber:
            NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
        guard let window, eventWindow === window else { return false }
        let locationInWindow = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let beginsGesture = event.phase.contains(.mayBegin) || event.phase.contains(.began)
        let wheelTick = event.phase.isEmpty && event.momentumPhase.isEmpty
        if beginsGesture || wheelTick {
            scrollingDock = nil
            if let dock = model.spaceDockScrollView, dock.window === window, !dock.isHiddenOrHasHiddenAncestor,
               dock.visibleRect.contains(dock.convert(locationInWindow, from: nil)),
               let document = dock.documentView, document.frame.width > dock.contentSize.width {
                scrollingDock = dock
            }
        }
        if let dock = scrollingDock {
            if beginsGesture, case .mayBegin = swipe {
                model.discardUndecidedSpaceSwipe()
                swipe = .passthrough
            }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy
            let clip = dock.contentView
            var bounds = clip.bounds
            bounds.origin.x -= delta * (event.hasPreciseScrollingDeltas ? 1 : dock.horizontalLineScroll)
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            dock.reflectScrolledClipView(clip)
            return true
        }
        // Trailing momentum after a swipe must not scroll the tab list.
        if !event.momentumPhase.isEmpty, event.phase.isEmpty {
            guard swallowMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
            return true
        }
        // Only phased trackpad gestures; classic mouse wheels scroll normally.
        guard !event.phase.isEmpty, event.hasPreciseScrollingDeltas else { return false }
        // Content follows the fingers regardless of the natural-scrolling setting.
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let fingerY = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        if beginsGesture {
            swallowMomentum = false
            if case .mayBegin = swipe, event.phase.contains(.began) {
                swipe = .undecided(.zero)
            } else {
                let inside = !isHiddenOrHasHiddenAncestor && bounds.contains(convert(locationInWindow, from: nil))
                if inside && model.canSwipeSpaces {
                    // The profile window can change before the fingers have
                    // travelled far enough to decide the gesture's axis.
                    model.beginSpaceSwipe()
                    swipe = event.phase.contains(.mayBegin) ? .mayBegin : .undecided(.zero)
                } else {
                    model.discardUndecidedSpaceSwipe()
                    swipe = .passthrough
                }
            }
            swipeVelocity.begin(at: event.timestamp)
            if event.phase.contains(.mayBegin) { return false }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { swipe = .idle }
            guard case .horizontal = swipe else {
                model.discardUndecidedSpaceSwipe()
                return false
            }
            if fingerX != 0 {
                swipeVelocity.add(fingerX, at: event.timestamp)
                model.updateSpaceSwipe(by: fingerX, width: bounds.width)
            }
            model.endSpaceSwipe(velocity: swipeVelocity.velocity(at: event.timestamp), width: bounds.width,
                                cancelled: event.phase.contains(.cancelled))
            swallowMomentum = true
            return true
        }
        if case .mayBegin = swipe { swipe = .undecided(.zero) }
        switch swipe {
        case .undecided(var total):
            swipeVelocity.add(fingerX, at: event.timestamp)
            total.width += fingerX; total.height += fingerY
            guard hypot(total.width, total.height) >= 6 else { swipe = .undecided(total); return false }
            // Decide once per gesture; a mostly vertical start keeps scrolling tabs.
            guard abs(total.width) > abs(total.height) * 1.3 else {
                model.discardUndecidedSpaceSwipe()
                swipe = .passthrough
                return false
            }
            swipe = .horizontal
            model.updateSpaceSwipe(by: total.width, width: bounds.width)
            return true
        case .horizontal:
            swipeVelocity.add(fingerX, at: event.timestamp)
            model.updateSpaceSwipe(by: fingerX, width: bounds.width)
            return true
        case .idle, .mayBegin, .passthrough:
            return false
        }
    }
}

// Main-thread-only ABI. C++ detaches the native host before releasing this
// retained view, and shuts down its callback before destroying the controller.
@_cdecl("BarkSwiftSidebarCreate")
@MainActor func barkSwiftSidebarCreate(_ context: UnsafeMutableRawPointer?, _ callback: ChromiumCommand?) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(ChromiumHostingView(context: context, callback: callback)).toOpaque()
}

@_cdecl("BarkSwiftSidebarUpdate")
@MainActor func barkSwiftSidebarUpdate(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.update(String(cString: json))
}

@_cdecl("BarkSwiftSidebarSelectSpace")
@MainActor func barkSwiftSidebarSelectSpace(_ handle: UnsafeMutableRawPointer, _ id: UnsafePointer<CChar>) {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    let spaceID = String(cString: id)
    if let space = model.snapshot.spaces.first(where: { $0.id == spaceID }) { model.requestSpaceSelection(space) }
}

@_cdecl("BarkSwiftSidebarDestroy")
@MainActor func barkSwiftSidebarDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeRetainedValue()
    view.stopTracking()
    view.model.shutdown()
}

@_cdecl("BarkSwiftSidebarSuggestions")
@MainActor func barkSwiftSidebarSuggestions(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.updateSuggestions(String(cString: json))
}

@_cdecl("BarkSwiftSidebarSwitcher")
@MainActor func barkSwiftSidebarSwitcher(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.updateSwitcher(String(cString: json))
}

@_cdecl("BarkSwiftSidebarFocusAddress")
@MainActor func barkSwiftSidebarFocusAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().focusAddress()
}

@_cdecl("BarkSwiftSidebarComposeAddress")
@MainActor func barkSwiftSidebarComposeAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.composeAddress()
}

@_cdecl("BarkSwiftSidebarDismissAddress")
@MainActor func barkSwiftSidebarDismissAddress(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().addressBar.close(returnFocus: false)
}

@_cdecl("BarkSwiftSidebarAddressVisible")
@MainActor func barkSwiftSidebarAddressVisible(_ handle: UnsafeMutableRawPointer) -> Bool {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().addressBar.isVisible
}

@_cdecl("BarkSwiftSidebarOpenSuggestion")
@MainActor func barkSwiftSidebarOpenSuggestion(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().openAddressSuggestion(String(cString: json))
}

@_cdecl("BarkSwiftSidebarHeaderCreate")
@MainActor func barkSwiftSidebarHeaderCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(ChromiumHeaderHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarHeaderDestroy")
@MainActor func barkSwiftSidebarHeaderDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<ChromiumHeaderHostingView>.fromOpaque(handle).takeRetainedValue()
    view.stopObserving()
}

@_cdecl("BarkSwiftSidebarResizeCreate")
@MainActor func barkSwiftSidebarResizeCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(SidebarResizeHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarResizeDestroy")
@MainActor func barkSwiftSidebarResizeDestroy(_ handle: UnsafeMutableRawPointer) {
    let view = Unmanaged<SidebarResizeHostingView>.fromOpaque(handle).takeRetainedValue()
    view.rootView.model.resizingSidebar = false
}

@_cdecl("BarkSwiftPageFrameCreate")
@MainActor func barkSwiftPageFrameCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    let frame = PageFrameHostingView(model: model)
    model.pageFrameView = frame
    return Unmanaged.passRetained(frame).toOpaque()
}

@_cdecl("BarkSwiftSidebarBackdropCreate")
@MainActor func barkSwiftSidebarBackdropCreate(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let model = Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model
    return Unmanaged.passRetained(SidebarBackdropHostingView(model: model)).toOpaque()
}

@_cdecl("BarkSwiftSidebarShowPreferences")
@MainActor func barkSwiftSidebarShowPreferences(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<ChromiumHostingView>.fromOpaque(handle).takeUnretainedValue().model.showPreferences()
}
