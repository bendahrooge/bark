import AppKit
import Combine
import SwiftUI
import BarkCore

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
        // A frame captured during resize can be shorter than the destination.
        // Extend its bottom edge until the tab paints at its new size.
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

struct LittleWindowSpace: Decodable, Equatable {
    let id: String
    let name: String
    let emoji: String?
    var gradientCanvas: SpaceGradientCanvas?

    var displayName: String { name == "Your Chromium" ? "Personal" : name }
    var label: String {
        guard let emoji, !emoji.isEmpty else { return displayName }
        return emoji + " " + displayName
    }
}

/// A borderless native button. The header draws the shared address and promotion
/// surfaces, so neighboring actions can have independent hover and focus states.
@MainActor private final class LittleHeaderButton: NSButton {
    let command: String
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(_ id: String, action: String, help: String, symbol: String? = nil) {
        command = action
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("BarkLittle" + id)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = help
        setAccessibilityLabel(help)
        if let symbol { image = Self.symbol(symbol, size: 15); imagePosition = .imageOnly }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.15 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor private final class LittleWindowHeader: NSView {
    static let height: CGFloat = 46
    let address = LittleHeaderButton("Address", action: "editAddress", help: "Search or enter a URL (⌘L)")
    let siteInfo = LittleHeaderButton("SiteInfo", action: "siteInfo", help: "Site information")
    let extensions = LittleHeaderButton("Extensions", action: "extensions", help: "Extensions", symbol: "puzzlepiece.extension")
    let copy = LittleHeaderButton("CopyURL", action: "copyURL", help: "Copy link (⇧⌘C)", symbol: "link")
    let open = LittleHeaderButton("Open", action: "expand", help: "Open in Bark (⌘O)")
    let choose = LittleHeaderButton("ChooseSpace", action: "chooseSpace", help: "Choose a Space (⇧⌘O)", symbol: "chevron.down")
    private(set) var editor: NSTextField?
    private var active: LittleWindowSpace?
    private var defaultID: String?
    private var spaces: [LittleWindowSpace] = []
    private var site = ""
    private var security = ""
    private var fieldRect = NSRect.zero
    private var actionRect = NSRect.zero
    private var keycap = NSRect.zero
    var send: ((String) -> Void)?
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private var foreground: NSColor { dark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1) }
    private var secondary: NSColor { foreground.withAlphaComponent(0.72) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("BarkLittleHeader")
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Little window")
        for button in [address, siteInfo, extensions, copy, open, choose] {
            addSubview(button)
            button.target = self
            button.action = #selector(pressed(_:))
        }
        address.cell?.lineBreakMode = .byTruncatingHead
        choose.image = LittleHeaderButton.symbol("chevron.down", size: 11)
        choose.menu = NSMenu(title: "Open in Space")
        setPage(site: "", security: "", description: "", canShowSiteInfo: false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }

    func update(activeID: String?, spaces: [LittleWindowSpace]) {
        guard defaultID != activeID || self.spaces != spaces else { return }
        defaultID = activeID
        self.spaces = spaces
        active = spaces.first { $0.id == activeID }
        let menu = choose.menu
        menu?.removeAllItems()
        for space in spaces {
            let item = NSMenuItem(title: space.label, action: #selector(openSpace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.state = space.id == activeID ? .on : .off
            menu?.addItem(item)
        }
        choose.isEnabled = !spaces.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    func setPage(site: String, security: String, description: String, canShowSiteInfo: Bool) {
        self.site = site
        self.security = security
        address.toolTip = site.isEmpty ? "Search or enter a URL (⌘L)" : site + " · Edit address (⌘L)"
        address.setAccessibilityLabel(site.isEmpty ? "Search or enter a URL" : site + ", edit address")
        siteInfo.toolTip = description.isEmpty ? "Site information" : description
        siteInfo.setAccessibilityHelp(siteInfo.toolTip)
        siteInfo.isEnabled = canShowSiteInfo
        copy.isEnabled = !site.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .medium,
                      color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                       .foregroundColor: color ?? foreground])
    }

    override func layout() {
        super.layout()
        let top = (bounds.height - 31) / 2
        let compact = bounds.width < 500
        let captionEnd = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }.filter { !$0.isHidden }
            .map { convert($0.bounds, from: $0).maxX }.max() ?? 68
        let start = max(80, captionEnd + 13)
        let end = bounds.width - 7
        let title = active?.displayName ?? "Bark"
        let promotion = "Open in " + title
        let openWidth: CGFloat = compact ? 31 : min(188, text(promotion, size: 13, weight: .semibold).size().width.rounded(.up) + 17)
        let keyWidth: CGFloat = bounds.width >= 660 ? 32 : 0
        let menuWidth: CGFloat = compact ? 22 : 29
        let width = openWidth + keyWidth + menuWidth + (compact ? 3 : 6)
        actionRect = NSRect(x: end - width, y: top, width: width, height: 31)
        fieldRect = NSRect(x: start, y: top, width: max(0, actionRect.minX - start - 7), height: 31)
        open.setAccessibilityLabel(promotion)
        open.toolTip = promotion + " (⌘O)"
        let openTitle = NSMutableAttributedString(attributedString: text("Open in ", size: 13, weight: .medium, color: secondary))
        openTitle.append(text(title, size: 13, weight: .semibold))
        open.attributedTitle = compact ? NSAttributedString(string: "") : openTitle
        open.imagePosition = compact ? .imageOnly : .noImage
        open.image = compact ? LittleHeaderButton.symbol("arrow.up.right", size: 14) : nil
        open.frame = NSRect(x: actionRect.minX + 1, y: top + 1, width: openWidth + 2, height: 29)
        keycap = keyWidth > 0 ? NSRect(x: open.frame.maxX + 1, y: top + 7, width: keyWidth - 3, height: 17) : .zero
        choose.frame = NSRect(x: end - menuWidth - 1, y: top + 1, width: menuWidth, height: 29)
        for button in [extensions, copy, choose] { button.contentTintColor = secondary }
        open.contentTintColor = foreground
        let utilitiesVisible = editor == nil && fieldRect.width >= 248
        extensions.isHidden = !utilitiesVisible
        copy.isHidden = !utilitiesVisible
        copy.frame = NSRect(x: fieldRect.maxX - 31, y: top + 2, width: 27, height: 27)
        extensions.frame = copy.frame.offsetBy(dx: -31, dy: 0)
        let showSpaceName = fieldRect.width >= 357 && editor == nil
        let isWarning = security == "warning" || security == "dangerous"
        let emoji = active?.emoji ?? ""
        let identity = showSpaceName ? (active?.displayName ?? "Bark") : ""
        let badgeText = (!isWarning && !emoji.isEmpty ? emoji + (identity.isEmpty ? "" : " ") : "") + identity
        siteInfo.attributedTitle = text(badgeText, size: 11, weight: .semibold)
        let symbol = isWarning ? "exclamationmark.triangle.fill" : "face.smiling"
        siteInfo.image = isWarning || emoji.isEmpty ? LittleHeaderButton.symbol(symbol, size: 12) : nil
        siteInfo.imagePosition = siteInfo.image == nil ? .noImage : badgeText.isEmpty ? .imageOnly : .imageLeading
        siteInfo.contentTintColor = isWarning ? (security == "dangerous" ? .systemRed : .systemOrange) : foreground
        let badgeWidth = min(fieldRect.width * 0.32, max(24, text(badgeText, size: 11, weight: .semibold).size().width +
                                                           (siteInfo.image == nil ? 13 : 26)))
        siteInfo.frame = NSRect(x: start + 7, y: top + 5, width: badgeWidth, height: 21)
        siteInfo.isHidden = fieldRect.width < 92 || editor != nil
        // Keep the origin centered in the complete address well as long as
        // it fits. Long origins use the full safe span between the controls.
        let left = siteInfo.isHidden ? fieldRect.minX + 4 : siteInfo.frame.maxX + 4
        let right = utilitiesVisible ? extensions.frame.minX - 3 : fieldRect.maxX - 4
        let label = site.isEmpty ? "Search or enter a URL" : site
        let natural = text(label, size: 13, weight: .semibold).size().width.rounded(.up) + 14
        let visibleWidth = max(0, min(natural, right - left))
        let centerX = min(max(left + visibleWidth / 2, fieldRect.midX), right - visibleWidth / 2)
        address.frame = NSRect(x: centerX - visibleWidth / 2, y: top + 1, width: visibleWidth, height: 29)
        address.attributedTitle = text(label, size: 13, weight: .semibold, color: site.isEmpty ? secondary : foreground)
        address.isHidden = editor != nil
        editor?.frame = fieldRect.insetBy(dx: 11, dy: 6)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = active?.gradientCanvas.flatMap { $0.isValid ? SpaceGradientCanvas.nsColor($0.endColor) : nil }
        let start = SpaceGradientCanvas.nsColor(dark ? "#0D0E20" : "#E0E2F0")
        let end = SpaceGradientCanvas.nsColor(dark ? "#1A0F20" : "#EEE4EE")
        let tinted = accent.flatMap { end.blended(withFraction: dark ? 0.06 : 0.10, of: $0) } ?? end
        NSGradient(starting: start, ending: tinted)?.draw(in: bounds, angle: 0)
        func surface(_ rect: NSRect, fill: NSColor, border: NSColor?, radius: CGFloat) {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
        }
        surface(fieldRect, fill: SpaceGradientCanvas.nsColor(dark ? "#282636" : "#F3F2F8"),
                border: editor == nil ? nil : NSColor.controlAccentColor, radius: 6)
        if !siteInfo.isHidden {
            surface(siteInfo.frame, fill: foreground.withAlphaComponent(dark ? 0.045 : 0.065), border: nil, radius: 10)
        }
        surface(actionRect, fill: SpaceGradientCanvas.nsColor(dark ? "#080920" : "#FCFAFF"),
                border: foreground.withAlphaComponent(0.14), radius: 6)
        foreground.withAlphaComponent(0.15).setFill()
        NSRect(x: choose.frame.minX - 1, y: actionRect.minY + 7, width: 1, height: 17).fill()
        if !keycap.isEmpty {
            surface(keycap, fill: foreground.withAlphaComponent(0.09), border: nil, radius: 3)
            let hint = text("⌘O", size: 11, weight: .semibold, color: secondary)
            hint.draw(at: NSPoint(x: keycap.midX - hint.size().width / 2, y: keycap.midY - hint.size().height / 2))
        }
        foreground.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit owns the traffic lights and their surrounding drag area.
        guard convert(point, from: superview).x >= fieldRect.minX else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if fieldRect.contains(point) { send?("editAddress") }
        else if actionRect.contains(point) { send?("expand") }
        else if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
    @objc private func pressed(_ sender: LittleHeaderButton) { send?(sender.command) }
    @objc private func openSpace(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { send?("expand:" + id) }
    }
    func showMenu() { choose.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: choose.bounds.maxY + 3), in: choose) }
    var defaultCommand: String { defaultID.map { "expand:" + $0 } ?? "expand" }

