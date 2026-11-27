import AppKit
import QuartzCore
import SwiftUI

/// How the pager travels to a new offset. Core Animation runs these in the
/// render server, so a busy main thread (Chromium activating the new Space's
/// tab) cannot drop their frames.
enum SpacePagerMotion {
    /// A dock click or shortcut: no finger velocity to continue.
    case curve(x1: Float, y1: Float, x2: Float, y2: Float, duration: TimeInterval)
    /// A released swipe. `initialVelocity` is in remaining distances per second.
    case spring(rate: CGFloat, initialVelocity: CGFloat, duration: TimeInterval)
}

/// The fraction of a neighboring Space's backdrop that shows through. Kept
/// apart from the sidebar model so that finger movement redraws only the
/// backdrops, not every row that observes the model.
@MainActor final class SpaceSwipeFade: ObservableObject {
    @Published var offset: CGFloat = 0
}

/// Moves the pager's pages on behalf of the sidebar model.
@MainActor final class SpacePagerDriver {
    fileprivate weak var view: SpacePagerView? {
        didSet { if view !== oldValue { view?.move(to: offset, motion: nil) } }
    }
    private var offset: CGFloat = 0
    private var pending: [(offset: CGFloat, motion: SpacePagerMotion?)]?
    private var batch = 0

    /// Moves the pages now: finger tracking, or a release that continues it.
    func move(to offset: CGFloat, motion: SpacePagerMotion? = nil) {
        if pending != nil {
            // Keep the order of moves that follow a content change.
            pending?.append((offset, motion))
            return
        }
        apply(offset, motion)
    }

    /// Moves the pages in the same update that changes what they show. A reset
    /// swaps the outgoing and incoming rows as it rebases the offset; applying
    /// either one a frame early would flash the wrong Space.
    func moveWithContent(to offset: CGFloat, motion: SpacePagerMotion? = nil) {
        if pending == nil {
            pending = []
            batch += 1
            let batch = batch
            // The sidebar may be detached or hidden and never update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.batch == batch else { return }
                self.contentUpdated()
            }
        }
        pending?.append((offset, motion))
    }

    fileprivate func contentUpdated() {
        guard let moves = pending else { return }
        pending = nil
        for move in moves { apply(move.offset, move.motion) }
    }

    private func apply(_ offset: CGFloat, _ motion: SpacePagerMotion?) {
        self.offset = offset
        view?.move(to: offset, motion: motion)
    }
}

/// Pages side by side: the active Space and the neighbor on each side.
/// Scrolling the bounds origin moves them together, as a clip view does.
/// A page belongs to its Space for as long as it is shown, so the neighbor a
/// slide lands on is moved into the active slot rather than built again.
final class SpacePagerView: NSView {
    private static let animationKey = "BarkSpacePager"
    private var pages: [String: (host: NSHostingView<AnyView>, slot: Int)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if #available(macOS 14.0, *) { clipsToBounds = true }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.masksToBounds = true
        return layer
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        placePages()
    }
    override func layout() {
        super.layout()
        placePages()
    }
    private func placePages() {
        let size = frame.size
        for (host, slot) in pages.values {
            let frame = NSRect(x: CGFloat(slot) * size.width, y: 0, width: size.width, height: size.height)
            if host.frame != frame { host.frame = frame }
        }
    }

    fileprivate func show(_ shown: [SpacePager.Page]) {
        var kept: Set<String> = []
        for page in shown where kept.insert(page.id).inserted {
            if let existing = pages[page.id] {
                existing.host.rootView = page.content
                pages[page.id]?.slot = page.slot
            } else {
                let host = NSHostingView(rootView: page.content)
                // The pager sets each page's frame; its content must never resize it.
                host.sizingOptions = []
                if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
                addSubview(host)
                pages[page.id] = (host, page.slot)
            }
        }
        for (id, page) in pages where !kept.contains(id) {
            page.host.removeFromSuperview()
            pages[id] = nil
        }
        placePages()
    }

    /// Where the pages are on screen, including partway through an animation.
    private var displayedOffset: CGFloat {
        if let layer, layer.animation(forKey: Self.animationKey) != nil, let shown = layer.presentation() {
            return -shown.bounds.origin.x
        }
        return -bounds.origin.x
    }

    fileprivate func move(to offset: CGFloat, motion: SpacePagerMotion?) {
        let from = displayedOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: Self.animationKey)
        setBoundsOrigin(NSPoint(x: -offset, y: 0))
        CATransaction.commit()
        guard let motion, let layer, window != nil, abs(from - offset) > 0.01 else { return }
        let animation: CABasicAnimation
        switch motion {
        case let .curve(x1, y1, x2, y2, duration):
            animation = CABasicAnimation(keyPath: "bounds.origin")
            animation.timingFunction = CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
            animation.duration = duration
        case let .spring(rate, initialVelocity, duration):
            let spring = CASpringAnimation(keyPath: "bounds.origin")
            spring.mass = 1
            spring.stiffness = rate * rate
            spring.damping = 2 * rate
            spring.initialVelocity = initialVelocity
            spring.duration = duration
            animation = spring
        }
        animation.fromValue = NSValue(point: NSPoint(x: -from, y: 0))
        animation.toValue = NSValue(point: NSPoint(x: -offset, y: 0))
        layer.add(animation, forKey: Self.animationKey)
    }
}

/// Hosts the sidebar's Space pages in AppKit so their slide is a layer
/// animation. Each page is its own SwiftUI host: preferences and named
/// coordinate spaces do not cross into the enclosing sidebar.
struct SpacePager: NSViewRepresentable {
    struct Page {
        /// The Space shown; its host is kept while this stays on a page.
        let id: String
        /// -1 to the left of the active page, 0 for it, 1 to its right.
        let slot: Int
        let content: AnyView
    }
    let driver: SpacePagerDriver
    let pages: [Page]

    func makeNSView(context: Context) -> SpacePagerView {
        let view = SpacePagerView(frame: .zero)
        driver.view = view
        return view
    }

    func updateNSView(_ view: SpacePagerView, context: Context) {
        if driver.view !== view { driver.view = view }
        view.show(pages)
        driver.contentUpdated()
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpacePagerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
