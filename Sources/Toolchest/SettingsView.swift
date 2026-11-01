import AppKit
import SwiftUI

enum SettingsPage: Hashable {
    case general, permissions, about
    case module(Module)
}

/// The window: a flat sidebar of pages, a hairline, and the page beside it under its title. The same
/// layout in every one of these apps, with the ground, text and accent from the palette.
struct SettingsView: View {
    let controller: AppController
    @FocusState private var sidebarFocused: Bool

    private var page: SettingsPage {
        get { controller.settingsPage }
        nonmutating set { controller.settingsPage = newValue }
    }

    private var pages: [SettingsPage] { [.general] + Module.allCases.map { .module($0) } + [.permissions, .about] }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Rectangle().fill(Brand.divider.color).frame(width: 1)
            detail
        }
        .frame(minWidth: 780, minHeight: 540)
        .background(Brand.ground.color)
        .background(WindowTitle(title: page.title))
        .font(Brand.font(13))
        .tint(Brand.accent.color)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(title: "General", symbol: "gearshape", selected: page == .general) { page = .general }
            Text("Modules")
                .font(Brand.font(12, .medium))
                .foregroundStyle(Brand.secondaryText.color)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(Module.allCases) { module in
                SidebarRow(title: module.title, symbol: module.symbol, selected: page == .module(module), on: controller.settings.isEnabled(module)) {
                    page = .module(module)
                }
            }
            Spacer().frame(height: 14)
            SidebarRow(title: "Permissions", symbol: "hand.raised", selected: page == .permissions) { page = .permissions }
            SidebarRow(title: "About", symbol: "info.circle", selected: page == .about) { page = .about }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // Below the traffic lights.
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        .focusable()
        .focused($sidebarFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let index = pages.firstIndex(of: page) else { return .ignored }
        page = pages[min(max(index + step, 0), pages.count - 1)]
        return .handled
    }

    private var detail: some View {
        Group {
            switch page {
            case .general: GeneralPage(controller: controller)
            case .permissions: PermissionsPage(controller: controller)
            case .about: AboutPage()
            case .module(let module): ModulePage(module: module, controller: controller)
            }
        }
        .foregroundStyle(.toolchestText)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The page's title in the unified toolbar's row. Content scrolling under it fades out.
        .safeAreaBar(edge: .top, spacing: 0) {
            Text(page.title)
                .font(Brand.font(22, .light))
                .foregroundStyle(.toolchestText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .frame(height: 56)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(minWidth: 520)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    /// A module's state: a filled dot when on, an empty ring when off. Told by shape, not by a colour.
    var on: Bool?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(title).font(Brand.font(13, .medium))
                Spacer(minLength: 0)
                if let on {
                    Circle()
                        .fill(on ? Color.toolchestText : .clear)
                        .overlay(Circle().stroke(Color.toolchestText.opacity(on ? 0 : 0.45), lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? Brand.text.color : Brand.secondaryText.color)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Brand.accent.color.opacity(0.34) : (hovering ? Brand.surface.color : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(on.map { $0 ? "On" : "Off" } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SettingsPage {
    var title: String {
        switch self {
        case .general: "General"
        case .permissions: "Permissions"
        case .about: "About"
        case .module(let module): module.title
        }
    }
}

/// Sets the hosting window's title, and keeps the first switch from opening with a focus ring.
/// A hosting controller doesn't pass `navigationTitle` on to its window by itself, and the window
/// title is what the split view shows over the detail pane. SwiftUI hands the first focusable
/// control the keyboard focus when the window appears; the window itself should hold it until
/// the user tabs in, like System Settings.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    final class Anchor: NSView {
        var title = "" { didSet { apply() } }
        override func viewDidMoveToWindow() {
            apply()
            guard let window else { return }
            // Once SwiftUI has placed its initial focus.
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
        private func apply() {
            guard let window else { return }
            // The window follows its content controller's title, so set that too.
            window.contentViewController?.title = title
            window.title = title
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.title = title
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) { anchor.title = title }
}

// MARK: Shared pieces

/// A label whose symbol sits in a fixed-width column, so titles start at the same x on every row
/// whatever the symbol's own width.
struct IconColumnLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .frame(width: 22, alignment: .center)
            configuration.title
        }
    }
}

extension View {
    /// A settings page: grouped form whose content fades under the window toolbar instead of
    /// running into the title.
    func toolchestFormPage() -> some View {
        self.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Brand.ground.color)
            .listRowBackground(Brand.surface.color)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

/// How a row that belongs to a feature looks: indented under it, and dimmed and inert while the
/// feature is off, the same for every kind of row.
private struct ChildRow: ViewModifier {
    let enabled: Bool
    let indented: Bool
    /// Already dimmed from above (a module that is off): dimming again would stack.
    @Environment(\.isEnabled) private var parentEnabled

    func body(content: Content) -> some View {
        content
            .padding(.leading, indented ? 18 : 0)
            .disabled(!enabled)
            .opacity(enabled || !parentEnabled ? 1 : 0.5)
    }
}

extension View {
    func childRow(of enabled: Bool = true, indented: Bool = true) -> some View {
        modifier(ChildRow(enabled: enabled, indented: indented))
    }
}

struct PageHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    let summary: String
    /// The app's own icon in place of a symbol (the General page).
    var showsAppIcon = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if showsAppIcon {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.toolchestText)
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.font(20, .light))
                Text(summary)
                    .font(Brand.font(12))
                    .foregroundStyle(.toolchestSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 6)
    }
}

/// A feature switch with a one-line explanation.
struct FeatureToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    /// False under a module (or feature) that is off: the switch then reads off, because nothing
    /// it controls is active. Its saved choice comes back when the parent is switched on.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Toggle(isOn: SafeBinding.gated(isEnabled: isEnabled, isOn: $isOn)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HotkeyRow: View {
    let action: HotkeyAction
    let controller: AppController
    var enabled = true
    var label = "Shortcut"

    var body: some View {
        LabeledContent {
            HotkeyRecorder(name: action.title, combo: controller.prefs.comboBinding(action), controller: controller)
        } label: {
            Text(label).foregroundStyle(.toolchestSecondary)
        }
        .childRow(of: enabled)
    }
}

struct PermissionStatusRow: View {
    enum Style { case plain, card }

    let permission: Permission
    let controller: AppController
    var style = Style.plain

    @State private var state: PermissionState
    @State private var openSettings: Bool

    init(permission: Permission, controller: AppController, style: Style = .plain) {
        self.permission = permission
        self.controller = controller
        self.style = style
        _state = State(initialValue: Permissions.state(permission))
        _openSettings = State(initialValue: Permissions.shouldOpenSettings(permission))
    }

    /// Mail is only asked while it is open: Toolchest never starts it.
    private var waitingForApp: Bool { state == .unknown && permission == .automationMail }

    var body: some View {
        let _ = controller.permissionsToken
        HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22)
                .foregroundStyle(state == .granted ? Color.toolchestText : .toolchestSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(waitingForApp ? "Open Mail first, then allow it here. Toolchest never starts Mail itself." : permission.reason)
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // One column on the trailing edge: the status on top, the button under it. Every
            // status then ends at the same edge, whether or not a button sits beside it.
            VStack(alignment: .trailing, spacing: 6) {
                if state == .granted || waitingForApp { StatusLabel(state: state) }
                if state != .granted && !waitingForApp {
                    PillButton(title: openSettings ? "Open System Settings" : "Allow…", prominent: false) {
                        Permissions.request(permission)
                        refreshSoon()
                    }
                    .accessibilityLabel(openSettings ? "Open System Settings for \(permission.title)" : "Request \(permission.title)")
                }
            }
        }
        .padding(style == .card ? 12 : 0)
        .accessibilityElement(children: .contain)
        .task {
            // Live status: the row follows the system for as long as it is on screen, with no relaunch.
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refresh() {
        let now = Permissions.state(permission)
        if now != state {
            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { state = now }
            if now == .granted {
                Haptics.play(.tick)
                announce("\(permission.title) allowed")
                controller.permissionsToken += 1
            }
        }
        let shouldOpen = Permissions.shouldOpenSettings(permission)
        if shouldOpen != openSettings { openSettings = shouldOpen }
    }

    private func refreshSoon() {
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refresh() }
        }
    }
}

