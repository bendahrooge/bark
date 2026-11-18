import AppKit
import SwiftUI

private final class FeedbackSink { var messages: [[String: Any]] = [] }

// NSEvent's enter/exit factory only accepts a legacy tracking number. SwiftUI
// uses the tracking area on the event to identify its own hover notifications.
@MainActor private final class HeaderTrackingEvent: NSEvent {
    var area: NSTrackingArea?
    var point = NSPoint.zero
    var kind: NSEvent.EventType = .mouseEntered
    weak var target: NSWindow?
    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { point }
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { target }
}

@MainActor func checkHeaderHoverExit(_ header: NSView) {
    let bounds = NSRect(x: 0, y: 0, width: 180, height: 28)
    let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    header.frame = bounds
    window.contentView!.addSubview(header)
    defer { header.removeFromSuperview() }
    header.layoutSubtreeIfNeeded()
    let event = HeaderTrackingEvent()
    event.target = window
    event.area = header.trackingAreas.first { $0.owner === header && $0.options.contains(.mouseMoved) }
    precondition(event.area != nil, "SwiftUI's header tracking area must be installed")
    func fill(at x: CGFloat) -> CGFloat {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.16))
        let image = header.bitmapImageRepForCachingDisplay(in: bounds)!
        header.cacheDisplay(in: bounds, to: image)
        return image.colorAt(x: Int(x * CGFloat(image.pixelsWide) / bounds.width), y: image.pixelsHigh / 2)!.alphaComponent
    }
    // Sample the fill inside each button, clear of the sidebar and reload glyphs.
    for left in [CGFloat.zero, bounds.width - 24] {
        let resting = fill(at: left + 3)
        event.point = NSPoint(x: left + 12, y: bounds.midY)
        event.kind = .mouseEntered
        header.mouseEntered(with: event)
        precondition(fill(at: left + 3) > resting + 0.02, "Pointer entry must highlight the toolbar button")
        event.point = NSPoint(x: left + 12, y: -8)
        event.kind = .mouseExited
        header.mouseExited(with: event)
        precondition(abs(fill(at: left + 3) - resting) < 0.01, "Leaving the header must clear the toolbar highlight")
    }
}

@MainActor func checkFeedback() throws {
    checkDisabledArrowAppearance()
    let sink = FeedbackSink()
    let context = Unmanaged.passUnretained(sink).toOpaque()
    let model = ChromiumSidebarModel(context: context) { pointer, json in
        guard let pointer, let json,
              let message = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any] else { return }
        Unmanaged<FeedbackSink>.fromOpaque(pointer).takeUnretainedValue().messages.append(message)
    }
    let snapshot = #"{"tabs":[{"id":7,"title":"Docs [today]","url":"https://example.test/docs?lang=en#copy","active":true,"pinned":false,"loading":false}],"spaces":[],"profile":"/temporary/bark-feedback","canGoBack":false,"canGoForward":false,"notices":[{"id":"n1","tabId":7,"url":"https://example.test/docs?lang=en#copy","message":"Review this notice","critical":false,"closeable":false,"actions":[{"id":"accept","title":"Continue","enabled":true},{"id":"extra","title":"Unavailable","enabled":false}]}]}"#
    model.update(snapshot)
    checkCopyLinkToast(model)
    let notice = model.activeNotices[0]
    model.performNoticeAction("accept", notice: notice)
    precondition(sink.messages.last?["action"] as? String == "noticeAction" &&
                 (sink.messages.last?["metadata"] as? [String: String])?["notice"] == "n1",
                 "Notice actions carry the exact notice and page context")
    let count = sink.messages.count
    model.performNoticeAction("dismiss", notice: notice)
    model.performNoticeAction("extra", notice: notice)
    model.performNoticeAction("invalid", notice: notice)
    precondition(sink.messages.count == count, "Non-closeable notices and disabled or unknown actions cannot be invoked")
    for changed in [snapshot.replacingOccurrences(of: "n1", with: "n2"),
                    snapshot.replacingOccurrences(of: "example.test/", with: "example.test/new"),
                    snapshot.replacingOccurrences(of: "\"id\":7", with: "\"id\":8")] {
        model.update(changed)
        model.performNoticeAction("accept", notice: notice)
        precondition(sink.messages.count == count, "Replaced notices, navigation, and tab changes reject stale actions")
    }
    model.shutdown()
    checkSpaceHeaderActions()
}

