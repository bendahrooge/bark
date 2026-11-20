import AppKit
import SwiftUI

private struct WindowSpaceBackground: View {
    @ObservedObject var model: ChromiumSidebarModel
    var canvasSize: CGSize? = nil

    var body: some View {
        ZStack {
            SidebarBackground(theme: model.outgoingTheme,
                              style: model.isIncognito ? SpaceStyle() : model.outgoingSpace?.style ?? SpaceStyle(),
                              canvasSize: canvasSize)
            ForEach([CGFloat(-1), 1], id: \.self) { direction in
                ZStack {
                    if let neighbor = model.swipePage(in: direction) {
                        SidebarBackground(theme: neighbor.themeValue, style: neighbor.style, canvasSize: canvasSize)
                            .transition(.identity)
                    }
                }.opacity(min(1, max(0, direction * model.spaceSwipeOffset / max(1, model.snapshot.sidebarWidth ?? 260))))
            }
        }
    }
}

/// The hover panel has one rounded backdrop for the caption and sidebar.
struct SidebarBackdropView: View {
    @ObservedObject var model: ChromiumSidebarModel
    var canvasSize: CGSize? = nil
    @Environment(\.colorScheme) private var scheme

    // Matches the native host's extra room for the floating panel's shadow.
    static let shadowMargin: CGFloat = 24

    var body: some View {
        WindowSpaceBackground(model: model, canvasSize: canvasSize)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.26) : Color.black.opacity(0.18), lineWidth: 0.5)
                    .padding(0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.24), radius: 10, x: 4, y: 3)
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            .padding(Self.shadowMargin)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor final class SidebarBackdropHostingView: NSHostingView<SidebarBackdropView> {
    init(model: ChromiumSidebarModel) {
        super.init(rootView: SidebarBackdropView(model: model))
        sizingOptions = []
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init(rootView: SidebarBackdropView) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setCanvasSize(_ size: CGSize) {
        if rootView.canvasSize != size { rootView.canvasSize = size }
    }
}

@_cdecl("BarkSwiftSidebarBackdropSetCanvasSize")
@MainActor func barkSwiftSidebarBackdropSetCanvasSize(_ handle: UnsafeMutableRawPointer, _ width: Double, _ height: Double) {
    Unmanaged<SidebarBackdropHostingView>.fromOpaque(handle).takeUnretainedValue()
        .setCanvasSize(CGSize(width: width, height: height))
}

@_cdecl("BarkSwiftSidebarBackdropDestroy")
@MainActor func barkSwiftSidebarBackdropDestroy(_ handle: UnsafeMutableRawPointer) {
    _ = Unmanaged<SidebarBackdropHostingView>.fromOpaque(handle).takeRetainedValue()
}

/// Geometry comes from Chromium after layout, including both split panes and
/// docked DevTools. The frame paints only space reserved by that layout.
@MainActor final class PageFrameGeometry: ObservableObject {
    struct Rect: Decodable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    struct State: Decodable, Equatable {
        let bounds: Rect
        let panes: [Rect]
        var contentBounds: CGRect? { panes.map(\.cgRect).reduce(nil) { $0?.union($1) ?? $1 } }
    }
    @Published var state: State?

    func update(_ json: String) {
        guard let data = json.data(using: .utf8),
              let next = try? JSONDecoder().decode(State.self, from: data), next != state else { return }
        state = next
    }
}

/// One window-wide surface joins the docked sidebar and page frame without
/// restarting the gradient at their boundary. The even-odd cutouts leave web
/// surfaces transparent; Chromium's native WebView clips the page corners.
private struct PageFrameMask: Shape {
    let state: PageFrameGeometry.State
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        for pane in state.panes {
            path.addRoundedRect(in: pane.cgRect, cornerSize: CGSize(width: 10, height: 10))
        }
        return path
    }
}

struct PageFrameView: View {
    @ObservedObject var model: ChromiumSidebarModel
    @ObservedObject var geometry: PageFrameGeometry
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let state = geometry.state {
            ZStack(alignment: .topLeading) {
                WindowSpaceBackground(model: model)
                ForEach(Array(state.panes.enumerated()), id: \.offset) { _, pane in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(scheme == .dark ? 0.22 : 0.12))
                        .frame(width: pane.width, height: pane.height)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.12), radius: 3, y: 1)
                        .position(x: pane.x + pane.width / 2, y: pane.y + pane.height / 2)
                }
            }
            .mask(PageFrameMask(state: state).fill(style: FillStyle(eoFill: true)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

@MainActor final class PageFrameHostingView: NSHostingView<PageFrameView> {
    let geometry = PageFrameGeometry()
    init(model: ChromiumSidebarModel) {
        super.init(rootView: PageFrameView(model: model, geometry: geometry))
        sizingOptions = []
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init(rootView: PageFrameView) { fatalError() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func pageRect(in window: NSWindow) -> NSRect? {
        func find(_ view: NSView) -> PageFrameHostingView? {
            if let frame = view as? PageFrameHostingView { return frame }
            for child in view.subviews { if let frame = find(child) { return frame } }
            return nil
        }
        guard let frame = window.contentView.flatMap(find), !frame.isHidden,
              let bounds = frame.geometry.state?.contentBounds else { return nil }
        return window.convertToScreen(frame.convert(bounds, to: nil))
    }
}

@_cdecl("BarkSwiftPageFrameUpdate")
@MainActor func barkSwiftPageFrameUpdate(_ handle: UnsafeMutableRawPointer, _ json: UnsafePointer<CChar>) {
    Unmanaged<PageFrameHostingView>.fromOpaque(handle).takeUnretainedValue().geometry.update(String(cString: json))
}

@_cdecl("BarkSwiftPageFrameDestroy")
@MainActor func barkSwiftPageFrameDestroy(_ handle: UnsafeMutableRawPointer) {
    _ = Unmanaged<PageFrameHostingView>.fromOpaque(handle).takeRetainedValue()
}
