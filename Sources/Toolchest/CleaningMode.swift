import AppKit
import ApplicationServices
import SwiftUI

@MainActor
@Observable
final class CleaningModel {
    var remaining = Int(CleaningGate.maximumDuration)
    var escProgress: Double = 0
}

struct CleaningView: View {
    let model: CleaningModel
    private let ice = Color(nsColor: Brand.ice.ns)

    /// The one place true black is used: the screen is blacked out so smudges show. The words and
    /// the ring are ice on it, the exit ring is the one accent element.
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(ice.opacity(0.18), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: model.escProgress)
                        .stroke(Brand.accent.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "display")
                        .font(.system(size: 28, weight: .light))
                        .symbolRenderingMode(.monochrome)
                }
                .frame(width: 76, height: 76)
                VStack(spacing: 6) {
                    Text("Cleaning Mode")
                        .font(Brand.font(22, .light))
                    Text("Keyboard and trackpad are paused.")
                        .font(Brand.font(14))
                        .foregroundStyle(ice.opacity(0.7))
                }
                Text("Hold Esc for 2 seconds to exit · ends in \(timeText)")
                    .font(Brand.font(13, .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(ice.opacity(0.25), lineWidth: 1))
            }
            .foregroundStyle(ice)
            .padding(36)
            .background(ice.opacity(0.05), in: .rect(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(ice.opacity(0.25), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Cleaning Mode. Keyboard and trackpad are paused. Hold escape for 2 seconds to exit. Ends in \(model.remaining) seconds.")
        }
    }

    private var timeText: String {
        String(format: "%d:%02d", model.remaining / 60, model.remaining % 60)
    }
}

/// A black screen that swallows keyboard and pointer input so the Mac can be wiped clean.
///
/// It can never lock the user out:
/// 1. Holding Esc for 2 seconds exits (checked by the tap and by a timer).
/// 2. A 60-second deadline exits through a main-queue timer.
/// 3. The tap's gate itself passes every event after the deadline, even if the main thread stalls.
/// 4. The overlay ignores the mouse, so even a stuck overlay cannot block clicks once input passes.
/// 5. Without Accessibility the tap cannot be created, and cleaning mode refuses to start.
@MainActor
final class CleaningMode {
    private let model = CleaningModel()
    private var windows: [NSWindow] = []
    private var deadlineTimer: DispatchSourceTimer?
    private var secondTimer: Timer?
    private var escTimer: Timer?
    private var startedAt: Date?
    private var screenObserver: NSObjectProtocol?
    private(set) var isActive = false

    func start() {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else {
            NeedsAccess.shared.present(.accessibility, for: "Cleaning Mode")
            return
        }
        isActive = true
        model.remaining = Int(CleaningGate.maximumDuration)
        model.escProgress = 0
        coverScreens()
        // A display plugged in or out mid-clean gets covered too.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isActive else { return }
                self.coverScreens()
            }
        }
        // Only swallow input once the overlay is really up.
        guard windows.allSatisfy(\.isVisible), EventTap.shared.beginCleaning(duration: CleaningGate.maximumDuration) else {
            stop()
            HUD.shared.error("Cleaning Mode could not start", "macOS refused the input tap. Check Accessibility.")
            return
        }
        NSCursor.hide()
        startedAt = Date()

        let deadline = DispatchSource.makeTimerSource(queue: .main)
        deadline.schedule(deadline: .now() + CleaningGate.maximumDuration)
        deadline.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.stop() } }
        deadline.resume()
        deadlineTimer = deadline

        let seconds = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tickSecond() }
        }
        RunLoop.main.add(seconds, forMode: .common)
        secondTimer = seconds
        announce("Cleaning Mode on. Hold escape for 2 seconds to exit.")
    }

    /// One black window per screen, rebuilt when the screen set changes.
    private func coverScreens() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = NSHostingView(rootView: CleaningView(model: model))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func handle(_ signal: TapSignal) {
        guard isActive else { return }
        switch signal {
        case .cleaningEscDown:
            escTimer?.invalidate()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tickEsc() }
            }
            RunLoop.main.add(timer, forMode: .common)
            escTimer = timer
        case .cleaningEscUp:
            escTimer?.invalidate()
            escTimer = nil
            withAnimation(.easeOut(duration: 0.2)) { model.escProgress = 0 }
        case .cleaningExit:
            stop()
        default:
            break
        }
    }

    private func tickEsc() {
        model.escProgress = EventTap.shared.cleaningEscProgress()
        if EventTap.shared.cleaningTick() { stop() }
    }

    private func tickSecond() {
        guard let startedAt else { return }
        model.remaining = max(0, Int((CleaningGate.maximumDuration - Date().timeIntervalSince(startedAt)).rounded(.up)))
        if EventTap.shared.cleaningTick() { stop() }
    }

    func stop() {
        let wasActive = isActive
        EventTap.shared.endCleaning()
        deadlineTimer?.cancel()
        deadlineTimer = nil
        secondTimer?.invalidate()
        secondTimer = nil
        escTimer?.invalidate()
        escTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if wasActive && startedAt != nil { NSCursor.unhide() }
        startedAt = nil
        isActive = false
        if wasActive {
            Haptics.play(.commit)
            announce("Cleaning Mode off")
        }
    }
}
