// Toolchest's widget extension: Control Center and menu bar controls, and desktop widgets.
//
// The extension is sandboxed. Every read and action goes to the Toolchest app over the widget channel
// in ToolchestIPC.swift (a private message port plus a per-launch secret), and Toolchest applies its
// module switches before doing anything. When Toolchest isn't running, controls show off and widgets
// say so.
import AppIntents
import SwiftUI
import WidgetKit

@main
struct ToolchestWidgets: WidgetBundle {
    var body: some Widget {
        KeepAwakeControl()
        MicMuteControl()
        NextOutputControl()
        CleaningModeControl()
        HyperKeyControl()
        KeepAwakeWidget()
        AudioWidget()
    }
}

enum WidgetError: Error, CustomLocalizedStringResourceConvertible {
    case toolchestNotRunning
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .toolchestNotRunning: "Open Toolchest first."
        case .refused(let message): "\(message)"
        }
    }
}

/// Sends a command and turns a refusal into an error the system shows.
func command(_ command: WidgetIPC.Command, minutes: Int? = nil) throws {
    guard let state = WidgetIPC.ask(command, minutes: minutes) else { throw WidgetError.toolchestNotRunning }
    if let error = state.error { throw WidgetError.refused(error) }
}

// MARK: Intents (run in the extension, act through Toolchest)

struct SetKeepAwakeIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keep Awake"
    static let isDiscoverable = false
    @Parameter(title: "Keep awake") var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        try command(value ? .keepAwakeOn : .keepAwakeOff)
        return .result()
    }
}

struct SetMicMuteIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    static let isDiscoverable = false
    @Parameter(title: "Muted") var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        try command(value ? .micMute : .micUnmute)
        return .result()
    }
}

struct SetHyperKeyControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Hyper Key"
    static let isDiscoverable = false
    @Parameter(title: "On") var value: Bool

    func perform() async throws -> some IntentResult {
        try command(value ? .hyperOn : .hyperOff)
        return .result()
    }
}

struct NextOutputControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Output Device"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        try command(.nextOutput)
        return .result()
    }
}

struct CleaningModeControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Cleaning Mode"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        try command(.cleaning)
        return .result()
    }
}

// MARK: Controls

struct StateValue: ControlValueProvider {
    let read: @Sendable (WidgetIPC.State) -> Bool
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        WidgetIPC.ask(.state).map(read) ?? false
    }
}

struct OutputNameValue: ControlValueProvider {
    var previewValue: String { "Speakers" }

    func currentValue() async throws -> String {
        WidgetIPC.ask(.state)?.outputName ?? "Output"
    }
}

struct KeepAwakeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "info.gabrimatic.toolchest.control.keep-awake", provider: StateValue { $0.keepAwakeOn }) { on in
            ControlWidgetToggle("Keep Awake", isOn: on, action: SetKeepAwakeIntent()) { isOn in
                Label(isOn ? "Awake" : "Off", systemImage: isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer")
            }
            .tint(Brand.accent.color)
        }
        .displayName("Keep Awake")
        .description("Keeps the Mac awake until you turn it off.")
    }
}

struct MicMuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "info.gabrimatic.toolchest.control.mic-mute", provider: StateValue { $0.micMuted }) { muted in
            ControlWidgetToggle("Mute Microphone", isOn: muted, action: SetMicMuteIntent()) { isMuted in
                Label(isMuted ? "Muted" : "Live", systemImage: isMuted ? "mic.slash.fill" : "mic.fill")
            }
            .tint(Brand.accent.color)
        }
        .displayName("Mute Microphone")
        .description("Mutes the current input device.")
    }
}

struct NextOutputControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "info.gabrimatic.toolchest.control.next-output", provider: OutputNameValue()) { name in
            ControlWidgetButton(action: NextOutputControlIntent()) {
                Label(name, systemImage: "hifispeaker.arrow.forward")
            }
        }
        .displayName("Next Output Device")
        .description("Switches sound to the next output.")
    }
}

struct CleaningModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "info.gabrimatic.toolchest.control.cleaning") {
            ControlWidgetButton(action: CleaningModeControlIntent()) {
                Label("Cleaning Mode", systemImage: "display")
            }
        }
        .displayName("Cleaning Mode")
        .description("Blacks out the screens and pauses input. Hold Esc for 2 seconds to leave.")
    }
}

struct HyperKeyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "info.gabrimatic.toolchest.control.hyper", provider: StateValue { $0.hyperOn }) { on in
            ControlWidgetToggle("Hyper Key", isOn: on, action: SetHyperKeyControlIntent()) { isOn in
                Label(isOn ? "Caps Lock is Hyper" : "Caps Lock", systemImage: isOn ? "capslock.fill" : "capslock")
            }
        }
        .displayName("Hyper Key")
        .description("Caps Lock as ⌃⌥⇧⌘.")
    }
}

// MARK: Widgets

struct StateEntry: TimelineEntry {
    let date: Date
    let state: WidgetIPC.State?
}

struct StateProvider: TimelineProvider {
    func placeholder(in context: Context) -> StateEntry {
        StateEntry(date: .now, state: WidgetIPC.State(keepAwakeAvailable: true, micAvailable: true, outputName: "Speakers",
                                                      outputSymbol: "speaker.wave.2", inputName: "Microphone"))
    }

    func getSnapshot(in context: Context, completion: @escaping (StateEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : StateEntry(date: .now, state: WidgetIPC.ask(.state)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StateEntry>) -> Void) {
        let state = WidgetIPC.ask(.state)
        // Toolchest reloads widgets whenever something changes; the timer end is the only other moment.
        let next = state?.keepAwakeUntil ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [StateEntry(date: .now, state: state)], policy: .after(next)))
    }
}

struct KeepAwakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "info.gabrimatic.toolchest.widget.keep-awake", provider: StateProvider()) { entry in
            KeepAwakeWidgetView(state: entry.state)
                .containerBackground(for: .widget) { Brand.ground.color }
        }
        .configurationDisplayName("Keep Awake")
        .description("Shows whether the Mac is kept awake, and for how long.")
        .supportedFamilies([.systemSmall])
    }
}

struct AudioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "info.gabrimatic.toolchest.widget.audio", provider: StateProvider()) { entry in
            AudioWidgetView(state: entry.state)
                .containerBackground(for: .widget) { Brand.ground.color }
        }
        .configurationDisplayName("Audio Devices")
        .description("The current output and input, with a mic mute button.")
        .supportedFamilies([.systemSmall])
    }
}
