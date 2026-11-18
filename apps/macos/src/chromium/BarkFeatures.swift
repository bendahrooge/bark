import AppKit
import Combine
import SwiftUI
import BarkCore

// Bark's sidebar presents the copy-link toast, Control-Tab switcher,
// Peek and Little window controls, and media player. Chromium owns the tabs and windows.

struct ChromiumFolder: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    var collapsed: Bool? = nil
    var parent: String? = nil
}

/// The tab playing (or paused in) media while another tab is on screen.
struct ChromiumMedia: Decodable, Equatable {
    let id: Int
    let title: String
    let url: String
    var favicon: String? = nil
    var muted: Bool? = nil
    var customTitle: String? = nil
    let playing: Bool
    var mediaTitle: String? = nil
    var artist: String? = nil
    var space: String? = nil
    var heading: String {
        if let mediaTitle, !mediaTitle.isEmpty { return mediaTitle }
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return title.isEmpty ? (URL(string: url)?.host ?? url) : title
    }
    var detail: String {
        if let artist, !artist.isEmpty { return artist }
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Switches in the Library menu, as Chromium last reported them.
struct ChromiumFeatures: Decodable, Equatable {
    var archiveAfterHours: Int = 12
    var peek: Bool = true
    var littleWindow: Bool = true
    var autoPictureInPicture: Bool = true
}

/// Normalized positions keep the theme consistent at every sidebar size.
struct SpaceColorPoint: Codable, Equatable {
    var x: Double
    var y: Double

    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

struct SpaceGradientCanvas: Codable, Equatable {
    var startColor: String
    var endColor: String
    var start = SpaceColorPoint(x: 0.25, y: 0.30)
    var end = SpaceColorPoint(x: 0.77, y: 0.78)

    static func isColor(_ value: String) -> Bool {
        value.utf8.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    var isValid: Bool { Self.isColor(startColor) && Self.isColor(endColor) && start.isValid && end.isValid }
    var json: String? {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A space's colors and gradient positions.
struct SpaceStyle: Equatable {
    var gradient: SpaceTheme? = nil
    var canvas: SpaceGradientCanvas? = nil
    var metadata: [String: String] {
        // Clear any saved texture when this space is next edited.
        ["gradient": gradient?.rawValue ?? "", "grain": "0", "gradientCanvas": canvas?.json ?? ""]
    }
}

// MARK: Toast

@MainActor final class ToastPresenter {
    static let shared = ToastPresenter()
    fileprivate var testCopyPasteboard: NSPasteboard?
    private var panel: NSPanel?
    private var generation = 0

    func copyLink(_ link: String, markdown: Bool = false, over window: NSWindow?, tint: Color = .accentColor) {
        guard !link.isEmpty else { return }
        let destination = testCopyPasteboard ?? .general
        destination.clearContents()
        guard destination.setString(link, forType: .string) else { return }
        let text = markdown ? "Copied link as Markdown" : "URL copied"
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        guard let window, window.isVisible else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ToastView(text: text, tint: tint))
        let size = host.fittingSize
        let frame = PageFrameHostingView.pageRect(in: window) ?? window.convertToScreen(window.contentLayoutRect)
        let alreadyVisible = panel.isVisible && panel.parent === window
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16,
                              width: size.width, height: size.height), display: true)
        panel.contentView = host
        panel.level = window.level
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !alreadyVisible { panel.alphaValue = reduceMotion ? 1 : 0 }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        generation += 1
        let shown = generation
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == shown else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = reduceMotion ? 0 : 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                DispatchQueue.main.async {
                    guard self.generation == shown else { return }
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("BarkCopyLinkToast")
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

@_cdecl("BarkSwiftUseCopyPasteboardForTesting")
@MainActor func barkSwiftUseCopyPasteboardForTesting(_ name: UnsafePointer<CChar>) {
    ToastPresenter.shared.testCopyPasteboard = NSPasteboard(name: .init(String(cString: name)))
}

private struct ToastView: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20).background(tint.opacity(0.4), in: Circle())
            Text(text).font(.system(size: 13, weight: .semibold))
        }.foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 36).fixedSize()
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: Control-Tab switcher

/// Control-Tab cycles through recently shown tabs. Release Control to show the
/// selected tab or press Escape to cancel.
@MainActor final class RecentTabSwitcher: ObservableObject {
    static let shared = RecentTabSwitcher()
    @Published private(set) var tabs: [ChromiumTab] = []
    @Published private(set) var selection = 0
    private weak var model: ChromiumSidebarModel?
    private weak var window: NSWindow?
    private var panel: NSPanel?
    private var flagsMonitor: Any?
    /// Presses made before Chromium answered with the tab list.
    private var pendingSteps = 0
    private var released = false
    private(set) var active = false

    func press(model: ChromiumSidebarModel, window: NSWindow, reverse: Bool) {
        if active, self.model === model {
            step(reverse ? -1 : 1)
            return
        }
        end()
        active = true
        self.model = model
        self.window = window
        tabs = []
        pendingSteps = reverse ? -1 : 1
        released = false
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let self, self.active, !event.modifierFlags.contains(.control) { self.commit() }
            return event
        }
        model.send("requestSwitcher")
    }

    func receive(_ tabs: [ChromiumTab], from model: ChromiumSidebarModel) {
        guard active, self.model === model else { return }
        self.tabs = tabs
        guard tabs.count > 1 else { end(); return }
        selection = ((pendingSteps % tabs.count) + tabs.count) % tabs.count
        if released { commit(); return }
        show()
    }

    /// Escape and Return while the switcher is open.
    func handleKey(_ event: NSEvent) -> Bool {
        guard active else { return false }
        switch event.keyCode {
        case 53: end(); return true          // Escape
        case 36, 76: commit(); return true   // Return, Enter
        case 123: step(-1); return true      // Left arrow
        case 124: step(1); return true       // Right arrow
        default: return false
        }
    }

    private func step(_ delta: Int) {
        guard !tabs.isEmpty else { pendingSteps += delta; return }
        selection = ((selection + delta) % tabs.count + tabs.count) % tabs.count
    }

    private func commit() {
        guard active else { return }
        guard !tabs.isEmpty else { released = true; return }
        let tab = tabs[selection]
        let model = self.model
        end()
        model?.send("select", id: tab.id)
    }

    func isShowing(for model: ChromiumSidebarModel) -> Bool { active && self.model === model }

    func end() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        active = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func show() {
        guard let window else { return }
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: RecentTabSwitcherView(switcher: self))
            return panel
        }()
        self.panel = panel
        let frame = window.frame
        let width = min(CGFloat(tabs.count) * RecentTabSwitcherView.cardWidth + 28, frame.width - 80)
        let height = RecentTabSwitcherView.height
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

private struct RecentTabSwitcherView: View {
    @ObservedObject var switcher: RecentTabSwitcher
    static let cardWidth: CGFloat = 188
    static let height: CGFloat = 176

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(switcher.tabs.enumerated()), id: \.element.id) { index, tab in
                        card(tab, selected: index == switcher.selection).id(tab.id)
                    }
                }.padding(10)
            }.scrollIndicators(.hidden)
                .onChange(of: switcher.selection) { selection in
                    if switcher.tabs.indices.contains(selection) {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(switcher.tabs[selection].id, anchor: .center) }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel("Recent tabs")
    }

    private func card(_ tab: ChromiumTab, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06))
                if let thumbnail = tab.thumbnailImage {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Self.cardWidth - 20, height: 104, alignment: .top)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let icon = tab.faviconImage, !tab.isBlank {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                } else {
                    Image(systemName: "square.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                }
            }.frame(width: Self.cardWidth - 20, height: 104)
            HStack(spacing: 6) {
                if let icon = tab.faviconImage, !tab.isBlank {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "square.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                Text(tab.displayTitle).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
        }.padding(10).frame(width: Self.cardWidth - 8, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Color.accentColor.opacity(0.20) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 2))
            .accessibilityElement(children: .ignore).accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Peek and Little windows

struct PeekLayout {
    static let buttonSize: CGFloat = 34
    static let buttonSpacing: CGFloat = 9
    let page: NSRect
    let controls: NSRect

    init(viewport: NSRect) {
        let gap: CGFloat = 12
        let margin: CGFloat = 6
        let width = max(1, min(viewport.width * 0.81, viewport.width - 2 * margin - gap - Self.buttonSize))
        let left = min(viewport.midX - width / 2, viewport.maxX - margin - gap - Self.buttonSize - width)
        let inset = min(8, max(3, viewport.height * 0.008))
        page = NSRect(x: left.rounded(), y: (viewport.minY + inset).rounded(), width: width.rounded(),
                      height: max(1, (viewport.height - 2 * inset).rounded()))
        let railHeight = 3 * Self.buttonSize + 2 * Self.buttonSpacing
        controls = NSRect(x: page.maxX + gap, y: max(viewport.minY, page.maxY - 6 - railHeight),
                          width: Self.buttonSize, height: railHeight)
    }
}

struct PeekEntrance {
    static let duration: TimeInterval = 0.34
    let pageOpacity: CGFloat
    let railOpacity: CGFloat
    let backdropOpacity: CGFloat
    private let remaining: CGFloat

    init(elapsed: TimeInterval) {
        let t = max(0, elapsed)
        // Step response of an underdamped spring, starting at rest.
        let damping = 16.4, frequency = 22.5
        remaining = t >= Self.duration ? 0 : exp(-damping * t) *
            (cos(frequency * t) + damping / frequency * sin(frequency * t))
        func fade(_ duration: TimeInterval) -> CGFloat { 1 - pow(1 - min(1, t / duration), 2) }
        pageOpacity = fade(0.11)
        railOpacity = fade(0.16)
        backdropOpacity = fade(0.14)
    }

    func pageFrame(_ final: NSRect) -> NSRect {
        let rect = final.insetBy(dx: final.width * 0.03 * remaining, dy: final.height * 0.03 * remaining)
        return rect.offsetBy(dx: 0, dy: -min(12, final.height * 0.025) * remaining)
    }

    fileprivate func transform(on layer: CALayer, page: NSRect) -> CATransform3D {
        let visible = pageFrame(page)
        let scale = visible.width / page.width
        let flipped = layer.superlayer?.isGeometryFlipped == true
        let dx = (scale - 1) * (layer.anchorPoint.x - 0.5) * layer.bounds.width
        let dy = (scale - 1) * (layer.anchorPoint.y - 0.5) * layer.bounds.height +
            (flipped ? -1 : 1) * (visible.midY - page.midY)
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }

    // AppKit and Chromium can both be busy scheduling the first web frame.
    // Let the render server present the same motion on the live page and the
    // rounded surface behind it without resizing the Chromium compositor.
    fileprivate static func animate(_ layer: CALayer, page: NSRect?, startTime: CFTimeInterval,
                                    opacity: KeyPath<PeekEntrance, CGFloat>) {
        let samples = (0...40).map { PeekEntrance(elapsed: duration * Double($0) / 40) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = samples.map { NSNumber(value: Double($0[keyPath: opacity])) }
        fade.duration = duration
        var animations: [CAAnimation] = [fade]
        if let page {
            let spring = CAKeyframeAnimation(keyPath: "transform")
            spring.values = samples.map { NSValue(caTransform3D: $0.transform(on: layer, page: page)) }
            spring.duration = duration
            animations.append(spring)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = layer.convertTime(startTime, from: nil)
        layer.add(group, forKey: "BarkPeekEntrance")
    }
}

@MainActor private final class PeekEntranceSurface: NSView {
    let card = CALayer()

    init(in content: NSView, color: NSColor) {
        super.init(frame: content.bounds)
        identifier = NSUserInterfaceItemIdentifier("BarkPeekEntranceSurface")
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        card.name = "BarkPeekCard"
        card.backgroundColor = color.cgColor
        card.cornerRadius = 10
        card.cornerCurve = .continuous
        card.shadowRadius = 12
        card.shadowOpacity = 0.18
        card.shadowOffset = CGSize(width: 0, height: -3)
        card.opacity = 0
        layer?.addSublayer(card)
        content.addSubview(self, positioned: .above, relativeTo: nil)
    }

    func setPageFrame(_ frame: NSRect) {
        guard let window else { return }
        card.frame = convert(window.convertFromScreen(frame), from: nil)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PeekBackdrop: NSView {
    var dismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.037, blue: 0.105, alpha: 0.68).cgColor
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { dismiss?() }
    override func rightMouseDown(with event: NSEvent) { dismiss?() }
}

@MainActor private final class PeekCoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class PeekCoverView: NSView {
    init(bitmap: CGImage, size: NSSize, scale: CGFloat) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        setAccessibilityElement(false)
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        let imageHeight = (size.width * CGFloat(bitmap.height) / CGFloat(bitmap.width) * scale).rounded() / scale
        let page = CALayer()
        page.contents = bitmap
        page.frame = NSRect(x: 0, y: size.height - imageHeight, width: size.width, height: imageHeight)
        page.contentsGravity = .resize
        page.contentsScale = scale
        layer.addSublayer(page)
        // The popup's location bar consumes a few rows above its web surface.
        // Anchor the web page at the top at its original aspect ratio and extend
        // its bottom edge across the short strip the tab will paint next.
        if page.frame.minY > 0, let lastRow = bitmap.cropping(to: CGRect(x: 0, y: bitmap.height - 1,
                                                                         width: bitmap.width, height: 1)) {
            let edge = CALayer()
            edge.contents = lastRow
            edge.frame = NSRect(x: 0, y: 0, width: size.width, height: page.frame.minY)
            edge.contentsGravity = .resize
            layer.addSublayer(edge)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Bark's controls on a Chromium popup window. Peek shows a link from a
/// pinned tab over its window and closes when that window is clicked; a
/// Little window shows a link from another app. Either can become a tab.
@MainActor final class PopupChrome: NSObject {
    private weak var window: NSWindow?
    private weak var owner: NSWindow?
    private weak var viewport: NSView?
    private var backdrop: PeekBackdrop?
    private var entranceSurface: PeekEntranceSurface?
    private var animationFrame: NSRect?
    private var attachedToOwner = false
    private var dismissalRequested = false
    private var placementScheduled = false
    private let kind: String
    private let context: UnsafeMutableRawPointer?
    private var callback: ChromiumCommand?
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var canSplit: Bool
    private let reduceMotion: () -> Bool
    private enum Promotion {
        case idle, animating(start: NSRect, time: TimeInterval, pageAlpha: CGFloat, railAlpha: CGFloat, backdropAlpha: CGFloat), submitted
    }
    private var promotion: Promotion = .idle
    private enum Entrance { case settled, prepared, playing(TimeInterval) }
    private var entrance: Entrance = .settled
    private var stopFrameUpdates: (() -> Void)?
    private static let snapDuration: TimeInterval = 0.22

    init(window: NSWindow, owner: NSWindow?, viewport: NSView?, kind: String, space: String, emoji: String, canSplit: Bool,
         context: UnsafeMutableRawPointer?, callback: ChromiumCommand?,
         waitForFirstPaint: Bool = false,
         pageColor: NSColor = .white,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.window = window
        self.owner = owner
        self.viewport = viewport
        self.kind = kind
        self.canSplit = canSplit
        self.context = context
        self.callback = callback
        self.reduceMotion = reduceMotion
        super.init()
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        let view = PopupChromeView(kind: kind, space: space, emoji: emoji, canSplit: canSplit) { [weak self] command in self?.performControl(command) }
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
        let springIn = kind == "peek" && owner != nil && !reduceMotion()
        if springIn { entrance = .prepared }
        if kind == "peek", let owner { attachPeek(to: owner, window: window, springIn: springIn, pageColor: pageColor) }
        window.addChildWindow(panel, ordered: .above)
        if springIn {
            if !waitForFirstPaint { beginEntrance() }
        } else {
            place()
        }
        panel.orderFront(nil)
        let center = NotificationCenter.default
        if kind == "peek", let owner {
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.removePaintedEntranceSurface() }
            })
            observePlacement(owner, [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                     NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification,
                                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification])
            if let viewport {
                viewport.postsFrameChangedNotifications = true
                observePlacement(viewport, [NSView.frameDidChangeNotification])
            }
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissFromOwner() }
            })
            for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.performControl("close") }
                })
            }
        } else {
            observePlacement(window, [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification])
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || event.window === self.panel,
                  let command = Self.command(characters: event.charactersIgnoringModifiers,
                      keyCode: event.keyCode, modifiers: event.modifierFlags,
                      kind: self.kind, canSplit: self.canSplit) else { return event }
            if !event.isARepeat { self.performControl(command) }
            return nil
        }
    }

    private func attachPeek(to owner: NSWindow, window: NSWindow, springIn: Bool, pageColor: NSColor) {
        guard let content = owner.contentView else { return }
        let scrim = PeekBackdrop(frame: content.bounds)
        scrim.dismiss = { [weak self] in self?.dismissFromOwner() }
        scrim.alphaValue = springIn ? 0 : 1
        content.addSubview(scrim, positioned: .above, relativeTo: nil)
        backdrop = scrim
        if springIn { entranceSurface = PeekEntranceSurface(in: content, color: pageColor) }

        // Chromium owns the in-page location bar and its security controls.
        // Only the AppKit frame and window buttons are removed.
        window.animationBehavior = .none
        panel?.animationBehavior = .none
        window.styleMask = .borderless
        window.isMovable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = !springIn
        if let page = window.contentView {
            page.wantsLayer = true
            page.layer?.cornerRadius = 10
            page.layer?.cornerCurve = .continuous
            page.layer?.masksToBounds = true
        }
        // Child windows can become visible as soon as they are attached.
        if let viewport = viewportFrame {
            placePeek(PeekLayout(viewport: viewport), entrance: springIn ? PeekEntrance(elapsed: 0) : nil)
        }
        if window.parent == nil {
            owner.addChildWindow(window, ordered: .above)
            attachedToOwner = true
        }
    }

    private func observePlacement(_ object: AnyObject, _ names: [Notification.Name]) {
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePlacement() }
            })
        }
    }

    private func schedulePlacement() {
        guard !placementScheduled else { return }
        placementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placementScheduled = false
            self.place()
        }
    }

    /// Match only popup-local shortcuts; ordinary page keys remain untouched.
    static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                        kind: String, canSplit: Bool) -> String? {
        let flags = modifiers.intersection(BarkShortcut.relevantModifiers)
        if flags == .command, characters?.lowercased() == "o" { return "expand" }
        let action = BarkShortcut.match(characters: characters, keyCode: keyCode, modifiers: modifiers)?.action
        if action == .copyURL { return "copyURL" }
        guard kind == "peek" else { return nil }
        if flags.isEmpty, keyCode == 53 { return "close" }
        if canSplit, action == .addSplit { return "split" }
        return nil
    }

    private var viewportFrame: NSRect? {
        guard let owner, let content = owner.contentView else { return nil }
        let bounds = content.convert(content.bounds, to: nil)
        if let viewport, viewport.window === owner {
            let visible = bounds.intersection(viewport.convert(viewport.bounds, to: nil))
            if !visible.isEmpty { return owner.convertToScreen(visible) }
        }
        return owner.convertToScreen(bounds)
    }

    private var promotionViewport: NSRect? {
        // A promoted tab fills the browser's page area even if its opener
        // occupied only one side of a split.
        if let owner, let frame = PageFrameHostingView.pageRect(in: owner), !frame.isEmpty { return frame }
        return viewportFrame
    }

    func handoffCover(_ image: NSImage) -> NSPanel? {
        guard kind == "peek", let owner, owner.isVisible, let viewport = promotionViewport, !viewport.isEmpty,
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let aligned = owner.backingAlignedRect(owner.convertFromScreen(viewport), options: .alignAllEdgesNearest)
        let frame = owner.convertToScreen(aligned)
        let cover = PeekCoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.isOpaque = false
        cover.backgroundColor = .clear
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        cover.animationBehavior = .none
        cover.contentView = PeekCoverView(bitmap: bitmap, size: frame.size, scale: owner.backingScaleFactor)
        // Keep this above Chromium's changing native views until the moved
        // renderer presents in the owner. The popup and its rail can close.
        owner.addChildWindow(cover, ordered: .above)
        cover.orderFront(nil)
        cover.displayIfNeeded()
        CATransaction.flush()
        return cover
    }

    private func place() {
        guard case .idle = promotion, let window, let panel, let content = panel.contentView else { return }
        if kind == "peek", let frame = viewportFrame {
            let sample: PeekEntrance?
            switch entrance {
            case .settled: sample = nil
            case .prepared: sample = PeekEntrance(elapsed: 0)
            case let .playing(started): sample = PeekEntrance(elapsed: CACurrentMediaTime() - started)
            }
            placePeek(PeekLayout(viewport: frame), entrance: sample)
            return
        }
        let size = content.fittingSize
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.maxX - size.width - 8, y: frame.maxY - size.height - 4,
                              width: size.width, height: size.height), display: true)
    }

    private func placePeek(_ layout: PeekLayout, entrance: PeekEntrance?) {
        guard let window, let panel else { return }
        let frame = entrance?.pageFrame(layout.page) ?? layout.page
        let rail = layout.controls.offsetBy(dx: frame.maxX - layout.page.maxX, dy: frame.maxY - layout.page.maxY)
        // Rendering at the resting size lets Chromium accept its first frame.
        // The compositor discards frames whose size differs from the NSWindow.
        if window.frame != layout.page { window.setFrame(layout.page, display: true) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case let .playing(started) = self.entrance {
            if animationFrame != layout.page {
                animationFrame = layout.page
                if let page = window.contentView, let layer = page.layer {
                    page.alphaValue = 1
                    layer.transform = CATransform3DIdentity
                    PeekEntrance.animate(layer, page: layout.page, startTime: started, opacity: \.pageOpacity)
                }
                if let surface = entranceSurface {
                    surface.setPageFrame(layout.page)
                    surface.card.opacity = 1
                    PeekEntrance.animate(surface.card, page: layout.page, startTime: started, opacity: \.pageOpacity)
                }
                if let backdrop, let layer = backdrop.layer {
                    backdrop.alphaValue = 1
                    PeekEntrance.animate(layer, page: nil, startTime: started, opacity: \.backdropOpacity)
                }
            }
        } else {
            window.contentView?.alphaValue = entrance?.pageOpacity ?? 1
            if let layer = window.contentView?.layer {
                layer.transform = entrance?.transform(on: layer, page: layout.page) ?? CATransform3DIdentity
            }
            entranceSurface?.setPageFrame(layout.page)
            backdrop?.alphaValue = entrance?.backdropOpacity ?? 1
        }
        CATransaction.commit()
        panel.alphaValue = entrance?.railOpacity ?? 1
        if panel.frame != rail { panel.setFrame(rail, display: true) }
    }

    var presentedPageFrame: NSRect? {
        guard let window else { return nil }
        let frame = window.frame
        switch entrance {
        case .settled: return frame
        case .prepared: return PeekEntrance(elapsed: 0).pageFrame(frame)
        case let .playing(started):
            if let layer = window.contentView?.layer, let visible = layer.presentation() {
                let t = visible.affineTransform()
                if t.a != 1 || t.d != 1 {
                    let dx = t.tx - (t.a - 1) * (layer.anchorPoint.x - 0.5) * layer.bounds.width
                    let dy = t.ty - (t.d - 1) * (layer.anchorPoint.y - 0.5) * layer.bounds.height
                    return frame.insetBy(dx: frame.width * (1 - t.a) / 2, dy: frame.height * (1 - t.d) / 2)
                        .offsetBy(dx: dx, dy: layer.superlayer?.isGeometryFlipped == true ? -dy : dy)
                }
            }
            return PeekEntrance(elapsed: CACurrentMediaTime() - started).pageFrame(frame)
        }
    }

    func beginEntrance() {
        guard case .prepared = entrance, let window else { return }
        if reduceMotion() { finishEntrance(); return }
        entrance = .playing(CACurrentMediaTime())
        place()
        CATransaction.flush()
        animateFrames(in: window, for: PeekEntrance.duration, selector: #selector(advanceEntrance(_:))) { [weak self] in
            self?.finishEntrance()
        }
    }

    @objc private func advanceEntrance(_ sender: AnyObject) {
        guard case let .playing(started) = entrance else { return }
        if CACurrentMediaTime() - started >= PeekEntrance.duration {
            finishEntrance()
        } else {
            place()
        }
    }

    private func finishEntrance() {
        if case .settled = entrance { return }
        endFrameUpdates()
        clearEntranceAnimations()
        place()
        removePaintedEntranceSurface()
    }

    private func clearEntranceAnimations() {
        entrance = .settled
        animationFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window?.contentView?.layer?.removeAnimation(forKey: "BarkPeekEntrance")
        window?.contentView?.layer?.transform = CATransform3DIdentity
        backdrop?.layer?.removeAnimation(forKey: "BarkPeekEntrance")
        entranceSurface?.card.removeAnimation(forKey: "BarkPeekEntrance")
        CATransaction.commit()
        window?.hasShadow = true
    }

    private func removePaintedEntranceSurface() {
        guard case .settled = entrance, (window?.alphaValue ?? 0) > 0 else { return }
        entranceSurface?.removeFromSuperview()
        entranceSurface = nil
    }

    private func dismissFromOwner() {
        // Changing key windows is part of promoting the live Chromium tab.
        guard case .idle = promotion else { return }
        performControl("close")
    }

    func performControl(_ command: String) {
        guard callback != nil else { return }
        if command == "close" {
            guard !dismissalRequested else { return }
            if case .submitted = promotion { return }
            if case .animating = promotion { cancelPromotion() }
            dismissalRequested = true
            // The same click can first activate the owner and then reach its
            // backdrop. A later click still works if the page cancels closing.
            DispatchQueue.main.async { [weak self] in self?.dismissalRequested = false }
        } else {
            guard case .idle = promotion, !dismissalRequested else { return }
            if command == "expand", kind == "peek" {
                startPromotion()
                return
            }
            guard command == "copyURL" || command == "expand" || (command == "split" && canSplit && kind == "peek") else { return }
        }
        dispatchCommand(command)
    }

    func copyURL(_ url: String) {
        guard let window else { return }
        ToastPresenter.shared.copyLink(url, over: window)
    }

    private func dispatchCommand(_ command: String) {
        guard let callback else { return }
        command.withCString { callback(context, $0) }
    }

    private func startPromotion() {
        let visibleFrame = presentedPageFrame
        let pageAlpha = window?.contentView?.layer?.presentation().map { CGFloat($0.opacity) } ?? window?.contentView?.alphaValue ?? 1
        let backdropAlpha = backdrop?.layer?.presentation().map { CGFloat($0.opacity) } ?? backdrop?.alphaValue ?? 1
        endFrameUpdates()
        clearEntranceAnimations()
        entranceSurface?.removeFromSuperview()
        entranceSurface = nil
        guard !reduceMotion(), let window, window.isVisible, let owner, promotionViewport != nil else {
            promotion = .submitted
            window?.contentView?.alphaValue = 1
            dispatchCommand("expand")
            return
        }
        if let visibleFrame, visibleFrame != window.frame { window.setFrame(visibleFrame, display: true) }
        window.contentView?.alphaValue = pageAlpha
        backdrop?.alphaValue = backdropAlpha
        promotion = .animating(start: owner.convertFromScreen(window.frame), time: ProcessInfo.processInfo.systemUptime,
                               pageAlpha: pageAlpha, railAlpha: panel?.alphaValue ?? 1, backdropAlpha: backdropAlpha)
        animateFrames(in: window, for: Self.snapDuration, selector: #selector(advancePromotion(_:))) { [weak self] in
            self?.finishPromotion()
        }
    }

    private func animateFrames(in window: NSWindow, for duration: TimeInterval, selector: Selector, finish: @escaping () -> Void) {
        let deadline = DispatchWorkItem(block: finish)
        // Finish even if the window is obscured and no longer receives ticks.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: deadline)
        if #available(macOS 14.0, *) {
            let link = window.displayLink(target: self, selector: selector)
            link.add(to: .main, forMode: .common)
            stopFrameUpdates = { link.invalidate(); deadline.cancel() }
        } else {
            let rate = max(60, window.screen?.maximumFramesPerSecond ?? 60)
            let timer = Timer(timeInterval: 1 / Double(rate), target: self, selector: selector,
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            stopFrameUpdates = { timer.invalidate(); deadline.cancel() }
        }
    }

    private func endFrameUpdates() {
        stopFrameUpdates?()
        stopFrameUpdates = nil
    }

    @objc private func advancePromotion(_ sender: AnyObject) {
        guard case let .animating(start, time, pageAlpha, railAlpha, backdropAlpha) = promotion,
              let window, let owner, let target = promotionViewport else { return }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - time) / Self.snapDuration))
        if progress >= 1 { finishPromotion(); return }
        let initial = owner.convertToScreen(start)
        let fraction = 1 - pow(1 - progress, 3)
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
        let frame = NSRect(x: blend(initial.minX, target.minX), y: blend(initial.minY, target.minY),
                           width: blend(initial.width, target.width), height: blend(initial.height, target.height))
        window.setFrame(frame, display: true)
        window.contentView?.alphaValue = pageAlpha + (1 - pageAlpha) * fraction
        panel?.alphaValue = railAlpha * max(0, 1 - 3 * progress)
        backdrop?.alphaValue = backdropAlpha * (1 - fraction)
    }

    private func finishPromotion() {
        guard case .animating = promotion else { return }
        promotion = .submitted
        endFrameUpdates()
        if let frame = promotionViewport { window?.setFrame(frame, display: true) }
        window?.contentView?.alphaValue = 1
        panel?.alphaValue = 0
        backdrop?.alphaValue = 0
        dispatchCommand("expand")
    }

    private func cancelPromotion() {
        endFrameUpdates()
        promotion = .idle
        panel?.alphaValue = 1
        backdrop?.alphaValue = 1
        place()
    }

    func setCanSplit(_ enabled: Bool) {
        guard kind == "peek", enabled != canSplit else { return }
        canSplit = enabled
        (panel?.contentView as? NSHostingView<PopupChromeView>)?.rootView.canSplit = enabled
    }

    func detach() {
        callback = nil
        endFrameUpdates()
        if kind == "peek" { clearEntranceAnimations() }
        entranceSurface?.removeFromSuperview()
        entranceSurface = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if attachedToOwner, let window, window.parent === owner { owner?.removeChildWindow(window) }
        backdrop?.removeFromSuperview()
        backdrop = nil
    }
}

