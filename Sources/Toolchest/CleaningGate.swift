import Foundation

/// The input gate behind Cleaning Mode. Pure logic with an injected clock.
///
/// Guarantees:
/// - Holding Esc for `escHold` seconds exits.
/// - Any event at or after `deadline` exits and is passed through, so a stalled main thread can
///   never keep input blocked past the deadline.
/// - After exit, every event passes.
struct CleaningGate: Sendable {
    enum Input: Sendable { case escDown, escUp, other }
    enum Verdict: Sendable, Equatable { case swallow, pass, exit }

    static let maximumDuration: TimeInterval = 60
    static let escHold: TimeInterval = 2

    let deadline: TimeInterval
    private(set) var escDownAt: TimeInterval?
    private(set) var finished = false

    init(start: TimeInterval, duration: TimeInterval = CleaningGate.maximumDuration) {
        deadline = start + min(max(duration, 1), CleaningGate.maximumDuration)
    }

    mutating func process(_ input: Input, now: TimeInterval) -> Verdict {
        if finished { return .pass }
        if now >= deadline { finished = true; return .exit }
        switch input {
        case .escDown:
            if let since = escDownAt {
                if now - since >= Self.escHold { finished = true; return .exit }
            } else {
                escDownAt = now
            }
        case .escUp:
            escDownAt = nil
        case .other:
            if let since = escDownAt, now - since >= Self.escHold { finished = true; return .exit }
        }
        return .swallow
    }

    /// Called by timers: exits when Esc has been held long enough or time is up, even with no new events.
    mutating func tick(now: TimeInterval) -> Bool {
        if finished { return true }
        if now >= deadline { finished = true; return true }
        if let since = escDownAt, now - since >= Self.escHold { finished = true; return true }
        return false
    }

    /// 0...1 progress of the Esc hold, for the on-screen ring.
    func escProgress(now: TimeInterval) -> Double {
        guard let since = escDownAt, !finished else { return 0 }
        return min(max((now - since) / Self.escHold, 0), 1)
    }

    mutating func finish() { finished = true }
}
