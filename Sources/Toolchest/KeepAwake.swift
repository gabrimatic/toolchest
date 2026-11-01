import Foundation
import IOKit.pwr_mgt

/// Keeps the display (and so the Mac) awake with a power assertion, for a set time or until stopped.
/// The assertion is released on stop, on expiry and when Toolchest quits (macOS drops it with the process).
@MainActor
final class KeepAwake {
    static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("15 Minutes", 15 * 60), ("30 Minutes", 30 * 60), ("1 Hour", 3600), ("2 Hours", 7200),
        ("5 Hours", 5 * 3600), ("Until Turned Off", nil),
    ]

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private(set) var until: Date?
    /// The length the running session was started with (nil: until turned off), for the menu's checkmark.
    private(set) var chosenSeconds: TimeInterval?
    private(set) var isActive = false
    var onChange: (() -> Void)?

    /// Returns false when macOS refused the assertion.
    @discardableResult
    func start(for seconds: TimeInterval?) -> Bool {
        stop(notify: false)
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Toolchest Keep Awake" as CFString, &assertion)
        guard status == kIOReturnSuccess else {
            assertion = 0
            onChange?()
            return false
        }
        isActive = true
        chosenSeconds = seconds
        if let seconds {
            until = Date().addingTimeInterval(seconds)
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { [weak self] in self?.stop() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            until = nil
        }
        onChange?()
        return true
    }

    func stop(notify: Bool = true) {
        timer?.invalidate()
        timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        isActive = false
        until = nil
        chosenSeconds = nil
        if notify { onChange?() }
    }

    /// Index in `durations` of the running session's length, or nil when nothing runs or the
    /// length isn't one of the menu's.
    var chosenDurationIndex: Int? {
        guard isActive else { return nil }
        return Self.durations.firstIndex { $0.seconds == chosenSeconds }
    }

    /// A timed session whose end passed while the Mac slept ends now, not at the next timer tick.
    func expireIfDue() {
        if isActive, let until, until <= Date() { stop() }
    }

    /// Status line for the menu: "28 min left, until 5:41 PM". Worked out when the menu opens, so
    /// nothing ticks while it is closed.
    var statusText: String { statusText(now: Date()) }

    func statusText(now: Date) -> String {
        guard isActive else { return "Off" }
        guard let until else { return "On until turned off" }
        return Self.remainingText(until.timeIntervalSince(now)) + ", until " + until.formatted(date: .omitted, time: .shortened)
    }

    /// "2 h 5 min left", "28 min left", "Under a minute left".
    static func remainingText(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded(.up))
        guard seconds > 0, minutes > 0 else { return "Under a minute left" }
        if minutes < 60 { return "\(minutes) min left" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) h left" : "\(hours) h \(rest) min left"
    }
}
