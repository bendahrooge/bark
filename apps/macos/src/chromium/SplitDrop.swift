import AppKit
import Combine
import SwiftUI
import BarkCore

/// Previews split drops over the page and a new window outside its bounds.
/// A child panel remains visible beyond the clipped sidebar and browser.
@MainActor final class SplitDropController {
    enum Side: String { case left, right, top, bottom }
    private var panel: NSPanel?
    private var label: NSTextField?
    private weak var parent: NSWindow?

    static func isOutsideWindow(_ point: NSPoint, window: NSRect) -> Bool {
        !window.contains(point)
    }

    static func pointerLocation(in window: NSWindow) -> NSPoint {
        // The captured drag event still belongs to its source window after
        // the pointer leaves it. This also handles displays with other origins.
        if let event = NSApp.currentEvent, event.window === window,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    static func newWindowPoint(from view: NSView?) -> NSPoint? {
        guard let window = view?.window else { return nil }
        let point = pointerLocation(in: window)
        return isOutsideWindow(point, window: window.frame) ? point : nil
    }

    func updateNewWindow(from view: NSView?, title: String) -> Bool {
        guard let window = view?.window, let point = Self.newWindowPoint(from: view) else { return false }
        var frame = NSRect(x: point.x + 16, y: point.y - 80, width: 260, height: 64)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        show(frame, over: window, title: "New window\n" + title)
        return true
    }

    /// The page area of `window` in screen coordinates: everything beside the
    /// sidebar, below the titlebar strip. A collapsed sidebar floats over the
    /// page, which then spans the window.
    static func pageRect(window: NSRect, sidebar: NSRect, floating: Bool) -> NSRect {
        let left = floating ? window.minX : min(max(sidebar.maxX, window.minX), window.maxX)
        let top = min(max(sidebar.maxY, window.minY), window.maxY)
        return NSRect(x: left, y: window.minY, width: window.maxX - left, height: top - window.minY)
    }

    static func side(at point: NSPoint, page: NSRect, sidebar: NSRect) -> Side? {
        guard page.width >= 200, page.height > 0, page.contains(point), !sidebar.contains(point) else { return nil }
        // Choose the nearest edge in normalized page coordinates so all four
        // directions remain reachable in both wide and tall windows.
        let x = (point.x - page.midX) / page.width
        let y = (point.y - page.midY) / page.height
        if abs(y) > abs(x) { return y > 0 ? .top : .bottom }
        return x < 0 ? .left : .right
    }

    static func halfRect(for side: Side, page: NSRect) -> NSRect {
        var half = page
        switch side {
        case .left, .right:
            half.size.width = page.width / 2
            if side == .right { half.origin.x = page.midX }
        case .top, .bottom:
            half.size.height = page.height / 2
            // AppKit screen coordinates increase upward.
            if side == .top { half.origin.y = page.midY }
        }
        return half
    }

    /// Call while dragging. Returns the half under the pointer, or nil when
    /// the pointer is not over the page.
    func update(from view: NSView?, floating: Bool, title: String) -> Side? {
        guard let view, let window = view.window else { end(); return nil }
        let sidebar = window.convertToScreen(view.convert(view.bounds, to: nil))
        let page = PageFrameHostingView.pageRect(in: window)
            ?? Self.pageRect(window: window.frame, sidebar: sidebar, floating: floating)
        guard let side = Self.side(at: Self.pointerLocation(in: window), page: page, sidebar: sidebar) else { end(); return nil }
        let half = Self.halfRect(for: side, page: page)
        show(half.insetBy(dx: 6, dy: 6), over: window, title: "Split with " + title)
        return side
    }

    func end() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
    }

    private func show(_ frame: NSRect, over window: NSWindow, title: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = title
        panel.setFrame(frame, display: true)
        if parent !== window {
            parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 2
        content.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        content.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
        panel.contentView = content
        self.label = label
        return panel
    }
}
