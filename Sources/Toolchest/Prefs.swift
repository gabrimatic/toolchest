import Foundation
import Observation

/// The observable settings store the UI binds to. Every change is saved and applied at once.
@MainActor
@Observable
final class Prefs {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if let data = settings.encoded() { defaults.set(data, forKey: Settings.storageKey) }
            onChange?(oldValue)
        }
    }

    @ObservationIgnored var onChange: ((Settings) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = Settings.decode(defaults.data(forKey: Settings.storageKey))
    }

    func combo(_ action: HotkeyAction) -> KeyCombo? { settings.hotkeys[action.rawValue] }

    func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) {
        settings.hotkeys[action.rawValue] = combo
    }
}
