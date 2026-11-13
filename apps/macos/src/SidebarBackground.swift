import AppKit
import SwiftUI
import BarkCore

struct SidebarBackground: View {
    let theme: SpaceTheme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                theme.sidebar(scheme)
            } else {
                SidebarVisualEffect()
                    .overlay(theme.sidebar(scheme).opacity(scheme == .dark ? 0.48 : 0.42))
            }
        }
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
