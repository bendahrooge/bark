import AppKit
import QuartzCore

@MainActor func checkPeekShortcuts() {
    checkPeekLayout()
    checkPeekEntranceMotion()
    func command(_ characters: String?, _ code: UInt16, _ flags: NSEvent.ModifierFlags,
                 kind: String = "peek", canSplit: Bool = true) -> String? {
        PopupChrome.command(characters: characters, keyCode: code, modifiers: flags, kind: kind, canSplit: canSplit)
    }
    precondition(command("o", 31, .command) == "expand" && command("o", 31, .command, kind: "little") == "expand",
                 "Peek and Little windows share the same expand shortcut")
    for kind in ["peek", "little"] {
        precondition(command("C", 8, [.command, .shift], kind: kind) == "copyURL" &&
                     command("c", 8, .command, kind: kind) == nil,
                     "Copy Page URL must work in both popup types while ordinary Copy stays with the page")
    }
    precondition(command(nil, 24, [.control, .shift, .numericPad]) == "split",
                 "Peek uses the existing split shortcut and ignores unrelated modifier flags")
    precondition(command(nil, 24, [.control, .shift], canSplit: false) == nil &&
                 command(nil, 24, [.control, .shift], kind: "little") == nil,
                 "Unavailable splits and Little windows do not consume split shortcuts")
    precondition(command(nil, 53, []) == "close" && command(nil, 53, [], kind: "little") == nil,
                 "Escape dismisses Peek only")
    precondition(command("o", 31, [.command, .shift]) == nil && command("o", 31, []) == nil &&
                 command(nil, 53, .command) == nil,
                 "Ordinary page keys and other command combinations stay with Chromium")
}

private func checkPeekEntranceMotion() {
    let destination = NSRect(x: 240, y: 60, width: 700, height: 510)
    let start = PeekEntrance(elapsed: 0).pageFrame(destination)
    precondition(start.width < destination.width && start.height < destination.height &&
                 start.midY < destination.midY, "The preview enters from a smaller, lower frame")
    for hz in [60, 120] {
        let count = Int(ceil(PeekEntrance.duration * Double(hz)))
        let frames = (0...count).map { PeekEntrance(elapsed: Double($0) / Double(hz)).pageFrame(destination) }
        guard let widest = frames.max(by: { $0.width < $1.width }) else { preconditionFailure() }
        precondition(widest.width > destination.width + 1 && widest.height > destination.height &&
                     widest.width < destination.width * 1.1, "The opening preview travels past its final dimensions and springs back")
        precondition(frames.last == destination && PeekEntrance(elapsed: PeekEntrance.duration).pageFrame(destination) == destination,
                     "The entrance ends exactly on its layout at both display rates")
    }
}

private func checkPeekLayout() {
    let ordinary = NSRect(x: 240, y: 60, width: 900, height: 660)
    let offset = ordinary.offsetBy(dx: -1440, dy: -180)
    let narrow = NSRect(x: 260, y: 30, width: 320, height: 650)
    let small = NSRect(x: 25, y: 40, width: 210, height: 144)
    for viewport in [ordinary, offset, narrow, small] {
        let layout = PeekLayout(viewport: viewport)
        precondition(viewport.contains(layout.page) && viewport.contains(layout.controls),
                     "The preview and all three controls fit inside the web page viewport")
        precondition(layout.page.height >= viewport.height * 0.9 && layout.page.width >= viewport.width * 0.7,
                     "The preview fills most of the available space")
        let gap = layout.controls.minX - layout.page.maxX
        precondition(gap > 0 && gap < PeekLayout.buttonSize && layout.controls.maxY <= layout.page.maxY,
                     "The controls sit within reach beside the preview's upper-right edge")
        precondition(layout.controls.width == PeekLayout.buttonSize &&
                     layout.controls.height >= 3 * PeekLayout.buttonSize + 2 * PeekLayout.buttonSpacing)
    }
    let source = PeekLayout(viewport: ordinary)
    let shifted = PeekLayout(viewport: offset)
    precondition(abs(source.page.midX - ordinary.midX) <= 1 &&
                 abs(source.page.width - ordinary.width * 0.81) <= 1,
                 "On a regular window the page sits centered inside the web viewport")
    for (original, moved) in [(source.page, shifted.page), (source.controls, shifted.controls)] {
        precondition(original.size == moved.size && abs((moved.minX - original.minX) + 1440) <= 1 &&
                     abs((moved.minY - original.minY) + 180) <= 1,
                     "A secondary display's origin offsets the preview and controls to within a point of rounding")
    }
}