/// A permission's state as plain text with a symbol, never a capsule: it is a fact, and the
/// button beside it is the only thing on the row that looks pressable. Only a refusal is a
/// warning; "not asked yet" and "app is closed" are neutral.
struct StatusLabel: View {
    let state: PermissionState

    /// Granted and refused read at full strength, with different words and symbols; the two
    /// states that wait on nothing the user did wrong read quieter.
    private var content: (text: String, symbol: String, strong: Bool) {
        switch state {
        case .granted: ("Allowed", "checkmark", true)
        case .denied: ("Not allowed yet", "exclamationmark.circle", true)
        case .notDetermined: ("Not asked yet", "circle.dashed", false)
        case .unknown: ("App is closed", "moon.zzz", false)
        }
    }

    var body: some View {
        let (text, symbol, strong) = content
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .contentTransition(.symbolEffect(.replace))
        }
        .font(Brand.font(12))
        .foregroundStyle(strong ? Color.toolchestText : .toolchestSecondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(text)")
    }
}

// MARK: General

struct GeneralPage: View {
    let controller: AppController
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                PageHeader(symbol: "slider.horizontal.3", title: "Toolchest",
                           summary: "Power tools for the Mac. Each module can be switched on and off on its own.",
                           showsAppIcon: true) {
                    Text(AppInfo.version)
                        .font(Brand.font(11))
                        .foregroundStyle(.toolchestSecondary)
                }
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LoginItem.set(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if LoginItem.needsApproval {
                    LabeledContent("macOS wants your approval in Login Items.") {
                        Button("Open Login Items") { LoginItem.openSettings() }.toolchestGlassButton()
                    }
                }
                if let loginError {
                    Text(loginError).font(Brand.font(11)).foregroundStyle(Brand.error)
                }
            }
            Section("Feel") {
                FeatureToggle(title: "Haptic feedback", detail: "A light tap on the Force Touch trackpad when a guarded quit commits, a shortcut is recorded, or a region is picked. Only felt while your finger is on the trackpad.",
                              isOn: controller.s.general.haptics)
            }
            Section("Shortcuts, Focus and Control Center") {
                Label("Every Toolchest action is in the Shortcuts app and Spotlight, and Siri knows the main ones.", systemImage: "square.2.layers.3d")
                    .font(Brand.font(12))
                Label("Add a Toolchest filter to a Focus (System Settings > Focus) to mute the mic, guard ⌘Q or keep the Mac awake while it’s on.", systemImage: "moon.circle")
                    .font(Brand.font(12))
                Label("Add Toolchest’s controls to Control Center or the menu bar, and its widgets to the desktop.", systemImage: "switch.2")
                    .font(Brand.font(12))
            }
            .labelStyle(IconColumnLabelStyle())
            Section("Modules") {
                ForEach(Module.allCases) { module in
                    Toggle(isOn: controller.prefs.moduleBinding(module)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(module.title)
                                Text(module.summary).font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                            }
                        } icon: {
                            Image(systemName: module.symbol)
                        }
                        .labelStyle(IconColumnLabelStyle())
                    }
                }
            }
            if controller.tapUnavailable || !controller.refusedHotkeys.isEmpty {
                Section("Needs attention") {
                    if controller.tapUnavailable {
                        Label("Some features are on but Toolchest doesn’t have Accessibility, so they are paused.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.toolchestText)
                        PermissionStatusRow(permission: .accessibility, controller: controller)
                    }
                    if !controller.refusedHotkeys.isEmpty {
                        Label("Another app already uses the shortcut for: " + controller.refusedHotkeys.joined(separator: ", "),
                              systemImage: "keyboard.badge.exclamationmark")
                            .foregroundStyle(.toolchestText)
                    }
                }
            }
            Section("Privacy") {
                Label("Toolchest never records keystrokes or clipboard contents. It only watches for the few shortcuts you turn on, and all text recognition and translation run on this Mac.",
                      systemImage: "hand.raised")
                    .font(Brand.font(12))
                    .foregroundStyle(.toolchestSecondary)
            }
        }
        .toolchestFormPage()
    }
}