    func beginEditing(_ value: String, delegate: NSTextFieldDelegate, target: AnyObject, action: Selector) {
        if let editor { editor.currentEditor()?.selectAll(nil); return }
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier("BarkLittleEditor")
        field.placeholderString = "Search or enter a URL"
        field.setAccessibilityLabel("Search or enter a URL")
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = foreground
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = delegate
        field.target = target
        field.action = action
        editor = field
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }
    func endEditing() {
        guard let field = editor else { return }
        editor = nil
        field.target = nil
        field.delegate = nil
        field.removeFromSuperview()
        needsLayout = true
        needsDisplay = true
    }
}

/// Bark's controls on a Chromium popup window. Peek shows a link from a
/// pinned tab over its window and closes when that window is clicked; a
/// Little window shows a link from another app. Either can become a tab.
@MainActor final class PopupChrome: NSObject, NSTextFieldDelegate {
    private weak var window: NSWindow?
    private weak var owner: NSWindow?
    private weak var viewport: NSView?
    private var freshAddressActivation: NSObjectProtocol?
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
    private var littleControls: LittleWindowHeader?
    private var originalTitleVisibility: NSWindow.TitleVisibility = .visible
    private var originalTransparentTitlebar = false
    private var originalFullSizeContent = false
    private var originalSeparator: NSTitlebarSeparatorStyle = .automatic
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