@MainActor private final class PromotionRecorder {
    let window: NSWindow
    var commands: [String] = []
    var frameAtCallback: NSRect?

    init(window: NSWindow) { self.window = window }
}

@MainActor func checkPeekPromotion() {
    enum Scenario { case settled, reduced, earlyExpand, earlyClose }
    for scenario in [Scenario.settled, .reduced, .earlyExpand, .earlyClose] {
        let reduced = scenario == .reduced
        let owner = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 850, height: 560),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let popup = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 480, height: 360),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        popup.isReleasedWhenClosed = false
        owner.alphaValue = 0
        popup.alphaValue = 0
        let viewport = NSView(frame: NSRect(x: 200, y: 14, width: 630, height: 530))
        owner.contentView!.addSubview(viewport)
        owner.orderBack(nil)
        popup.orderBack(nil)
        let recorder = PromotionRecorder(window: popup)
        let chrome = PopupChrome(window: popup, owner: owner, viewport: viewport, kind: "peek", space: "Testing",
                                 emoji: "", canSplit: true, context: Unmanaged.passUnretained(recorder).toOpaque(),
                                 callback: { pointer, message in
            guard let pointer, let message else { return }
            MainActor.assumeIsolated {
                let recorder = Unmanaged<PromotionRecorder>.fromOpaque(pointer).takeUnretainedValue()
                recorder.commands.append(String(cString: message))
                recorder.frameAtCallback = recorder.window.frame
            }
        }, waitForFirstPaint: true, reduceMotion: { reduced })
        defer { popup.orderOut(nil); owner.orderOut(nil) }

        let finalFrame = owner.convertToScreen(viewport.convert(viewport.bounds, to: nil))
        let restingFrame = PeekLayout(viewport: finalFrame).page
        func entranceSurface() -> NSView? {
            owner.contentView?.subviews.first { $0.identifier?.rawValue == "BarkPeekEntranceSurface" }
        }
        func samples(_ layer: CALayer, keyPath: String) -> [Any]? {
            func find(_ animation: CAAnimation) -> [Any]? {
                if let keyframes = animation as? CAKeyframeAnimation, keyframes.keyPath == keyPath { return keyframes.values }
                return (animation as? CAAnimationGroup)?.animations?.compactMap(find).first
            }
            return (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }.compactMap(find).first
        }
        precondition(popup.frame == restingFrame, "Chromium lays out at the final viewport size before revealing the page")
        guard let openingFrame = chrome.presentedPageFrame else { preconditionFailure("Peek exposes the visible page frame") }
        if reduced {
            precondition(openingFrame == restingFrame && popup.contentView?.alphaValue == 1 && entranceSurface() == nil,
                         "Reduce Motion shows the settled preview immediately without an entrance surface")
        } else {
            precondition(openingFrame.width < restingFrame.width && openingFrame.height < restingFrame.height,
                         "The attached preview prepares a smaller visual size without resizing Chromium")
        }
        if scenario == .settled {
            RunLoop.main.run(until: Date().addingTimeInterval(PeekEntrance.duration + 0.1))
            precondition(chrome.presentedPageFrame == openingFrame && popup.contentView?.alphaValue == 0,
                         "A delayed first paint holds the initial visual frame without showing an empty document")
            chrome.beginEntrance()
            guard let surface = entranceSurface(),
                  let card = surface.layer?.sublayers?.first(where: { $0.name == "BarkPeekCard" }) else {
                preconditionFailure("The owner renders a backing card while Chromium presents its first frames")
            }
            precondition(surface.hitTest(.zero) == nil && card.backgroundColor?.alpha == 1 && card.cornerRadius > 0)
            for layer in [card, popup.contentView?.layer] {
                guard let layer, let transforms = samples(layer, keyPath: "transform") as? [NSValue],
                      let alphas = samples(layer, keyPath: "opacity") as? [NSNumber] else {
                    preconditionFailure("Both the live Chromium content and the owner card animate on the render server")
                }
                let frames = zip(transforms.map { $0.caTransform3DValue.m11 }, alphas.map { CGFloat($0.doubleValue) })
                precondition(transforms.count == alphas.count && frames.contains { $0 < 0.98 && $1 > 0.2 } &&
                             frames.contains { $0 > 1 && $1 > 0.8 },
                             "Both layers become visible while the sheet is still inset and remain visible through the overshoot")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let currentWidth = chrome.presentedPageFrame!.width
            chrome.beginEntrance()
            precondition(abs(chrome.presentedPageFrame!.width - currentWidth) < 3,
                         "A repeated paint signal cannot restart the entrance")
            RunLoop.main.run(until: Date().addingTimeInterval(PeekEntrance.duration + 0.25))
            precondition(popup.frame == restingFrame && chrome.presentedPageFrame == restingFrame &&
                         popup.contentView?.alphaValue == 1 && entranceSurface() === surface && recorder.commands.isEmpty,
                         "The backing card remains at the settled geometry until Chromium makes its window visible")
            popup.alphaValue = 1
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: popup)
            precondition(entranceSurface() == nil, "The first visible Chromium window releases its temporary card")
        }
        if scenario == .earlyClose || scenario == .earlyExpand {
            chrome.beginEntrance()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        let interruptedFrame = chrome.presentedPageFrame!
        if scenario == .earlyClose {
            chrome.performControl("close")
            precondition(recorder.commands == ["close"], "Dismissing an opening preview fires immediately")
            chrome.detach()
            RunLoop.main.run(until: Date().addingTimeInterval(PeekEntrance.duration + 0.1))
            precondition(entranceSurface() == nil && recorder.commands == ["close"],
                         "Detached previews leave no backing card or queued entrance actions")
            continue
        }
        for _ in 0..<3 { chrome.performControl("expand") }
        if scenario == .earlyExpand {
            precondition(abs(popup.frame.width - interruptedFrame.width) < 3 && entranceSurface() == nil,
                         "Early expansion takes over at the current visible size and removes the backing card")
        }
        if reduced {
            precondition(recorder.commands == ["expand"], "Reduce Motion promotes the page immediately and exactly once")
        } else {
            precondition(recorder.commands.isEmpty, "The active preview stays live until its expansion completes")
        }
        let deadline = Date().addingTimeInterval(2)
        while recorder.commands.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(recorder.commands == ["expand"], "Rapid presses on + promote the live page once")
        if !reduced {
            precondition(recorder.frameAtCallback == finalFrame, "The handoff occurs at the opener's full viewport frame")
        }
        let image = NSImage(size: NSSize(width: 12, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let handle = withExtendedLifetime(image) {
            barkSwiftPopupCover(Unmanaged.passUnretained(chrome).toOpaque(), Unmanaged.passUnretained(image).toOpaque())
        }
        guard let handle else { preconditionFailure("A rendered page snapshot creates the handoff cover") }
        let cover = Unmanaged<NSPanel>.fromOpaque(handle).takeUnretainedValue()
        precondition(cover.parent === owner && cover.frame == finalFrame && cover.isVisible &&
                     cover.ignoresMouseEvents && !cover.canBecomeKey && !cover.canBecomeMain,
                     "The full-viewport cover passes clicks and keyboard focus to the promoted page")
        chrome.detach()
        precondition(cover.isVisible && cover.parent === owner, "The owner retains the cover while the popup detaches")
        barkSwiftPopupRemoveCover(handle)
        precondition(!cover.isVisible && cover.parent == nil, "Native presentation completion explicitly removes the cover")
    }
}