// MARK: About

/// What this copy is and how to use it. Help opens this page.
struct AboutPage: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toolchest").font(Brand.font(22, .light))
                        Text(AppInfo.version).foregroundStyle(.toolchestSecondary)
                        Text(AboutView.tagline).foregroundStyle(.toolchestSecondary)
                        Text(AboutView.copyright).font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section("Using Toolchest") {
                LabeledContent("Switch on a module", value: "Settings > the module")
                LabeledContent("Run a tool", value: "The menu bar icon, or its hotkey")
                LabeledContent("Add it to a Focus", value: "System Settings > Focus")
                LabeledContent("Settings", value: "Open Toolchest from Finder or Spotlight")
            }
        }
        .toolchestFormPage()
    }
}

// MARK: Permissions

struct PermissionsPage: View {
    let controller: AppController

    var body: some View {
        Form {
            Section {
                PageHeader(symbol: "hand.raised", title: "Permissions",
                           summary: "Toolchest asks only for what the modules you turn on need. Press Allow… and macOS asks for you; if you said no before, the button opens the right System Settings pane.") {
                    Button("Refresh") { controller.permissionsToken += 1 }.toolchestGlassButton()
                }
            }
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionStatusRow(permission: permission, controller: controller)
                }
            }
            Section {
                Text("Automation access can only be checked while the other app is open.")
                    .font(Brand.font(11))
                    .foregroundStyle(.toolchestSecondary)
            }
            Section {
                LabeledContent {
                    Button("Show Again") { controller.resetOnboarding() }
                        .toolchestGlassButton()
                        .accessibilityHint("Shows the welcome window again and lets Toolchest ask macOS for each permission again.")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome window")
                        Text("Show the first-run window again.")
                            .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                    }
                }
            }
        }
        .toolchestFormPage()
    }
}

