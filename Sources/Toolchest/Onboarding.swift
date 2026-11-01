import AppKit
import SwiftUI

/// Whether the first-run welcome window shows, and its record in the app's own preferences.
@MainActor
enum Onboarding {
    static let key = "onboarding.state"
    private static let doneValue = "done"

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: key) != doneValue
    }

    static func markDone(defaults: UserDefaults = .standard) {
        defaults.set(doneValue, forKey: key)
    }

    /// Back to a first run: the window shows again and every permission can be asked for again.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        Permissions.forgetAsked(defaults: defaults)
    }
}

/// The ground of the welcome and About windows: flat ink in the dark appearance, flat paper in the
/// light one. Nothing behind the text.
struct FlatBackdrop: View {
    var body: some View {
        Brand.ground.color
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct OnboardingView: View {
    let controller: AppController
    let onDone: () -> Void

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginNote: String?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to Toolchest")
                    .font(Brand.font(24, .light))
                Text("Power tools for your Mac. Everything starts off, and you switch on only what you want.")
                    .font(Brand.font(13))
                    .foregroundStyle(.toolchestSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Permission.allCases) { permission in
                        PermissionStatusRow(permission: permission, controller: controller, style: .card)
                        if permission != Permission.allCases.last {
                            Rectangle().fill(Brand.hairline.color).frame(height: 1).padding(.leading, 12)
                        }
                    }
                }
                .welcomeCard()
                Text("Each one is optional. You can allow it later in Settings.")
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestSecondary)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Launch at login").font(Brand.font(13))
                    Spacer(minLength: 8)
                    Toggle("Launch at login", isOn: SafeBinding.make(launchAtLogin, set: setLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if let loginNote {
                    Text(loginNote).font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                }
            }
            .padding(12)
            .welcomeCard()

            PillButton(title: "Done", prominent: true, height: 36, fullWidth: true, action: onDone)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes this window. Toolchest stays in the menu bar.")
        }
        .padding(24)
        .frame(width: 460)
        .background(FlatBackdrop())
        .toolchestSurface()
        .onExitCommand(perform: onDone)
    }

    private func setLogin(_ on: Bool) {
        if let error = LoginItem.set(on) {
            loginNote = "Could not change the login item: \(error)"
        } else {
            loginNote = LoginItem.needsApproval ? "Approve Toolchest in System Settings > General > Login Items." : nil
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

/// A capsule text button drawn without its own glass, so a surface never stacks glass on glass.
struct PillButton: View {
    let title: String
    let prominent: Bool
    var height: CGFloat = 26
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.font(height > 30 ? 13 : 12, .medium))
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(prominent ? Color(.sRGB, red: 0xbb / 255, green: 0xe1 / 255, blue: 0xfa / 255) : Brand.text.color)
                .background(Capsule().fill(prominent ? Brand.accent.color : Brand.surface.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// A flat card on the flat ground: a faint fill and a hairline.
    func welcomeCard() -> some View {
        background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline.color, lineWidth: 1))
    }
}

/// The version as every window shows it, so no two surfaces disagree.
enum AppInfo {
    static func version(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    static var version: String { version() }
}

struct AboutView: View {
    static let tagline = "Power tools for your Mac, from the menu bar."

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Soroush Yousefpour"
    }

    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            Text("Toolchest")
                .font(Brand.font(24, .light))
            Text(AppInfo.version)
                .font(Brand.font(12))
                .foregroundStyle(.toolchestSecondary)
            Text(Self.tagline)
                .font(Brand.font(13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(Self.copyright)
                .font(Brand.font(11))
                .foregroundStyle(.toolchestSecondary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 28)
        .frame(width: 340)
        .background(FlatBackdrop())
        .toolchestSurface()
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .combine)
    }
}