private struct PopupChromeView: View {
    let kind: String
    let space: String
    let emoji: String
    var canSplit: Bool
    let action: (String) -> Void
    var body: some View {
        if kind == "peek" {
            VStack(spacing: PeekLayout.buttonSpacing) {
                button("xmark", "Close Peek", command: "close", shortcut: "Esc")
                button("plus", "Open as tab", command: "expand", shortcut: "⌘O")
                button("rectangle.split.2x1", "Open in Split View", command: "split", shortcut: "⌃⇧=", enabled: canSplit)
            }.fixedSize().accessibilityElement(children: .contain)
        } else {
            HStack(spacing: 2) {
                Button { action("expand") } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .semibold))
                        Text(space.isEmpty ? "Open in Bark" : "Open in \(emoji.isEmpty ? "" : emoji + " ")\(space)")
                            .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    }.padding(.horizontal, 10).frame(height: 24).contentShape(Capsule())
                }.buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                    .help("Move this page into your Bark window (⌘O)").accessibilityLabel("Open in Bark")
            }.padding(3).foregroundStyle(.secondary)
        }
    }
    private func button(_ symbol: String, _ label: String, command: String, shortcut: String, enabled: Bool = true) -> some View {
        Button { action(command) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .frame(width: PeekLayout.buttonSize, height: PeekLayout.buttonSize)
                .contentShape(Circle())
        }.buttonStyle(PeekButtonStyle()).disabled(!enabled)
            .help(enabled ? "\(label) (\(shortcut))" : "Split View is unavailable for this tab")
            .accessibilityLabel(label).accessibilityHint(enabled ? shortcut : "Unavailable for this tab")
    }
}