// MARK: Modules

struct ModulePage: View {
    let module: Module
    let controller: AppController

    private var enabled: Binding<Bool> {
        controller.prefs.moduleBinding(module)
    }

    var body: some View {
        Form {
            Section {
                PageHeader(symbol: module.symbol, title: module.title, summary: module.summary) {
                    Toggle("On", isOn: enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("\(module.title) module")
                }
            }
            Group {
                switch module {
                case .finder: FinderPage(controller: controller)
                case .windows: WindowsPage(controller: controller)
                case .keyboard: KeyboardPage(controller: controller)
                case .screen: ScreenPage(controller: controller)
                case .audio: AudioPage(controller: controller)
                case .utilities: UtilitiesPage(controller: controller)
                case .links: LinksPage(controller: controller)
                }
            }
            .disabled(!controller.settings.isEnabled(module))
            .opacity(controller.settings.isEnabled(module) ? 1 : 0.55)
        }
        .toolchestFormPage()
        .animation(reduceMotionAnimation, value: controller.settings.isEnabled(module))
        .onChange(of: controller.settings.isEnabled(module)) { Haptics.play(.tick) }
    }

    private var reduceMotionAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)
    }
}

private extension AppController {
    var s: Binding<Settings> {
        prefs.settingsBinding
    }
}

struct FinderPage: View {
    let controller: AppController

    var body: some View {
        let s = controller.s
        Section("Keyboard") {
            FeatureToggle(title: "Cut and paste files", detail: "⌘X then ⌘V moves files. Only in Finder’s file list, never in a text field.",
                          isOn: s.finder.cutPaste)
            FeatureToggle(title: "Return opens, F2 renames", detail: "Return opens the selection like ⌘↓. Rename moves to F2 (fn-F2 on Mac keyboards).",
                          isOn: s.finder.returnOpens)
            FeatureToggle(title: "Reopen closed window", detail: "⇧⌘T reopens the last closed Finder window or tab. This replaces Finder’s Show Tab Bar shortcut.",
                          isOn: s.finder.reopenClosed)
            FeatureToggle(title: "New text file", detail: "⌥N creates “untitled.txt” in the current folder and starts renaming it.",
                          isOn: s.finder.newTextFile)
            FeatureToggle(title: "Paste image or text as a file", detail: "⌘V with an image or text (and no files) on the clipboard saves it as a file.",
                          isOn: s.finder.pasteAsFile)
        }
        Section("Context menu") {
            let _ = controller.permissionsToken
            FeatureToggle(title: "Right-click extras", detail: "Copy Path, Open in \(KeyboardModule.terminalName), VS Code, templates, Move To, Copy To, color tags, Name by Content, SHA-256 and Remove Photo Location. Toolchest only acts on items selected in Finder.",
                          isOn: s.finder.rightClickExtras)
            LabeledContent {
                Button(FinderModule.extensionEnabled ? "Manage…" : "Turn On…") {
                    FinderModule.manageExtension()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { controller.permissionsToken += 1 }
                }
                .toolchestGlassButton()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finder extension")
                    Text(FinderModule.extensionEnabled ? "On. Right-click files for Copy Path, Open in \(KeyboardModule.terminalName), checksums and more."
                        : "Off. Click Turn On and switch on Toolchest Finder Extras in the list macOS shows.")
                        .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                }
            }
            .childRow(of: controller.settings.finder.rightClickExtras)
            LabeledContent("Templates for New File from Template") {
                Button("Open Folder") {
                    _ = FinderModule.ensureTemplates()
                    NSWorkspace.shared.open(FinderModule.templatesFolder)
                }
                .toolchestGlassButton()
            }
            .childRow(of: controller.settings.finder.rightClickExtras)
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
            PermissionStatusRow(permission: .automationFinder, controller: controller)
        }
    }
}

