import AppKit
import SwiftUI
import Translation

struct ScannedCode: Identifiable, Equatable, Sendable {
    let id = UUID()
    let payload: String
    let symbology: String

    /// Only web links get an Open button; anything else can be copied but not opened.
    var openableURL: URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

@MainActor
@Observable
final class ResultModel {
    enum Kind { case translation, codes, summary }
    enum Phase: Equatable { case working, done, failed(String) }

    var kind = Kind.translation
    var phase = Phase.working
    var original = ""
    var translated = ""
    var sourceName = ""
    var targetName = ""
    var codes: [ScannedCode] = []
    var configuration: TranslationSession.Configuration?
    var copiedToken = 0
    var onClose: () -> Void = {}

    /// "German → English", or plain "Translate" when there is no pair to show. A text that is
    /// already in the target language has no pair: "English → English" says nothing.
    var translationTitle: String {
        sourceName.isEmpty || sourceName == targetName ? "Translate" : "\(sourceName) → \(targetName)"
    }
}

struct ResultView: View {
    @Bindable var model: ResultModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.kind {
            case .translation, .summary: translation
            case .codes: codes
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
        .flatCard(in: .rect(cornerRadius: 22))
        .padding(16)
        .toolchestSurface()
        .translationTask(model.configuration) { session in
            await runDownloadedTranslation(session)
        }
        .onExitCommand { model.onClose() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.kind == .translation ? "translate" : model.kind == .summary ? "text.append" : "qrcode.viewfinder")
                .font(.system(size: 17, weight: .regular))
                .symbolRenderingMode(.monochrome)
            Text(title)
                .font(Brand.font(14, .medium))
            Spacer()
            Button(action: model.onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    private var title: String {
        switch model.kind {
        case .translation:
            model.translationTitle
        case .codes:
            model.codes.count == 1 ? "1 code found" : "\(model.codes.count) codes found"
        case .summary:
            "Apple Intelligence summary"
        }
    }

    private var isSummary: Bool { model.kind == .summary }

    /// A small caption over a block of text. Both blocks of a summary carry one, so the exact
    /// text is never mistaken for the model's answer.
    private func caption(_ text: String, symbol: String? = nil) -> some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(Brand.font(11, .medium))
        .foregroundStyle(.toolchestSecondary)
    }

    @ViewBuilder private var translation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSummary { caption("Exact text", symbol: "text.quote") }
            FittingScroll(maxHeight: 90, long: model.original.count > 280) {
                Text(model.original)
                    // A summary's source is the thing to check against, so it reads at full strength;
                    // a translation's source is context for the result below.
                    .font(Brand.font(isSummary ? 14 : 12))
                    .foregroundStyle(isSummary ? Color.toolchestText : .toolchestSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Rectangle().fill(Brand.divider.color).frame(height: 1)
        if isSummary {
            caption("Summary, model output", symbol: "text.append")
            Text("It may leave things out or get them wrong. Check it against the exact text above.")
                .font(Brand.font(11))
                .foregroundStyle(.toolchestSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch model.phase {
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isSummary ? "Summarizing on this Mac…" : "Translating on this Mac…")
                    .font(Brand.font(13)).foregroundStyle(.toolchestSecondary)
            }
            // The summary streams in while the model writes it.
            if !model.translated.isEmpty { resultText }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Brand.font(13))
                .foregroundStyle(.toolchestSecondary)
        case .done:
            resultText
            HStack {
                Spacer()
                if isSummary {
                    // Two equal choices: neither is the default, and ⌘C belongs to whatever text
                    // is selected, so neither button claims it.
                    Button {
                        copy(model.original)
                    } label: {
                        Label("Copy Exact Text", systemImage: "text.quote")
                    }
                    .buttonStyle(.glass)
                    Button {
                        copy(model.translated)
                    } label: {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        copy(model.translated)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("c", modifiers: .command)
                }
            }
        }
    }

    private var resultText: some View {
        FittingScroll(maxHeight: 220, long: model.translated.count > 600) {
            Text(model.translated)
                .font(Brand.font(isSummary ? 14 : 15))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.codes) { code in
                VStack(alignment: .leading, spacing: 8) {
                    Text(code.symbology)
                        .font(Brand.font(11, .medium))
                        .foregroundStyle(.toolchestSecondary)
                    Text(code.payload)
                        .font(code.openableURL == nil ? Brand.font(13) : .system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Spacer()
                        Button {
                            copy(code.payload)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)
                        if let url = code.openableURL {
                            Button {
                                NSWorkspace.shared.open(url)
                                model.onClose()
                            } label: {
                                Label("Open \(url.host ?? "link")", systemImage: "safari")
                            }
                            .buttonStyle(.glassProminent)
                            .accessibilityHint("Opens \(url.absoluteString) in your browser")
                        }
                    }
                }
                .padding(12)
                .background(Brand.surface.color, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.divider.color, lineWidth: 1))
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.copiedToken += 1
        announce("Copied")
    }

    /// Used when the language pair still has to be downloaded: the system shows its download sheet.
    private func runDownloadedTranslation(_ session: TranslationSession) async {
        // The session is handed to this task by SwiftUI and used only here, one call at a time.
        nonisolated(unsafe) let session = session
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(model.original)
            model.translated = response.targetText
            model.phase = .done
        } catch {
            model.phase = .failed("Translation isn’t available: \(error.localizedDescription)")
        }
    }
}

/// Shows short text as is and scrolls only long text, so short results don't sit in an empty box.
struct FittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    var long = false
    @ViewBuilder let content: Content

    var body: some View {
        if long {
            ScrollView { content }.frame(maxHeight: maxHeight)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A floating panel for translation and code results. It takes focus so text can be
/// selected and copied, and closes on Esc, its close button, or when it loses focus.
@MainActor
final class ResultPanel: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }

        /// ⌘C copies the text the user selected, if any, before it can fire a Copy button. Toolchest
        /// has no Edit menu while only this panel is open, so nothing else would deliver it.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "c", let responder = firstResponder {
                let before = NSPasteboard.general.changeCount
                // With nothing selected, copy does nothing and the pasteboard stays as it was.
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: responder, from: self),
                   NSPasteboard.general.changeCount != before {
                    return true
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private var panel: NSPanel?
    let model = ResultModel()

    func show() {
        model.onClose = { [weak self] in self?.close() }
        let panel = self.panel ?? {
            let panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 472, height: 300),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            let host = NSHostingView(rootView: ResultView(model: model))
            host.sizingOptions = [.preferredContentSize]
            panel.contentView = host
            self.panel = panel
            return panel
        }()
        if let screen = screenUnderMouse {
            // The hosting view has no size until it lays out once; a zero fitting size would hide the panel.
            panel.contentView?.layoutSubtreeIfNeeded()
            var size = panel.contentView?.fittingSize ?? .zero
            if size.width < 100 || size.height < 60 { size = CGSize(width: 472, height: 300) }
            panel.setFrame(CGRect(x: screen.visibleFrame.midX - size.width / 2,
                                  y: screen.visibleFrame.midY - size.height / 2 + screen.visibleFrame.height * 0.12,
                                  width: size.width, height: size.height), display: true)
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        model.configuration = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // The system's language download prompt takes focus; closing then would cancel the download.
        if model.configuration != nil && model.phase == .working { return }
        if panel?.attachedSheet != nil { return }
        close()
    }
}