private struct PeekButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(enabled ? 0.95 : 0.42))
            .background {
                Circle().fill(Color(red: 0.035, green: 0.038, blue: 0.12))
                    .overlay(Circle().fill(.white.opacity(configuration.isPressed ? 0.24 : hovered && enabled ? 0.12 : 0)))
            }
            .onHover { hovered = $0 }
    }
}

// MARK: Media player

/// Media playing in another tab: play or pause it, mute it, or go to it.
struct SidebarMediaPlayer: View {
    @ObservedObject var model: ChromiumSidebarModel
    let media: ChromiumMedia
    var body: some View {
        HStack(spacing: 9) {
            Button { model.send("select", id: media.id) } label: {
                HStack(spacing: 9) {
                    Group {
                        if let icon = FaviconCache.image(media.favicon) { Image(nsImage: icon).resizable().scaledToFit() }
                        else { Image(systemName: "music.note").foregroundStyle(.secondary) }
                    }.frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.heading).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !media.detail.isEmpty {
                            Text(media.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Go to this tab").accessibilityLabel("Go to " + media.heading)
            control(media.playing ? "pause.fill" : "play.fill", media.playing ? "Pause" : "Play") {
                model.send("mediaToggle", id: media.id)
            }
            control(media.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill", media.muted == true ? "Unmute" : "Mute") {
                model.send("mute", id: media.id)
            }
        }.padding(.leading, 10).padding(.trailing, 4).frame(height: 44)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain).accessibilityLabel("Now playing")
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 30) }
            .buttonStyle(SidebarControlStyle()).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
}

typealias SidebarControlStyle = BarkControlStyle

// MARK: C ABI

@_cdecl("BarkSwiftPopupAttach")
@MainActor func barkSwiftPopupAttach(_ window: UnsafeMutableRawPointer, _ owner: UnsafeMutableRawPointer?, _ viewport: UnsafeMutableRawPointer?,
                                     _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
                                     _ callback: ChromiumCommand?) -> UnsafeMutableRawPointer? {
    let popup = Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue()
    let ownerWindow = owner.map { Unmanaged<NSWindow>.fromOpaque($0).takeUnretainedValue() }
    let viewportView = viewport.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    let data = String(cString: json).data(using: .utf8) ?? Data()
    let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let color = (config["backgroundColor"] as? String).flatMap { SpaceGradientCanvas.isColor($0) ? SpaceGradientCanvas.nsColor($0) : nil }
    let chrome = PopupChrome(window: popup, owner: ownerWindow, viewport: viewportView, kind: config["kind"] as? String ?? "peek",
                             space: config["space"] as? String ?? "", emoji: config["emoji"] as? String ?? "",
                             canSplit: config["canSplit"] as? Bool ?? false,
                             context: context, callback: callback, waitForFirstPaint: true, pageColor: color ?? .white)
    return Unmanaged.passRetained(chrome).toOpaque()
}

@_cdecl("BarkSwiftPopupBeginEntrance")
@MainActor func barkSwiftPopupBeginEntrance(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().beginEntrance()
}

@_cdecl("BarkSwiftPopupSetCanSplit")
@MainActor func barkSwiftPopupSetCanSplit(_ handle: UnsafeMutableRawPointer, _ enabled: Bool) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().setCanSplit(enabled)
}