struct WindowsPage: View {
    let controller: AppController

    var body: some View {
        let s = controller.s
        Section("Quit guard") {
            FeatureToggle(title: "Hold ⌘Q to quit", detail: "Hold for a moment (a ring fills next to the pointer) or press twice. Finder is exempt.",
                          isOn: s.windows.quitGuard)
            LabeledContent("Hold for") {
                HStack {
                    Slider(value: s.windows.holdDuration, in: 0.3...1.5, step: 0.1).frame(width: 180)
                    Text(String(format: "%.1f s", controller.settings.windows.holdDuration)).monospacedDigit().frame(width: 44)
                }
            }
            .childRow(of: controller.settings.windows.quitGuard)
            AppListEditor(title: "Also guard ⌘W in", bundleIDs: s.windows.closeGuardBundleIDs)
                .childRow(of: controller.settings.windows.quitGuard)
        }
        Section("Windows") {
            FeatureToggle(title: "Isolate window", detail: "A shortcut hides every other app.", isOn: s.windows.isolate)
            HotkeyRow(action: .isolate, controller: controller, enabled: controller.settings.windows.isolate)
            FeatureToggle(title: "Green button fills the screen", detail: "Click it to fill the screen (click again to restore). ⌥-click still enters full screen.",
                          isOn: s.windows.greenFill)
        }
        Section("Dock") {
            FeatureToggle(title: "Click the active app’s icon", detail: "Choose what clicking the Dock icon of the app you’re already in does.", isOn: s.windows.dockClick)
            Picker("Action", selection: s.windows.dockClickAction) {
                ForEach(DockClickAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .childRow(of: controller.settings.windows.dockClick)
            FeatureToggle(title: "Middle-click quits", detail: "Middle-click a Dock icon and hold (or click twice) to quit that app.",
                          isOn: s.windows.dockMiddleQuit)
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
        }
    }
}

/// A row of a list the user adds apps to: click selects it, and the bar under the list removes it
/// (so removing never sits next to a control that clears something else). A context menu and a
/// VoiceOver action do the same.
struct SelectableAppRow<Content: View>: View {
    let name: String
    let selected: Bool
    let select: () -> Void
    let remove: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(selected ? Brand.selection.color : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
            .onTapGesture(perform: select)
            .contextMenu { Button("Remove \(name)", role: .destructive, action: remove) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: "Select", select)
            .accessibilityAction(named: "Remove", remove)
    }
}

/// The bar under an app list, like the + and − bar under a macOS list: add and remove at the
/// bottom left, and an optional note beside them.
struct AppListBar<Note: View>: View {
    let selectedName: String?
    let add: () -> Void
    let remove: () -> Void
    @ViewBuilder let note: Note

    var body: some View {
        HStack(spacing: 8) {
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 16)
            }
            .toolchestGlassButton()
            .help("Add an app")
            .accessibilityLabel("Add app")
            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 16)
            }
            .toolchestGlassButton()
            .disabled(selectedName == nil)
            .help(selectedName.map { "Remove \($0)" } ?? "Select an app to remove it")
            .accessibilityLabel(selectedName.map { "Remove \($0)" } ?? "Remove selected app")
            note
                .padding(.leading, 4)
            Spacer(minLength: 0)
        }
    }
}

/// What an app list shows while it has no apps.
struct AppListEmpty: View {
    var body: some View {
        Text("No apps")
            .font(Brand.font(11))
            .foregroundStyle(.toolchestSecondary)
    }
}

/// A list of apps chosen from /Applications.
struct AppListEditor: View {
    let title: String
    @Binding var bundleIDs: [String]
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            if bundleIDs.isEmpty { AppListEmpty() }
            ForEach(bundleIDs, id: \.self) { id in
                SelectableAppRow(name: AppIcon.name(for: id), selected: selection == id,
                                 select: { selection = id }, remove: { remove(id) }) {
                    HStack(spacing: 8) {
                        AppIcon(bundleID: id)
                        Text(AppIcon.name(for: id))
                        Spacer()
                    }
                }
            }
            AppListBar(selectedName: selection.map(AppIcon.name(for:)), add: add,
                       remove: { if let selection { remove(selection) } }) { EmptyView() }
        }
    }

    private func remove(_ id: String) {
        bundleIDs.removeAll { $0 == id }
        if selection == id { selection = nil }
    }

    private func add() {
        guard let bundleID = AppIcon.chooseApp()?.bundleID, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
        selection = bundleID
    }
}

struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @MainActor
    static func chooseApp() -> (bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return nil }
        return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
}

struct KeyboardPage: View {
    let controller: AppController
    @State private var inspectCombo: KeyCombo?
    @State private var matches: [ShortcutInspector.Match] = []
    @State private var inspecting = false
    @State private var inspected = false
    @State private var selectedApp: String?

    private func removeApp(_ bundleID: String) {
        controller.prefs.settings.keyboard.appHotkeys.removeAll { $0.bundleID == bundleID }
        if selectedApp == bundleID { selectedApp = nil }
    }

    private func addApp() {
        guard let chosen = AppIcon.chooseApp(),
              !controller.settings.keyboard.appHotkeys.contains(where: { $0.bundleID == chosen.bundleID }) else { return }
        controller.prefs.settings.keyboard.appHotkeys.append(AppHotkey(bundleID: chosen.bundleID, name: chosen.name, combo: nil))
        selectedApp = chosen.bundleID
    }

    var body: some View {
        let s = controller.s
        Section("Hyper key") {
            FeatureToggle(title: "Caps Lock is Hyper", detail: "Caps Lock acts as ⌃⌥⇧⌘ held together, for shortcuts no app uses. Caps Lock itself stops toggling capitals.",
                          isOn: s.keyboard.hyper)
            FeatureToggle(title: "Tap for Escape", detail: "A quick tap of Caps Lock on its own sends Esc.", isOn: s.keyboard.hyperEscOnTap)
                .childRow(of: controller.settings.keyboard.hyper)
        }
        Section("App hotkeys") {
            if controller.settings.keyboard.appHotkeys.isEmpty { AppListEmpty() }
            ForEach(controller.settings.keyboard.appHotkeys) { app in
                SelectableAppRow(name: app.name, selected: selectedApp == app.bundleID,
                                 select: { selectedApp = app.bundleID }, remove: { removeApp(app.bundleID) }) {
                    LabeledContent {
                        HotkeyRecorder(name: "Open \(app.name)", combo: controller.prefs.appHotkeyBinding(bundleID: app.bundleID), controller: controller)
                    } label: {
                        HStack(spacing: 8) {
                            AppIcon(bundleID: app.bundleID)
                            Text(app.name)
                        }
                    }
                }
            }
            AppListBar(selectedName: controller.settings.keyboard.appHotkeys.first { $0.bundleID == selectedApp }?.name,
                       add: addApp, remove: { if let selectedApp { removeApp(selectedApp) } }) {
                Text("Press the key to open or focus the app; press it again to hide it.")
                    .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Drop-down windows") {
            FeatureToggle(title: "Drop-down Finder", detail: "A Finder window slides down from the top of the screen; press again to hide it.",
                          isOn: s.keyboard.dropdownFinder)
            HotkeyRow(action: .dropdownFinder, controller: controller, enabled: controller.settings.keyboard.dropdownFinder)
            FeatureToggle(title: "Drop-down terminal", detail: "The same for \(KeyboardModule.terminalName).",
                          isOn: s.keyboard.dropdownTerminal)
            HotkeyRow(action: .dropdownTerminal, controller: controller, enabled: controller.settings.keyboard.dropdownTerminal)
            // Not a child of either switch: it sets the height of both drop-downs.
            LabeledContent {
                HStack {
                    Slider(value: s.keyboard.dropdownHeight, in: 0.25...0.9, step: 0.05).frame(width: 180)
                    Text("\(Int(controller.settings.keyboard.dropdownHeight * 100))%").monospacedDigit().frame(width: 44)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Height")
                    Text("For both drop-down windows.")
                        .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                }
            }
            .childRow(of: controller.settings.keyboard.dropdownFinder || controller.settings.keyboard.dropdownTerminal, indented: false)
        }
        Section("Shortcut Inspector") {
            LabeledContent {
                HStack {
                    HotkeyRecorder(name: "Inspector", combo: $inspectCombo, controller: controller, showConflicts: true)
                    Button(inspecting ? "Looking…" : "Find") {
                        guard let combo = inspectCombo else { return }
                        inspecting = true
                        Task {
                            matches = await ShortcutInspector.inspect(combo)
                            inspecting = false
                            inspected = true
                        }
                    }
                    .toolchestGlassButton(prominent: true)
                    .disabled(inspectCombo == nil || inspecting)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Which app uses a shortcut?")
                    Text("Reads the menus of every running app. It can’t see shortcuts an app handles without a menu item.")
                        .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
                }
            }
            if inspected {
                if matches.isEmpty {
                    Text("No running app has a menu item with this shortcut.")
                        .font(Brand.font(12)).foregroundStyle(.toolchestSecondary)
                } else {
                    ForEach(matches) { match in
                        LabeledContent(match.app) {
                            Text(match.path).font(Brand.font(12)).foregroundStyle(.toolchestSecondary)
                        }
                    }
                }
            }
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
        }
    }
}

struct ScreenPage: View {
    let controller: AppController