    init(window: NSWindow, owner: NSWindow?, viewport: NSView?, kind: String, canSplit: Bool,
         activeSpace: String? = nil, spaces: [LittleWindowSpace] = [],
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
        let center = NotificationCenter.default
        if kind == "little" {
            originalTitleVisibility = window.titleVisibility
            originalTransparentTitlebar = window.titlebarAppearsTransparent
            originalFullSizeContent = window.styleMask.contains(.fullSizeContentView)
            originalSeparator = window.titlebarSeparatorStyle
            let header = LittleWindowHeader(frame: .zero)
            littleControls = header
            header.send = { [weak self] in self?.performControl($0) }
            header.update(activeID: activeSpace, spaces: spaces)
            setLittleTitlebar(in: window, visible: !window.styleMask.contains(.fullScreen))
            if let content = window.contentView {
                header.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(header, positioned: .above, relativeTo: nil)
                NSLayoutConstraint.activate([
                    header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    header.topAnchor.constraint(equalTo: content.topAnchor),
                    header.heightAnchor.constraint(equalToConstant: LittleWindowHeader.height),
                ])
                content.layoutSubtreeIfNeeded()
            }
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.setLittleTitlebar(in: window, visible: notification.name == NSWindow.didExitFullScreenNotification)
                    }
                })
            }
        } else if let owner {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = NSHostingView(rootView: PeekControlsView(canSplit: canSplit) { [weak self] in self?.performControl($0) })
            self.panel = panel
            let springIn = !reduceMotion()
            if springIn { entrance = .prepared }
            attachPeek(to: owner, window: window, springIn: springIn, pageColor: pageColor)
            window.addChildWindow(panel, ordered: .above)
            if springIn {
                if !waitForFirstPaint { beginEntrance() }
            } else {
                place()
            }
            panel.orderFront(nil)
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
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || (self.panel != nil && event.window === self.panel) ||
                      (self.addressEditorVisible && event.window === self.littleControls?.editor?.window),
                  let command = Self.command(characters: event.charactersIgnoringModifiers,
                      keyCode: event.keyCode, modifiers: event.modifierFlags,
                      kind: self.kind, canSplit: self.canSplit) else { return event }
            if !event.isARepeat { self.performControl(command) }
            return nil
        }
    }

    private func setLittleTitlebar(in window: NSWindow, visible: Bool) {
        littleControls?.isHidden = !visible
        window.titleVisibility = visible ? .hidden : originalTitleVisibility
        window.titlebarAppearsTransparent = visible || originalTransparentTitlebar
        window.titlebarSeparatorStyle = visible ? .none : originalSeparator
        // Changing fullSizeContentView on an existing restored popup can resize
        // its frame. Preserve both its position and its saved outer dimensions.
        let fullSize = visible || originalFullSizeContent
        if window.styleMask.contains(.fullSizeContentView) != fullSize {
            let frame = window.frame
            if fullSize { window.styleMask.insert(.fullSizeContentView) }
            else { window.styleMask.remove(.fullSizeContentView) }
            window.setFrame(frame, display: false)
        }
        if !visible { littleControls?.endEditing() }
    }

    func setSite(_ site: String, security: String, description: String, canShowSiteInfo: Bool) {
        littleControls?.setPage(site: site, security: security, description: description, canShowSiteInfo: canShowSiteInfo)
    }

    func anchorX(extensions: Bool) -> Double {
        guard let header = littleControls else { return 0 }
        header.layoutSubtreeIfNeeded()
        let button = extensions ? header.extensions : header.siteInfo
        let anchor = button.isHidden ? header.address : button
        return anchor.convert(anchor.bounds, to: nil).midX
    }

    private func attachPeek(to owner: NSWindow, window: NSWindow, springIn: Bool, pageColor: NSColor) {
        guard let content = owner.contentView else { return }
        let scrim = PeekBackdrop(frame: content.bounds)
        scrim.dismiss = { [weak self] in self?.dismissFromOwner() }
        scrim.alphaValue = springIn ? 0 : 1
        content.addSubview(scrim, positioned: .above, relativeTo: nil)
        backdrop = scrim
        if springIn { entranceSurface = PeekEntranceSurface(in: content, color: pageColor) }

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
        if kind == "little" {
            if flags == [.command, .shift], characters?.lowercased() == "o" { return "chooseSpace" }
            if flags == .command, characters?.lowercased() == "l" { return "editAddress" }
        }
        let action = BarkShortcut.match(characters: characters, keyCode: keyCode, modifiers: modifiers)?.action
        if kind == "little", action == .newLittleWindow { return "newLittleWindow" }
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
        guard case .idle = promotion, let frame = viewportFrame else { return }
        let sample: PeekEntrance?
        switch entrance {
        case .settled: sample = nil
        case .prepared: sample = PeekEntrance(elapsed: 0)
        case let .playing(started): sample = PeekEntrance(elapsed: CACurrentMediaTime() - started)
        }
        placePeek(PeekLayout(viewport: frame), entrance: sample)
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
            if let littleControls {
                switch command {
                case "chooseSpace": littleControls.showMenu()
                case "expand": dispatchCommand(littleControls.defaultCommand)
                case "copyURL", "editAddress", "newLittleWindow", "siteInfo", "extensions": dispatchCommand(command)
                default:
                    if command.hasPrefix("expand:") { dispatchCommand(command) }
                }
                return
            }
            if command == "expand" {
                startPromotion()
                return
            }
            guard command == "copyURL" || (command == "split" && canSplit) else { return }
        }
        dispatchCommand(command)
    }

    func editAddress(_ url: String, whenKey: Bool) {
        guard kind == "little", callback != nil, let window else { return }
        if let editor = littleControls?.editor {
            editor.currentEditor()?.selectAll(nil)
            return
        }
        if whenKey && !window.isKeyWindow && freshAddressActivation == nil {
            // A lookup summoned from another app may still be activating.
            // If a different window wins focus, discard this pending edit.
            freshAddressActivation = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                    object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.freshAddressActivation != nil else { return }
                    self.clearAddressActivation()
                    self.editAddress(url, whenKey: false)
                }
            }
        }
        guard window.isKeyWindow, window.isVisible, let header = littleControls, !header.isHidden else { return }
        header.beginEditing(url, delegate: self, target: self, action: #selector(submitAddress(_:)))
    }

    var addressEditorVisible: Bool { littleControls?.editor != nil }

    private func clearAddressActivation() {
        if let freshAddressActivation { NotificationCenter.default.removeObserver(freshAddressActivation) }
        freshAddressActivation = nil
    }

    @objc private func submitAddress(_ field: NSTextField) {
        guard field === littleControls?.editor else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        littleControls?.endEditing()
        dispatchCommand(value.isEmpty ? "focusPage" : "navigate:" + value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // AppKit sends this before the field action on Return.
        if let movement = notification.userInfo?["NSTextMovement"] as? Int, movement == NSTextMovement.return.rawValue { return }
        littleControls?.endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), let editor = littleControls?.editor, control === editor else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            submitAddress(editor)
            return true
        }
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        littleControls?.endEditing()
        dispatchCommand("focusPage")
        return true
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
        (panel?.contentView as? NSHostingView<PeekControlsView>)?.rootView.canSplit = enabled
    }

    func setSpaces(activeID: String?, spaces: [LittleWindowSpace]) {
        littleControls?.update(activeID: activeID, spaces: spaces)
    }

    func detach() {
        callback = nil
        clearAddressActivation()
        littleControls?.endEditing()
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
        if let header = littleControls {
            header.removeFromSuperview()
            if let window { setLittleTitlebar(in: window, visible: false) }
        }
        littleControls = nil
        if attachedToOwner, let window, window.parent === owner { owner?.removeChildWindow(window) }
        backdrop?.removeFromSuperview()
        backdrop = nil
    }
}

