import Foundation

/// The Hyper key's state machine. Caps Lock arrives as F18 (hidutil remaps it), and while F18 is
/// held every other key gets Control, Option, Shift and Command added. A quick tap with no other
/// key can send Escape instead.
struct HyperState: Sendable {
    static let f18KeyCode = 79
    static let tapThreshold: TimeInterval = 0.3

    enum Output: Sendable, Equatable {
        /// F18 pressed: post the four modifier presses.
        case pressModifiers
        /// F18 auto-repeat: swallow.
        case swallow
        /// F18 released: post the modifier releases, plus Escape on a quick lone tap.
        case releaseModifiers(sendEscape: Bool)
        /// Another key while Hyper is held: add the modifiers to it.
        case addModifiers
        case pass
    }

    private(set) var isDown = false
    private var used = false
    private var downAt: TimeInterval = 0

    mutating func keyDown(keyCode: Int, now: TimeInterval) -> Output {
        if keyCode == Self.f18KeyCode {
            if isDown { return .swallow }
            isDown = true
            used = false
            downAt = now
            return .pressModifiers
        }
        if isDown { used = true; return .addModifiers }
        return .pass
    }

    mutating func keyUp(keyCode: Int, now: TimeInterval, escapeOnTap: Bool) -> Output {
        if keyCode == Self.f18KeyCode {
            guard isDown else { return .swallow }
            isDown = false
            let quick = now - downAt < Self.tapThreshold
            return .releaseModifiers(sendEscape: escapeOnTap && !used && quick)
        }
        return isDown ? .addModifiers : .pass
    }

    /// A click while Hyper is held counts as use, so releasing won't send Escape.
    mutating func noteOtherInput() { if isDown { used = true } }

    /// Forgets a press whose release was lost (tap restarted). Returns whether modifiers need releasing.
    mutating func reset() -> Bool {
        defer { isDown = false; used = false }
        return isDown
    }
}