@_cdecl("BarkSwiftPopupCopyURL")
@MainActor func barkSwiftPopupCopyURL(_ handle: UnsafeMutableRawPointer, _ url: UnsafePointer<CChar>) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().copyURL(String(cString: url))
}

@_cdecl("BarkSwiftPopupCover")
@MainActor func barkSwiftPopupCover(_ handle: UnsafeMutableRawPointer, _ image: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let chrome = Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue()
    let snapshot = Unmanaged<NSImage>.fromOpaque(image).takeUnretainedValue()
    return chrome.handoffCover(snapshot).map { Unmanaged.passRetained($0).toOpaque() }
}

@_cdecl("BarkSwiftPopupRemoveCover")
@MainActor func barkSwiftPopupRemoveCover(_ handle: UnsafeMutableRawPointer) {
    let cover = Unmanaged<NSPanel>.fromOpaque(handle).takeRetainedValue()
    cover.parent?.removeChildWindow(cover)
    cover.orderOut(nil)
}

@_cdecl("BarkSwiftPopupPerformControl")
@MainActor func barkSwiftPopupPerformControl(_ handle: UnsafeMutableRawPointer, _ command: UnsafePointer<CChar>) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().performControl(String(cString: command))
}

@_cdecl("BarkSwiftPopupDetach")
@MainActor func barkSwiftPopupDetach(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeRetainedValue().detach()
}
