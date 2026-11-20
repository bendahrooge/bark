import AppKit
import SwiftUI

/// Clip the outgoing rows to their shrinking space while the rows below move up.
struct SidebarFoldingRows<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                content().transition(.offset(y: -5).combined(with: .opacity))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).clipped()
    }
}

/// Shared restrained treatment for sidebar, popover, and media controls.
struct BarkControlStyle: ButtonStyle {
    var cornerRadius: CGFloat = 7
    var restingOpacity: Double = 0
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let highlight = isEnabled && (configuration.isPressed || hovered)
        configuration.label
            .opacity(isEnabled ? 1 : 0.38)
            .background(Color.primary.opacity(highlight ? (configuration.isPressed ? 0.12 : 0.065) : restingOpacity),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

struct SpaceHeaderRow: View {
    let name: String
    let emoji: String
    let tint: Color
    let pinsCollapsed: Bool
    let togglePins: () -> Void
    let openSettings: () -> Void

    private enum Control: Hashable { case disclosure, settings }
    @State private var hovered = false
    @FocusState private var focused: Control?
    @AccessibilityFocusState private var accessibilityFocused: Control?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var showControls: Bool { hovered || focused != nil || accessibilityFocused != nil }
    private var showChevron: Bool { pinsCollapsed || showControls }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: togglePins) {
                HStack(spacing: 8) {
                    ZStack {
                        SpaceIcon(emoji: emoji, tint: tint).font(.system(size: 14))
                            .opacity(showChevron ? 0 : 1)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(pinsCollapsed ? 0 : 90))
                            .opacity(showChevron ? 1 : 0)
                    }.fixedSize().frame(minWidth: 16).accessibilityHidden(true)
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.leading, 10).frame(height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .disclosure).accessibilityFocused($accessibilityFocused, equals: .disclosure)
            .accessibilityLabel(Text(name)).accessibilityValue(pinsCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(pinsCollapsed ? "Expand pinned tabs" : "Collapse pinned tabs")
            .help(pinsCollapsed ? "Expand pinned tabs" : "Collapse pinned tabs")

            Button(action: openSettings) {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .opacity(showControls ? 1 : 0)
                    .frame(width: 32, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused, equals: .settings).accessibilityFocused($accessibilityFocused, equals: .settings)
            .help("Space settings").accessibilityLabel("Space settings")
        }
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(showControls ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showControls)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pinsCollapsed)
    }
}

struct ChromiumNotice: Decodable, Identifiable, Equatable {
    struct Action: Decodable, Identifiable, Equatable {
        let id: String
        let title: String
        let enabled: Bool
    }
    let id: String
    let tabId: Int
    let url: String
    let message: String
    let critical: Bool
    let closeable: Bool
    let actions: [Action]
}

@MainActor extension ChromiumSidebarModel {
    var activeNotices: [ChromiumNotice] {
        (snapshot.notices ?? []).filter { $0.tabId == activeTab?.id && $0.url == activeTab?.url }
    }
    func performNoticeAction(_ action: String, notice: ChromiumNotice) {
        guard let current = activeNotices.first(where: { $0.id == notice.id }),
              current == notice,
              action == "dismiss" ? current.closeable : current.actions.contains(where: { $0.id == action && $0.enabled }) else { return }
        send("noticeAction", id: current.tabId, text: action, metadata: ["url": current.url, "notice": current.id])
    }
}

/// Notices stay available until Chromium expires them or the person acts.
/// The compact summary never occupies or shifts the webpage's layout.
struct BrowserNoticeSummary: View {
    @ObservedObject var model: ChromiumSidebarModel
    @State private var announced = Set<String>()
    private var notices: [ChromiumNotice] { model.activeNotices }
    private var critical: Bool { notices.contains(where: \.critical) }
    var body: some View {
        if let first = notices.first {
            Button { model.noticesOpen = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: critical ? "exclamationmark.shield" : "bell")
                        .foregroundStyle(critical ? Color.orange : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notices.count == 1 ? "Site notice" : "\(notices.count) site notices")
                            .font(.system(size: 12, weight: .medium))
                        Text(first.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }.padding(10).contentShape(Rectangle())
            }.buttonStyle(BarkControlStyle(cornerRadius: 10, restingOpacity: 0.035))
                .help("Review site notices")
                .accessibilityLabel("Review site notices. " + first.message)
                .popover(isPresented: $model.noticesOpen, arrowEdge: .trailing) {
                    BrowserNoticesView(model: model)
                }
                .onAppear { announceNewNotices() }
                .onChange(of: notices) { _ in
                    if notices.isEmpty { model.noticesOpen = false }
                    announceNewNotices()
                }
                .onChange(of: model.activeTab?.id) { _ in model.noticesOpen = false }
                .onChange(of: model.activeTab?.url) { _ in model.noticesOpen = false }
                .onDisappear { model.noticesOpen = false }
        }
    }
    private func announceNewNotices() {
        for notice in notices where announced.insert(notice.id).inserted {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: "Site notice: " + notice.message,
                           .priority: notice.critical ? NSAccessibilityPriorityLevel.high.rawValue : NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}

private struct BrowserNoticesView: View {
    @ObservedObject var model: ChromiumSidebarModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Site notices").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.noticesOpen = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(BarkControlStyle()).help("Close notices").accessibilityLabel("Close notices")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.activeNotices) { notice in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(notice.message).font(.system(size: 13)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(notice.actions) { action in
                                Button(action.title) { model.performNoticeAction(action.id, notice: notice) }
                                    .buttonStyle(.bordered).disabled(!action.enabled)
                            }
                            if notice.closeable {
                                Button("Dismiss") { model.performNoticeAction("dismiss", notice: notice) }
                                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }.frame(maxHeight: 360)
        }.padding(16).frame(width: 320)
            .background(model.theme.accent.opacity(0.04))
            .accessibilityElement(children: .contain).accessibilityLabel("Site notices")
    }
}
