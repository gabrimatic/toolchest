// The look of Toolchest's desktop widgets, kept apart from the WidgetKit plumbing.
import AppIntents
import SwiftUI
import WidgetKit

struct KeepAwakeWidgetView: View {
    let state: WidgetIPC.State?
    var interactive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: on ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(on ? Color.toolchestAccent : .toolchestSecondary)
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                if interactive, state?.keepAwakeAvailable == true {
                    Toggle(isOn: on, intent: SetKeepAwakeIntent(value: !on)) {
                        Text(on ? "On" : "Off")
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            Text("Keep Awake")
                .font(Brand.font(13, .medium))
            Group {
                if state == nil {
                    Text("Open Toolchest to use this widget.")
                } else if state?.keepAwakeAvailable == false {
                    Text("Turn on Keep Awake in Toolchest.")
                } else if on, let until = state?.keepAwakeUntil {
                    Text(until, style: .timer).monospacedDigit()
                } else if on {
                    Text("Until turned off")
                } else {
                    Text("Mac sleeps normally")
                }
            }
            .font(Brand.font(11))
            .foregroundStyle(.toolchestSecondary)
        }
        .foregroundStyle(.toolchestText)
        .tint(Brand.accent.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake, \(on ? "on" : "off")")
    }

    private var on: Bool { state?.keepAwakeOn ?? false }
}

struct AudioWidgetView: View {
    let state: WidgetIPC.State?
    var interactive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: state?.outputSymbol ?? "speaker.wave.2")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.toolchestText)
                Spacer()
                if interactive, state?.micAvailable == true {
                    Button(intent: SetMicMuteIntent(value: !(state?.micMuted ?? false))) {
                        Image(systemName: state?.micMuted == true ? "mic.slash.fill" : "mic.fill")
                            .foregroundStyle(state?.micMuted == true ? Color.toolchestAccent : .toolchestText)
                            .frame(width: 30, height: 30)
                            .background(Brand.surface.color, in: .circle)
                            .overlay(Circle().stroke(Brand.hairline.color, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state?.micMuted == true ? "Unmute microphone" : "Mute microphone")
                }
            }
            Spacer(minLength: 0)
            Text(state?.outputName ?? "No output")
                .font(Brand.font(13, .medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: state?.micMuted == true ? "mic.slash" : "mic")
                Text(state?.inputName ?? (state == nil ? "Open Toolchest to use this widget." : "No input"))
                    .lineLimit(1)
            }
            .font(Brand.font(11))
            .foregroundStyle(.toolchestSecondary)
        }
        .foregroundStyle(.toolchestText)
        .tint(Brand.accent.color)
        .accessibilityElement(children: .contain)
    }
}
