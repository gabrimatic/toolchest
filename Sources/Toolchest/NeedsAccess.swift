import AppKit
import SwiftUI
import os

@MainActor
@Observable
final class NeedsAccessModel {
    /// What the card's one button does: ask macOS (nothing has been refused yet) or open the
    /// System Settings pane (macOS was asked and said no, so it won't ask again).
    enum Mode: Equatable { case allow, openSettings }

    var permission = Permission.accessibility
    var feature = ""
    var mode = Mode.openSettings
    var onClose: () -> Void = {}
    var onAllow: () -> Void = {}

    /// "Allow…" or "Open System Settings".
    var buttonTitle: String { mode == .allow ? "Allow…" : "Open System Settings" }

    var message: String {
        mode == .allow
            ? "Toolchest needs \(permission.title).\nAllow it and it works right away."
            : "Toolchest needs \(permission.title).\nTurn it on in System Settings and it works right away."
    }
}

/// The "not allowed yet" state: a flat card with one button, shown when a feature needs a
/// permission Toolchest doesn't have. It closes itself the moment access is granted.
struct NeedsAccessView: View {
    let model: NeedsAccessModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.permission.symbol)
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.toolchestText)
                .frame(width: 30)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.feature) isn\u{2019}t allowed yet")
                        .font(Brand.font(14, .medium))
                    Text(model.message)
                        .font(Brand.font(12))
                        .foregroundStyle(.toolchestSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.buttonTitle) {
                    if model.mode == .allow { model.onAllow() } else { Permissions.open(model.permission) }
                }
                .toolchestGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
            }
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .toolchestGlassButton()
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .flatCard(in: .rect(cornerRadius: 22))
        .padding(16)
        .toolchestSurface()
        .onExitCommand(perform: model.onClose)
        .accessibilityElement(children: .contain)
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Telling when macOS is showing its own permission prompt, so Toolchest's card never stacks on it.
@MainActor
enum SystemPrompt {
    /// The processes macOS shows its permission prompts from (tccd hands them to universalAccessAuthWarn).
    static let owners: Set<String> = ["universalAccessAuthWarn", "UserNotificationCenter", "UniversalAccessControl",
                                      "CoreServicesUIAgent", "SecurityAgent"]

    enum Outcome: Equatable {
        /// No prompt showed up: macOS had nothing to ask.
        case none
        /// A prompt showed and has gone away.
        case answered
    }

    /// Whether a prompt window is on screen. Window owners are readable without any permission.
    static func isShowing() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { return false }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return alpha > 0 && (bounds?.width ?? 0) > 80 && (bounds?.height ?? 0) > 40
        }
    }

    /// Waits for a prompt to appear (up to `appearTicks`), then for it to go away (up to
    /// `answerTicks`). `pause` waits one tick and returns false when the wait was cancelled.
    static func waitForAnswer(isShowing: () -> Bool, pause: () async -> Bool,
                              appearTicks: Int = 15, answerTicks: Int = 1500) async -> Outcome {
        var seen = false
        for _ in 0..<appearTicks {
            if isShowing() { seen = true; break }
            guard await pause() else { return .none }
        }
        guard seen else { return .none }
        for _ in 0..<answerTicks {
            if !isShowing() { return .answered }
            guard await pause() else { return .answered }
        }
        return .answered
    }
}

@MainActor
final class NeedsAccess {
    static let shared = NeedsAccess()

    private let model = NeedsAccessModel()
    private var panel: NSPanel?
    private var watcher: Task<Void, Never>?
    private var asking: Task<Void, Never>?
    private let log = Logger(subsystem: "info.gabrimatic.toolchest", category: "permissions")

    /// A feature needs `permission`. The first time, Toolchest asks macOS and holds its own card back
    /// until macOS's prompt has been answered, so the two never stack. After a refusal the card
    /// shows at once with a button to the System Settings pane.
    func present(_ permission: Permission, for feature: String) {
        guard Permissions.state(permission) != .granted else { return }
        if asking != nil { return } // macOS's prompt is still up
        model.permission = permission
        model.feature = feature
        model.onClose = { [weak self] in self?.close() }
        model.onAllow = { [weak self] in self?.ask(permission, for: feature, retry: true) }
        if Permissions.hasAsked(permission) {
            show(.openSettings)
        } else {
            ask(permission, for: feature, retry: false)
        }
    }

    private func ask(_ permission: Permission, for feature: String, retry: Bool) {
        close()
        Permissions.ask(permission)
        asking = Task { @MainActor [weak self] in
            let outcome = await SystemPrompt.waitForAnswer(isShowing: { SystemPrompt.isShowing() }, pause: {
                (try? await Task.sleep(for: .milliseconds(200))) != nil
            })
            // macOS records the answer a moment after the prompt closes.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.asking = nil
            guard !Task.isCancelled else { return }
            if Permissions.state(permission) == .granted {
                HUD.shared.show("checkmark.circle.fill", "\(permission.title) allowed", detail: "Try \(feature) again.")
            } else {
                if outcome == .none { self.log.notice("no macOS prompt appeared for \(permission.rawValue, privacy: .public)") }
                // A prompt that was answered (or one macOS no longer shows) means the way on is System Settings.
                self.show(outcome == .answered || retry ? .openSettings : .allow)
            }
        }
    }

    private func show(_ mode: NeedsAccessModel.Mode) {
        model.mode = mode
        let permission = model.permission, feature = model.feature
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: 452, height: 170)
        if let screen = screenUnderMouse {
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 70,
                                  width: size.width, height: size.height), display: false)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        announce("\(feature) isn\u{2019}t allowed yet. Toolchest needs \(permission.title).")

        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if Permissions.state(permission) == .granted {
                    self.close()
                    HUD.shared.show("checkmark.circle.fill", "\(permission.title) allowed", detail: "Try \(feature) again.")
                    return
                }
            }
        }
    }

    func close() {
        watcher?.cancel()
        watcher = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 452, height: 170),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Hide Others, or a hidden launch, must not take this off the screen.
        panel.canHide = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NeedsAccessView(model: model))
        return panel
    }
}