private struct PeekControlsView: View {
    var canSplit: Bool
    let action: (String) -> Void
    var body: some View {
        VStack(spacing: PeekLayout.buttonSpacing) {
            button("xmark", "Close Peek", command: "close", shortcut: "Esc")
            button("plus", "Open as tab", command: "expand", shortcut: "⌘O")
            button("rectangle.split.2x1", "Open in Split View", command: "split", shortcut: "⌃⇧=", enabled: canSplit)
        }.fixedSize().accessibilityElement(children: .contain)
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

// MARK: C ABI

private struct PopupConfiguration: Decodable {
    let kind: String?
    let canSplit: Bool?
    let backgroundColor: String?
    let activeSpace: String?
    let spaces: [LittleWindowSpace]?
    let site: String?
    let security: String?
    let securityDescription: String?
    let canShowSiteInfo: Bool?

    static func decode(_ json: UnsafePointer<CChar>) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(String(cString: json).utf8))
    }
}

@_cdecl("BarkSwiftPopupAttach")
@MainActor func barkSwiftPopupAttach(_ window: UnsafeMutableRawPointer, _ owner: UnsafeMutableRawPointer?, _ viewport: UnsafeMutableRawPointer?,
                                     _ json: UnsafePointer<CChar>, _ context: UnsafeMutableRawPointer?,
                                     _ callback: ChromiumCommand?) -> UnsafeMutableRawPointer? {
    let popup = Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue()
    let ownerWindow = owner.map { Unmanaged<NSWindow>.fromOpaque($0).takeUnretainedValue() }
    let viewportView = viewport.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    guard let config = PopupConfiguration.decode(json) else { return nil }
    let color = config.backgroundColor.flatMap { SpaceGradientCanvas.isColor($0) ? SpaceGradientCanvas.nsColor($0) : nil }
    let chrome = PopupChrome(window: popup, owner: ownerWindow, viewport: viewportView, kind: config.kind ?? "peek",
                             canSplit: config.canSplit ?? false, activeSpace: config.activeSpace, spaces: config.spaces ?? [],
                             context: context, callback: callback, waitForFirstPaint: true, pageColor: color ?? .white)
    chrome.setSite(config.site ?? "", security: config.security ?? "", description: config.securityDescription ?? "",
                   canShowSiteInfo: config.canShowSiteInfo ?? false)
    return Unmanaged.passRetained(chrome).toOpaque()
}

