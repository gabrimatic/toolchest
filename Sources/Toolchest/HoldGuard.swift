import Foundation

/// The quit guard's decision logic: an action fires after a hold of `hold` seconds, or on a second
/// press within `doubleWindow` seconds of a quick first press. Pure, with an injected clock.
struct HoldGuard: Sendable {
    enum Key: Sendable, Equatable { case quit, close }

    enum Target: Sendable, Equatable {
        case key(Key, pid: pid_t)
        case dockQuit(pid: pid_t)
    }

    enum Action: Sendable, Equatable {
        case showRing
        case hideRing(completed: Bool)
        case scheduleCheck(after: TimeInterval)
        case hint(Target)
        case fire(Target)
    }

    private enum State: Sendable, Equatable {
        case idle
        case holding(Target, since: TimeInterval)
        case armed(Target, until: TimeInterval)
        case fired(Target)
    }

    var hold: TimeInterval
    var doubleWindow: TimeInterval = 0.45
    private var state = State.idle

    init(hold: TimeInterval) { self.hold = min(max(hold, 0.2), 3) }

    var isHolding: Bool { if case .holding = state { true } else { false } }

    mutating func press(_ target: Target, now: TimeInterval) -> [Action] {
        switch state {
        case .fired(let current) where current == target:
            return []
        case .holding(let current, _) where current == target:
            return [] // key repeat
        case .armed(let current, let until) where current == target && now <= until:
            state = .fired(target)
            return [.fire(target)]
        default:
            state = .holding(target, since: now)
            return [.showRing, .scheduleCheck(after: hold)]
        }
    }

    mutating func release(now: TimeInterval) -> [Action] {
        switch state {
        case .holding(let target, let since):
            if now - since >= hold {
                state = .idle
                return [.hideRing(completed: true), .fire(target)]
            }
            state = .armed(target, until: now + doubleWindow)
            return [.hideRing(completed: false), .hint(target)]
        case .fired:
            state = .idle
            return []
        case .armed, .idle:
            return []
        }
    }

    mutating func check(now: TimeInterval) -> [Action] {
        guard case .holding(let target, let since) = state, now - since >= hold else { return [] }
        state = .fired(target)
        return [.hideRing(completed: true), .fire(target)]
    }

    mutating func cancel() -> [Action] {
        if case .holding = state { state = .idle; return [.hideRing(completed: false)] }
        state = .idle
        return []
    }
}
