import AppKit
import Combine
import SwiftUI

/// The 20-20-20 reminder: every 20 minutes, look about 20 feet away for 20 seconds.
/// Off by default. The setting is app-wide and lives in the same defaults as Peek.
@MainActor final class EyeRestReminder {
    static let shared = EyeRestReminder()
    static let defaultsKey = "BarkChromium.EyeRestReminder"
    static let interval: TimeInterval = 20 * 60
    static let restSeconds = 20

    private var timer: Timer?
    private var started = false
    /// The interval ended while Bark was in the background; remind on return.
    private var pending = false
    private var observers: [NSObjectProtocol] = []
    private var panel: NSPanel?
    private var countdown: Timer?
    private let state = EyeRestState()

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.defaultsKey) }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        restart()
    }

    /// Safe to call for every window; only the first call installs observers.
    func start() {
        guard !started else { return }
        started = true
        let app = NotificationCenter.default
        observers.append(app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showIfPending() }
        })
        // Time away from the screen counts as rest, so start the interval over.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            })
        }
        restart()
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        pending = false
        dismiss(animated: false)
    }

    private func restart() {
        pause()
        guard isEnabled else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.intervalEnded() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func intervalEnded() {
        timer = nil
        guard isEnabled else { return }
        if !present() { pending = true }
    }

    private func showIfPending() {
        guard pending, isEnabled else { return }
        pending = false
        if !present() { restart() }
    }

    /// Shows the reminder over the window in front. Returns false when Bark has no window to show it on.
    private func present() -> Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible else { return false }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.remaining = Self.restSeconds
        state.done = false
        let host = NSHostingView(rootView: EyeRestView(state: state, total: Self.restSeconds, animateIn: !reduceMotion) { [weak self] in
            self?.finish()
        })
        let size = host.fittingSize
        let frame = PageFrameHostingView.pageRect(in: window) ?? window.convertToScreen(window.contentLayoutRect)
        let inset = EyeRestView.shadowInset
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16 + inset, y: frame.maxY - size.height - 16 + inset,
                              width: size.width, height: size.height), display: true)
        panel.contentView = host
        panel.level = window.level
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "Rest your focus. Look at something about 20 feet away for 20 seconds.",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        countdown?.invalidate()
        let countdown = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(countdown, forMode: .common)
        self.countdown = countdown
        return true
    }

    private func tick() {
        guard state.remaining > 0 else { return }
        state.remaining -= 1
        guard state.remaining == 0 else { return }
        countdown?.invalidate()
        countdown = nil
        withAnimation(.easeOut(duration: 0.2)) { state.done = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.state.done else { return }
            self.finish()
        }
    }

    /// The rest is over (or skipped): hide the reminder and start the next interval.
    private func finish() {
        dismiss(animated: true)
        restart()
    }

    private func dismiss(animated: Bool) {
        countdown?.invalidate()
        countdown = nil
        state.done = false
        guard let panel, panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated && !reduceMotion ? 0.2 : 0
            panel.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                guard panel.alphaValue == 0 else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("BarkEyeRestReminder")
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

@MainActor private final class EyeRestState: ObservableObject {
    @Published var remaining = EyeRestReminder.restSeconds
    @Published var done = false
}

private struct EyeRestView: View {
    static let shadowInset: CGFloat = 16
    @ObservedObject var state: EyeRestState
    let total: Int
    let animateIn: Bool
    let skip: () -> Void
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(state.remaining) / CGFloat(total))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: state.remaining)
                if state.done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                } else {
                    Text("\(state.remaining)").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.done ? "Nice — back to it" : "Rest your focus").font(.system(size: 13, weight: .semibold))
                Text("Every 20 minutes, look at something about 20 feet away for 20 seconds. Your focusing muscles tire from holding at screen distance.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(width: 250, alignment: .leading)
            Button(action: skip) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
                    .background(.white.opacity(0.12), in: Circle())
            }.buttonStyle(.plain).help("Skip this break").accessibilityLabel("Skip this break")
        }.foregroundStyle(.white)
            .padding(14)
            .background(Color(white: 0.16), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .scaleEffect(shown ? 1 : 0.92, anchor: .topTrailing)
            .offset(y: shown ? 0 : -8)
            .opacity(shown ? 1 : 0)
            .padding(Self.shadowInset)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .onAppear {
                guard animateIn else { shown = true; return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) { shown = true }
            }
    }
}