@_cdecl("BarkSwiftPopupUpdateSite")
@MainActor func barkSwiftPopupUpdateSite(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    guard let config = PopupConfiguration.decode(json) else { return }
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().setSite(
        config.site ?? "", security: config.security ?? "", description: config.securityDescription ?? "",
        canShowSiteInfo: config.canShowSiteInfo ?? false)
}

@_cdecl("BarkSwiftPopupAnchorX")
@MainActor func barkSwiftPopupAnchorX(_ handle: UnsafeMutableRawPointer, _ extensions: Bool) -> Double {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().anchorX(extensions: extensions)
}

@_cdecl("BarkSwiftPopupSetSpaces")
@MainActor func barkSwiftPopupSetSpaces(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    guard let config = PopupConfiguration.decode(json), let spaces = config.spaces else { return }
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().setSpaces(activeID: config.activeSpace, spaces: spaces)
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

@_cdecl("BarkSwiftPopupEditAddress")
@MainActor func barkSwiftPopupEditAddress(_ handle: UnsafeMutableRawPointer, _ url: UnsafePointer<CChar>, _ whenKey: Bool = false) {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().editAddress(String(cString: url), whenKey: whenKey)
}

@_cdecl("BarkSwiftPopupAddressVisible")
@MainActor func barkSwiftPopupAddressVisible(_ handle: UnsafeMutableRawPointer) -> Bool {
    Unmanaged<PopupChrome>.fromOpaque(handle).takeUnretainedValue().addressEditorVisible
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
