import SwiftUI
import Observation

/// SwiftUI can evaluate a Binding's getter on a background thread (during a graph update). In Swift 6
/// mode `Binding(get:set:)` closures written inside a main-actor view inherit main-actor isolation,
/// so reading model state in them traps with a dispatch queue assertion off the main thread.
/// Every binding in Toolchest comes from here instead: the getter returns an immutable value captured
/// when the view body ran, and the setter applies on the main actor (at once when already there).
enum SafeBinding {
    /// A binding that reads `value` and writes through `set` on the main actor.
    /// Declared `nonisolated` so the closures below do not inherit the caller's main-actor isolation.
    nonisolated static func make<Value: Sendable>(_ value: Value, set: @escaping @MainActor @Sendable (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { set(newValue) }
                } else {
                    Task { @MainActor in set(newValue) }
                }
            }
        )
    }

    /// A switch that reads off while its parent is off, and writes the saved choice through `isOn`.
    nonisolated static func gated(isEnabled: Bool, isOn: Binding<Bool>) -> Binding<Bool> {
        make(isEnabled && isOn.wrappedValue) { newValue in isOn.wrappedValue = newValue }
    }
}

@MainActor
extension Prefs {
    /// The whole settings value as a binding. A key-path binding on the observable store, so derived
    /// bindings (`settings.keyboard.hyper`) read and write the live value field by field.
    var settingsBinding: Binding<Settings> { Bindable(self).settings }

    func moduleBinding(_ module: Module) -> Binding<Bool> {
        SafeBinding.make(settings.isEnabled(module)) { [self] on in settings.setEnabled(module, on) }
    }

    func comboBinding(_ action: HotkeyAction) -> Binding<KeyCombo?> {
        SafeBinding.make(combo(action)) { [self] combo in setCombo(combo, for: action) }
    }

    func appHotkeyBinding(bundleID: String) -> Binding<KeyCombo?> {
        let current = settings.keyboard.appHotkeys.first { $0.bundleID == bundleID }?.combo
        return SafeBinding.make(current) { [self] combo in
            if let index = settings.keyboard.appHotkeys.firstIndex(where: { $0.bundleID == bundleID }) {
                settings.keyboard.appHotkeys[index].combo = combo
            }
        }
    }
}