    static let languages: [(String, String)] = [
        ("", "System language"), ("en", "English"), ("de", "German"), ("fa", "Persian"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("tr", "Turkish"), ("ar", "Arabic"), ("ru", "Russian"),
        ("uk", "Ukrainian"), ("pl", "Polish"), ("zh-Hans", "Chinese (Simplified)"), ("ja", "Japanese"), ("ko", "Korean"),
    ]

    var body: some View {
        let s = controller.s
        Section("Text") {
            FeatureToggle(title: "Capture Text", detail: "Select any region (including images and PDFs) and its text is copied.", isOn: s.screen.captureText)
            HotkeyRow(action: .captureText, controller: controller, enabled: controller.settings.screen.captureText)
            FeatureToggle(title: "Tidy captured text", detail: "Joins lines broken mid-sentence, removes line-end hyphens and extra spaces. Plain rules, no AI: words are never changed.",
                          isOn: s.screen.cleanUpText)
                .childRow(of: controller.settings.screen.captureText)
            FeatureToggle(title: "Capture and Translate", detail: "Translate the text in a region on this Mac with Apple’s Translation.", isOn: s.screen.translate)
            HotkeyRow(action: .translate, controller: controller, enabled: controller.settings.screen.translate)
            Picker("Translate into", selection: s.screen.translateTarget) {
                ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .childRow(of: controller.settings.screen.translate)
        }
        Section("Apple Intelligence") {
            FeatureToggle(title: "Capture and Summarize", detail: "Shows an Apple Intelligence summary next to the exact text. The summary is model output and may be wrong; it’s never copied for you.", isOn: s.screen.summarize)
            HotkeyRow(action: .summarize, controller: controller, enabled: controller.settings.screen.summarize)
            if let reason = Intelligence.unavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
            } else {
                Label("Runs on this Mac. Nothing is sent anywhere.", systemImage: "lock")
                    .font(Brand.font(11)).foregroundStyle(.toolchestSecondary)
            }
        }
        Section("Codes") {
            FeatureToggle(title: "Scan QR codes and barcodes", detail: "From a screen region or the clipboard image. Links are shown before anything opens.",
                          isOn: s.screen.scanCode)
            HotkeyRow(action: .scanCode, controller: controller, enabled: controller.settings.screen.scanCode)
        }
        Section("Color") {
            FeatureToggle(title: "Color Picker", detail: "Pick any pixel on screen and copy its value.", isOn: s.screen.colorPicker)
            HotkeyRow(action: .pickColor, controller: controller, enabled: controller.settings.screen.colorPicker)
            Picker("Copy as", selection: s.screen.colorFormat) {
                ForEach(ColorFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .childRow(of: controller.settings.screen.colorPicker)
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .screenRecording, controller: controller)
        }
    }
}

struct AudioPage: View {
    let controller: AppController

    var body: some View {
        let s = controller.s
        Section("Music") {
            FeatureToggle(title: "Music stays shut", detail: "Closes Music when a media key or headphones open it by themselves. Opening it yourself still works.",
                          isOn: s.audio.musicGuard)
        }
        Section("Microphone") {
            FeatureToggle(title: "Mic mute", detail: "A shortcut and a menu bar indicator mute the current input device.", isOn: s.audio.micMute)
            HotkeyRow(action: .micMute, controller: controller, enabled: controller.settings.audio.micMute)
            FeatureToggle(title: "Mute while typing in a call", detail: "While the mic is in use, typing mutes it until you stop.",
                          isOn: s.audio.autoMuteTyping)
                .childRow(of: controller.settings.audio.micMute)
        }
        Section("Devices") {
            FeatureToggle(title: "Switch devices with a shortcut", detail: "Cycle through outputs or inputs; a glass HUD shows the new device.",
                          isOn: s.audio.deviceSwitch)
            HotkeyRow(action: .cycleOutput, controller: controller, enabled: controller.settings.audio.deviceSwitch, label: "Next output")
            HotkeyRow(action: .cycleInput, controller: controller, enabled: controller.settings.audio.deviceSwitch, label: "Next input")
        }
        Section("Volume") {
            FeatureToggle(title: "Cap volume after wake", detail: "If the Mac wakes louder than this, the volume is turned down.", isOn: s.audio.volumeCap)
            LabeledContent("Maximum") {
                HStack {
                    Slider(value: s.audio.volumeCapLevel, in: 0.1...1, step: 0.05).frame(width: 180)
                    Text("\(Int(controller.settings.audio.volumeCapLevel * 100))%").monospacedDigit().frame(width: 44)
                }
            }
            .childRow(of: controller.settings.audio.volumeCap)
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
        }
    }
}

struct UtilitiesPage: View {
    let controller: AppController

    static let ages: [(Double, String)] = [(30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes")]

    var body: some View {
        let s = controller.s
        Section("Sleep") {
            FeatureToggle(title: "Keep Awake", detail: "Stops the Mac and display sleeping, for a set time, from the menu bar.", isOn: s.utilities.keepAwake)
            HotkeyRow(action: .keepAwake, controller: controller, enabled: controller.settings.utilities.keepAwake)
        }
        Section("Cleaning") {
            FeatureToggle(title: "Cleaning Mode", detail: "Blacks out every screen and pauses keyboard and trackpad. Hold Esc for 2 seconds to leave; it always ends after 60 seconds.",
                          isOn: s.utilities.cleaning)
            HotkeyRow(action: .cleaning, controller: controller, enabled: controller.settings.utilities.cleaning)
        }
        Section("Quick toggles") {
            FeatureToggle(title: "Dark Mode and desktop icons", detail: "Switch Dark Mode and show or hide desktop icons from the menu bar.",
                          isOn: s.utilities.toggles)
            HotkeyRow(action: .darkMode, controller: controller, enabled: controller.settings.utilities.toggles)
        }
        Section("Clipboard") {
            FeatureToggle(title: "Clear the clipboard", detail: "Clears what you copied after a while, and when the Mac sleeps or locks. Never while you’re pasting.",
                          isOn: s.utilities.clipboardClear)
            Picker("After", selection: s.utilities.clipboardAge) {
                ForEach(Self.ages, id: \.0) { Text($0.1).tag($0.0) }
            }
            .childRow(of: controller.settings.utilities.clipboardClear)
        }
        Section("Notifications") {
            FeatureToggle(title: "Notification shortcuts", detail: "Clear all notifications or open the top one. Works on notifications currently on screen.",
                          isOn: s.utilities.notifications)
            HotkeyRow(action: .clearNotifications, controller: controller, enabled: controller.settings.utilities.notifications, label: "Clear all")
            HotkeyRow(action: .openNotification, controller: controller, enabled: controller.settings.utilities.notifications, label: "Open the top one")
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
            PermissionStatusRow(permission: .automationSystemEvents, controller: controller)
        }
    }
}

struct LinksPage: View {
    let controller: AppController

    var body: some View {
        let s = controller.s
        Section("Mail") {
            FeatureToggle(title: "Copy message link", detail: "Copies a message:// link to the selected Mail message. Opening it jumps to that message.",
                          isOn: s.links.mailLink)
            HotkeyRow(action: .mailLink, controller: controller, enabled: controller.settings.links.mailLink)
        }
        Section("Notes") {
            FeatureToggle(title: "Copy note link", detail: "Uses Notes’ own Copy Link command for the selected note, when Notes offers one.",
                          isOn: s.links.noteLink)
            HotkeyRow(action: .noteLink, controller: controller, enabled: controller.settings.links.noteLink)
        }
        Section("Permissions") {
            PermissionStatusRow(permission: .accessibility, controller: controller)
            PermissionStatusRow(permission: .automationMail, controller: controller)
        }
    }
}
