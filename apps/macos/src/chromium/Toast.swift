import AppKit
import Combine
import SwiftUI
import BarkCore

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
