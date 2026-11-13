import AppKit
import SwiftUI

// Observe pointer position at the window level: embedded Chromium NSViews can
// otherwise swallow SwiftUI's hover events. This view never captures clicks.
struct SidebarHoverSensor: NSViewRepresentable {
    var revealWidth: Double
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> SensorView { SensorView() }
    func updateNSView(_ view: SensorView, context: Context) { view.revealWidth = revealWidth; view.changed = changed }

    final class SensorView: NSView {
        var revealWidth: Double = 0
        var changed: ((Bool) -> Void)?
        private var monitor: Any?
        private var area: NSTrackingArea?
        private var inside = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                self.updateInside(self.revealWidth > 0 && self.bounds.contains(point) && point.x <= self.revealWidth)
                return event
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area); self.area = area
        }
        override func mouseExited(with event: NSEvent) { updateInside(false) }
        private func updateInside(_ value: Bool) {
            guard inside != value else { return }
            inside = value
            changed?(value)
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
