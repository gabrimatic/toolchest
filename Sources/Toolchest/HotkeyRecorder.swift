import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Toolchest's own shortcut recorder. While recording, Toolchest's global hotkeys are paused so pressing
/// one doesn't fire it. Esc cancels, Delete clears. Conflicts with macOS shortcuts, standard app
/// commands and Toolchest's other hotkeys are listed under the field.
struct HotkeyRecorder: View {
    let name: String
    @Binding var combo: KeyCombo?
    let controller: AppController
    var showConflicts = true

    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var pressed: NSEvent.ModifierFlags = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Text(label)
                        .font(Brand.font(12, combo == nil && !recording ? .regular : .medium))
                        .monospacedDigit()
                        .foregroundStyle(recording ? Color.toolchestAccent : (combo == nil ? .toolchestSecondary : .toolchestText))
                        .frame(minWidth: 108)
                        .contentTransition(.numericText())
                }
                .toolchestGlassButton()
                .accessibilityLabel(recording ? "Recording shortcut for \(name). Press keys, escape to cancel." :
                    "Shortcut for \(name): \(combo?.spoken ?? "none")")
                .accessibilityHint("Click to record a new shortcut")
                if combo != nil && !recording {
                    Button {
                        combo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.toolchestSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear shortcut for \(name)")
                }
            }
            if let message {
                Text(message)
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showConflicts, let combo, !conflicts(combo).isEmpty {
                Label(conflicts(combo).joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestText)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Conflict: " + conflicts(combo).joined(separator: ", "))
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording {
            let mods = KeyCombo(keyCode: 0, modifiers: pressed).display.dropLast()
            return mods.isEmpty ? "Type shortcut…" : String(mods) + "…"
        }
        return combo?.display ?? "Record Shortcut"
    }

    private func conflicts(_ combo: KeyCombo) -> [String] {
        ShortcutConflicts.conflicts(for: combo, system: ShortcutConflicts.currentSystemShortcuts(),
                                    toolchest: controller.assignedHotkeys(excluding: name))
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        message = nil
        recording = true
        pressed = []
        HotkeyCenter.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                pressed = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
                return nil
            }
            let flags = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
            if flags.isEmpty && event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            if flags.isEmpty && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
                combo = nil
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: event.keyCode, modifiers: flags)
            guard candidate.isValidHotkey else {
                message = "Add ⌘, ⌥ or ⌃ so typing still works."
                NSSound.beep()
                return nil
            }
            combo = candidate
            Haptics.play(.recorded)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            controller.apply()
        }
    }
}
