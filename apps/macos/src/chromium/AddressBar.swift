import AppKit
import Combine
import SwiftUI
import BarkCore

// The centered panel opens empty for a new destination or with the current URL
// selected for editing. As a child window, it follows the browser when it moves.
@MainActor final class AddressBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let model: ChromiumSidebarModel
    private var panel: AddressBarPanel?
    private var field: NSTextField?
    private var icon: NSImageView?
    private var searchHint: NSTextField?
    private var displayedIcon: AddressBarIcon?
    private weak var parent: NSWindow?
    private var suggestionsObserver: AnyCancellable?
    private var iconObserver: AnyCancellable?
    private var openedAt: Date?
    private var scrim: AddressBarScrim?
    private static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40

    init(model: ChromiumSidebarModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible == true }

    func show(over window: NSWindow?) {
        guard let window, window.isVisible else {
            model.cancelAddressEditing()
            return
        }
        let panel = self.panel ?? makePanel()
        if parent !== window {
            parent?.removeChildWindow(panel)
            if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
            parent = window
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(parentChanged(_:)), name: name, object: window)
            }
        }
        field?.stringValue = model.address
        model.clearSuggestions()
        // Start with recently used open tabs; typing narrows to matches.
        model.requestSuggestions(for: "")
        updateIcon()
        position(panel)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        openedAt = Date()
        showScrim(in: window)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field?.currentEditor()?.selectAll(nil)
    }

    func close(returnFocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        model.cancelAddressEditing()
        model.send("suggest", text: "")  // Stops any running history query.
        model.clearSuggestions()
        hideScrim()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if returnFocus, let parent, parent.isVisible { parent.makeKeyAndOrderFront(nil) }
    }

    func tearDown() {
        if let parent { NotificationCenter.default.removeObserver(self, name: nil, object: parent) }
        if let panel { parent?.removeChildWindow(panel); panel.orderOut(nil); panel.delegate = nil }
        suggestionsObserver = nil
        iconObserver = nil
        scrim?.removeFromSuperview(); scrim = nil
        field?.delegate = nil
        panel = nil; field = nil; icon = nil; searchHint = nil; displayedIcon = nil; parent = nil
    }

    private func makePanel() -> AddressBarPanel {
        let panel = AddressBarPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 56),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.textColor = .labelColor
        field.placeholderString = "Search or enter address · Tab for actions"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Address")
        field.delegate = self

        let searchHint = NSTextField(labelWithString: "")
        searchHint.font = .systemFont(ofSize: 13, weight: .medium)
        searchHint.textColor = .secondaryLabelColor
        searchHint.lineBreakMode = .byTruncatingTail
        searchHint.isHidden = true
        searchHint.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchHint.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, field, searchHint])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)

        let list = NSHostingView(rootView: AddressSuggestionList(model: model) { [weak self] suggestion in
            self?.open(suggestion)
        })
        list.sizingOptions = []
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.fieldHeight),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        self.panel = panel
        self.field = field
        self.icon = icon
        self.searchHint = searchHint
        suggestionsObserver = model.$suggestions.dropFirst().sink { [weak self] items in
            // @Published fires before the value is stored; lay out next turn.
            DispatchQueue.main.async { self?.resize(rows: items.count) }
        }
        iconObserver = model.objectWillChange.sink { [weak self] in
            // Read after @Published has stored the new text, selection, or favicon.
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
        return panel
    }

    private func updateIcon() {
        if let searchHint {
            let hint = model.addressSearchHint
            searchHint.stringValue = hint ?? ""
            searchHint.isHidden = hint == nil
        }
        guard let icon else { return }
        let next = model.addressBarIcon
        guard next != displayedIcon else { return }
        displayedIcon = next
        switch next {
        case .favicon(let encoded):
            icon.symbolConfiguration = nil
            icon.contentTintColor = nil
            icon.image = FaviconCache.image(encoded)
            icon.setAccessibilityLabel("Website icon")
        case .command(let symbol):
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Browser action")
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityLabel("Browser action")
        case .globe, .search:
            let label = next == .search ? "Search" : "Open address"
            icon.image = NSImage(systemSymbolName: next == .search ? "magnifyingglass" : "globe", accessibilityDescription: label)
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            icon.setAccessibilityLabel(label)
        }
    }

    private func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + AddressSuggestionList.padding * 2 + 1
    }

    private func resize(rows: Int) {
        guard let panel, panel.isVisible else { return }
        position(panel, rows: rows)
    }

    func open(_ suggestion: AddressSuggestion) {
        let disposition = model.addressDisposition
        close()
        model.openSuggestion(suggestion, in: disposition)
    }

    // Dims the browser window's content under the bar. The scrim is a plain
    // subview of the window's content view (where Chromium also attaches the
    // sidebar), so it follows the window's rounded corners and resizing, and
    // it ignores clicks: clicking the page still dismisses the bar.
    private func showScrim(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let scrim = self.scrim ?? AddressBarScrim()
        self.scrim = scrim
        if scrim.superview !== content {
            scrim.removeFromSuperview()
            scrim.frame = content.bounds
            scrim.autoresizingMask = [.width, .height]
            scrim.alphaValue = 0
        }
        // Keep it above Chromium's views, which may have been added since.
        content.addSubview(scrim, positioned: .above, relativeTo: nil)
        scrim.generation += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scrim.animator().alphaValue = 1
        }
    }

    private func hideScrim() {
        guard let scrim, scrim.superview != nil else { return }
        scrim.generation += 1
        let generation = scrim.generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            scrim.animator().alphaValue = 0
        }, completionHandler: { [weak scrim] in
            // Reopening during the fade-out keeps the scrim in place.
            MainActor.assumeIsolated {
                guard let scrim, scrim.generation == generation else { return }
                scrim.removeFromSuperview()
            }
        })
    }

    // The field stays centered in the window; suggestions extend below it.
    private func position(_ panel: NSPanel, rows: Int? = nil) {
        guard let parent else { return }
        let frame = parent.frame
        let width = min(680, max(320, frame.width - 120))
        let height = Self.fieldHeight + listHeight(rows: rows ?? model.suggestions.count)
        let top = frame.midY + Self.fieldHeight / 2
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    @objc private func parentChanged(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    // When Chromium asks to edit an existing tab's address, it can briefly
    // reclaim key focus as that tab finishes opening.
    func windowDidResignKey(_ notification: Notification) {
        let type = NSApp.currentEvent?.type
        let clicked = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let justOpened = openedAt.map { Date().timeIntervalSince($0) < 1.5 } ?? false
        if model.editingAddress, model.addressDisposition == .currentTab,
           !clicked && justOpened, let panel, panel.isVisible, NSApp.isActive {
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                panel.makeKey()
                if panel.firstResponder !== self.field?.currentEditor() { panel.makeFirstResponder(self.field) }
            }
            return
        }
        close(returnFocus: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        model.address = field.stringValue
        model.selectedSuggestion = nil
        model.requestSuggestions(for: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertTab(_:)), control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            control.stringValue = "> "
            model.address = control.stringValue
            model.selectedSuggestion = nil
            model.requestSuggestions(for: control.stringValue)
            return true
        }
        if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
            guard !model.suggestions.isEmpty else { return false }
            model.moveSuggestionSelection(by: command == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) {
            if let index = model.selectedSuggestion, model.suggestions.indices.contains(index) {
                open(model.suggestions[index])
                return true
            }
            let text = control.stringValue
            // Action-only input never leaks into a web search when no command matches.
            if CommandBarSelection.isActionQuery(text) { NSSound.beep(); return true }
            let disposition = model.addressDisposition
            close()
            model.submitAddress(text, in: disposition)
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}

private struct AddressSuggestionList: View {
    static let padding: CGFloat = 6
    @ObservedObject var model: ChromiumSidebarModel
    let open: (AddressSuggestion) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if !model.suggestions.isEmpty { Divider() }
            VStack(spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.listID) { index, suggestion in
                    AddressSuggestionRow(suggestion: suggestion, selected: model.selectedSuggestion == index)
                        .frame(height: AddressBarController.rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { open(suggestion) }
                        .onHover { if $0 { model.selectedSuggestion = index } }
                }
            }.padding(Self.padding)
            Spacer(minLength: 0)
        }
    }
}

private struct AddressSuggestionRow: View {
    let suggestion: AddressSuggestion
    let selected: Bool
    private var icon: NSImage? { suggestion.faviconValid == false ? nil : FaviconCache.image(suggestion.favicon) }
    private var subtitle: String {
        if suggestion.isCommand { return suggestion.detail ?? "Browser action" }
        guard let url = URL(string: suggestion.url), let host = url.host else { return suggestion.url }
        let path = url.path == "/" ? "" : url.path
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }
    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else {
                    Image(systemName: suggestion.isCommand ? (suggestion.symbol ?? "command") : suggestion.isTab ? "square.fill" : suggestion.kind == "history" ? "clock" : "globe")
                        .foregroundStyle(.secondary)
                }
            }.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title.isEmpty ? subtitle : suggestion.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(suggestion.isCommand ? "Run action" : suggestion.isTab
                 ? (suggestion.space.map { "Switch to tab · \($0)" } ?? "Switch to tab")
                 : suggestion.kind == "history" ? "History" : suggestion.kind == "search" ? "Search" : "Open address")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color.accentColor.opacity(selected ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor final class AddressBarScrim: NSView {
    var generation = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class AddressBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