@MainActor private func checkCopyLinkToast(_ model: ChromiumSidebarModel) {
    let window = NSWindow(contentRect: NSRect(x: 35, y: 45, width: 820, height: 590),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    let viewport = PageFrameHostingView(model: model)
    viewport.frame = window.contentView!.bounds
    window.contentView!.addSubview(viewport)
    viewport.geometry.update(#"{"bounds":{"x":0,"y":0,"width":820,"height":590},"panes":[{"x":200,"y":60,"width":570,"height":490}]}"#)
    model.hostView = viewport
    window.orderBack(nil)
    let board = NSPasteboard.withUniqueName()
    barkSwiftUseCopyPasteboardForTesting(board.name.rawValue)
    defer {
        barkSwiftUseCopyPasteboardForTesting(NSPasteboard.general.name.rawValue)
        board.releaseGlobally()
        model.hostView = nil
        window.orderOut(nil)
    }

    guard let tab = model.activeTab else { preconditionFailure("The browser fixture needs an active tab") }
    let responder = window.firstResponder
    model.perform(.copyURL)
    precondition(board.string(forType: .string) == tab.url, "Copy must preserve the complete URL, including its query and fragment")
    func toasts() -> [NSWindow] {
        (window.childWindows ?? []).filter { $0.identifier?.rawValue == "BarkCopyLinkToast" && $0.isVisible }
    }
    guard let toast = toasts().first, let page = PageFrameHostingView.pageRect(in: window) else {
        preconditionFailure("Copying a link must display a confirmation in the browser window")
    }
    precondition(page.contains(toast.frame) && toast.frame.width > 64 && toast.frame.height > 20 &&
                 (0...30).contains(page.maxX - toast.frame.maxX) && (0...30).contains(page.maxY - toast.frame.maxY),
                 "The confirmation must fit inside the upper-right corner of the actual page viewport")
    precondition(toast.ignoresMouseEvents && !toast.isKeyWindow && window.firstResponder === responder,
                 "The confirmation must leave the page's keyboard and pointer input available")

    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    model.perform(.copyMarkdown)
    precondition(board.string(forType: .string) == #"[Docs \[today\]](https://example.test/docs?lang=en#copy)"#)
    RunLoop.main.run(until: Date().addingTimeInterval(1.3))
    let renewed = toasts()
    precondition(renewed.count == 1 && (renewed.first?.alphaValue ?? 0) > 0.9,
                 "A repeated copy must renew the confirmation without stacking two toasts")
    RunLoop.main.run(until: Date().addingTimeInterval(1.3))
    precondition(toasts().isEmpty, "The confirmation must disappear automatically")
}

@MainActor private func checkSpaceHeaderActions() {
    // Request SwiftUI's accessibility tree for this test process's unshown window.
    guard NSApp.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) else { return }
    let key = "accessibilityEnhancedUserInterface"
    let previous = NSApp.value(forKey: key)
    NSApp.setValue(true, forKey: key)
    defer { NSApp.setValue(previous, forKey: key) }

    for collapsed in [false, true] {
        var actions = [String]()
        let row = SpaceHeaderRow(name: "School", emoji: "", tint: .blue, pinsCollapsed: collapsed,
                                 togglePins: { actions.append("toggle") }, openSettings: { actions.append("settings") })
        let host = NSHostingView(rootView: row)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 36), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var nodes = host.accessibilityChildren() ?? []
        var buttons: [String: AnyObject] = [:]
        while let item = nodes.popLast() {
            let node = item as AnyObject
            if node.accessibilityRole?() == .button, let label = node.accessibilityLabel?() {
                buttons[label] = node
            }
            nodes += node.accessibilityChildren?() ?? []
        }
        let value = (buttons["School"] as? NSObject)?.value(forKey: "accessibilityValue") as? String
        precondition(value == (collapsed ? "Collapsed" : "Expanded"))
        precondition(buttons["School"]?.accessibilityPerformPress?() == true && actions == ["toggle"])
        precondition(buttons["Space settings"]?.accessibilityPerformPress?() == true && actions == ["toggle", "settings"])
    }
}

@MainActor private func checkDisabledArrowAppearance() {
    for scheme in [ColorScheme.light, .dark] {
        func contrast(disabled: Bool) -> CGFloat {
            let arrow = Button {} label: { Image(systemName: "chevron.left").frame(width: 24, height: 28) }
                .buttonStyle(BarkControlStyle()).disabled(disabled).foregroundStyle(.secondary)
                .background(scheme == .light ? Color.white : Color.black).environment(\.colorScheme, scheme)
            let bitmap = NSBitmapImageRep(cgImage: ImageRenderer(content: arrow).cgImage!)
            var total: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    let white = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.genericGray)!.whiteComponent
                    total += scheme == .light ? 1 - white : white
                }
            }
            return total
        }
        let disabled = contrast(disabled: true)
        precondition(disabled > 0 && disabled < 0.7 * contrast(disabled: false),
                     "An unavailable navigation arrow must remain visible and distinctly dimmer")
    }
}
