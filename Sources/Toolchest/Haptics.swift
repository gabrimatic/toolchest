import AppKit

/// Light Force Touch trackpad feedback. The trackpad only plays it while a finger rests on it,
/// so it never surprises anyone using a mouse. Switchable in Settings > General.
@MainActor
enum Haptics {
    enum Kind: Equatable {
        /// Something began (a hold ring appeared, a region was picked, a switch flipped).
        case tick
        /// Something committed (a guarded quit fired, cleaning mode ended).
        case commit
        /// A shortcut was recorded.
        case recorded
    }

    static var enabled = true
    static var performer: NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer

    static func pattern(for kind: Kind) -> NSHapticFeedbackManager.FeedbackPattern {
        switch kind {
        case .tick: .alignment
        case .commit: .levelChange
        case .recorded: .generic
        }
    }

    static func play(_ kind: Kind) {
        guard enabled else { return }
        performer.perform(pattern(for: kind), performanceTime: .now)
    }
}

/// Power, heat and accessibility conditions that tone down Toolchest's motion and effects.
@MainActor
@Observable
final class SystemConditions {
    static let shared = SystemConditions()

    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    private(set) var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Skip decorative animation: Reduce Motion, Low Power Mode, or a hot Mac.
    var calmEffects: Bool { Self.calm(reduceMotion: reduceMotion, lowPower: lowPower, thermal: thermal) }

    nonisolated static func calm(reduceMotion: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        reduceMotion || lowPower || thermal == .serious || thermal == .critical
    }

    private init() {
        let refresh: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in SystemConditions.shared.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh))
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: refresh))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                           object: nil, queue: .main, using: refresh))
    }

    func refresh() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}
