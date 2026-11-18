import AppKit
import SwiftUI
import BarkCore

struct SidebarBackground: View {
    let theme: SpaceTheme
    var style = SpaceStyle()
    var canvasSize: CGSize? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color.clear
            } else {
                SidebarVisualEffect()
            }
        }
        .overlay(alignment: .topLeading) {
            // The floating panel shows the same slice as the attached sidebar.
            SpaceThemeSurface(theme: theme, style: style)
                .frame(width: canvasSize?.width, height: canvasSize?.height)
                .opacity(reduceTransparency ? 1 : 0.90)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarVisualEffect: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> BackgroundEffectView {
        let view = BackgroundEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: BackgroundEffectView, context: Context) {
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    final class BackgroundEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
