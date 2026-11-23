import AppKit
import Combine
import SwiftUI
import BarkCore

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
