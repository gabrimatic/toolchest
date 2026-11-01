import AppKit
import NaturalLanguage
import ScreenCaptureKit
import Translation
import Vision

/// Capture Text, Capture and Translate, code scanning and the color picker.
@MainActor
final class ScreenModule {
    var settings = ScreenSettings()
    private let selector = RegionSelector()
    private let results = ResultPanel()
    private var busy = false
    /// The system color sampler, held until it answers (a sampler that is released early cancels).
    private var sampler: NSColorSampler?

    // MARK: Capture

    private func captureRegion(title: String, symbol: String) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            NeedsAccess.shared.present(.screenRecording, for: title)
            return nil
        }
        guard let rect = await selector.select(title: title, symbol: symbol) else { return nil }
        // Let the window server take the selection overlay off screen before capturing.
        try? await Task.sleep(for: .milliseconds(120))
        do {
            return try await SCScreenshotManager.captureImage(in: rect)
        } catch {
            HUD.shared.error("Capture failed", error.localizedDescription)
            return nil
        }
    }

    private func guarded(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await work()
            busy = false
        }
    }

    // MARK: Capture Text

    func captureText() {
        guarded { [self] in
            guard let image = await captureRegion(title: "Capture Text", symbol: "text.viewfinder") else { return }
            var text = await Self.recognizeText(in: image)
            guard !text.isEmpty else {
                HUD.shared.show("text.magnifyingglass", "No text found")
                return
            }
            if settings.cleanUpText { text = TextReflow.reflow(text) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.split(separator: "\n").count
            HUD.shared.show("doc.on.clipboard.fill", "Text copied", detail: lines == 1 ? "1 line" : "\(lines) lines")
        }
    }

    /// Accurate, language-detecting OCR. Lines come back in reading order, top to bottom.
    nonisolated static func recognizeText(in image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return "" }
        let lines = observations
            .sorted { a, b in
                let ay = a.boundingBox.cgRect.midY, by = b.boundingBox.cgRect.midY
                if abs(ay - by) > 0.01 { return ay > by }
                return a.boundingBox.cgRect.minX < b.boundingBox.cgRect.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Summarize

    func captureAndSummarize() {
        guarded { [self] in
            guard let image = await captureRegion(title: "Capture and Summarize", symbol: "text.append") else { return }
            let text = await Self.recognizeText(in: image)
            guard !text.isEmpty else {
                HUD.shared.show("text.magnifyingglass", "No text found")
                return
            }
            let model = results.model
            model.kind = .summary
            model.original = text
            model.translated = ""
            model.configuration = nil
            model.phase = .working
            results.show()
            do {
                _ = try await Intelligence.summarize(text) { model.translated = $0 }
                model.phase = .done
            } catch {
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Translate

    func captureAndTranslate() {
        guarded { [self] in
            guard let image = await captureRegion(title: "Capture and Translate", symbol: "translate") else { return }
            let text = await Self.recognizeText(in: image)
            guard !text.isEmpty else {
                HUD.shared.show("text.magnifyingglass", "No text found")
                return
            }
            await translate(text)
        }
    }

    private func translate(_ text: String) async {
        let model = results.model
        model.kind = .translation
        model.original = text
        model.translated = ""
        model.configuration = nil
        model.phase = .working
        results.show()

        let route: TextTranslator.Route
        do {
            route = try await TextTranslator.route(for: text, into: settings.translateTarget)
        } catch TextTranslator.Failure.sameLanguage(let name) {
            model.translated = text
            model.phase = .failed("This is already in \(name). Pick another target language in Settings.")
            return
        } catch {
            model.phase = .failed(error.localizedDescription)
            return
        }
        model.sourceName = route.sourceName
        model.targetName = route.targetName

        switch route.status {
        case .installed:
            do {
                model.translated = try await TextTranslator.translate(text, along: route)
                model.phase = .done
            } catch {
                model.phase = .failed("Translation failed: \(error.localizedDescription)")
            }
        case .supported:
            // Not downloaded yet: the SwiftUI translation task shows the system's download prompt.
            model.configuration = TranslationSession.Configuration(source: route.source, target: route.target)
        default:
            model.phase = .failed(TextTranslator.Failure.unsupported(route.sourceName, route.targetName).localizedDescription)
        }
    }

    nonisolated static func name(of language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: Codes

    func scanRegion() {
        guarded { [self] in
            guard let image = await captureRegion(title: "Scan Code", symbol: "qrcode.viewfinder") else { return }
            await showCodes(in: image)
        }
    }

    func scanClipboard() {
        guarded { [self] in
            guard let image = NSImage(pasteboard: NSPasteboard.general),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                HUD.shared.show("photo", "No image on the clipboard")
                return
            }
            await showCodes(in: cgImage)
        }
    }

    private func showCodes(in image: CGImage) async {
        let codes = await Self.detectCodes(in: image)
        guard !codes.isEmpty else {
            HUD.shared.show("qrcode", "No code found")
            return
        }
        results.model.kind = .codes
        results.model.codes = codes
        results.model.configuration = nil
        results.model.phase = .done
        results.show()
    }

    nonisolated static func detectCodes(in image: CGImage) async -> [ScannedCode] {
        let request = DetectBarcodesRequest()
        guard let observations = try? await request.perform(on: image) else { return [] }
        var seen = Set<String>()
        return observations.compactMap { observation in
            guard let payload = observation.payloadString, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
            return ScannedCode(payload: payload, symbology: symbologyName(observation.symbology))
        }
    }

    nonisolated static func symbologyName(_ symbology: BarcodeSymbology) -> String {
        switch symbology {
        case .qr, .microQR: "QR code"
        case .aztec: "Aztec code"
        case .dataMatrix: "Data Matrix"
        case .pdf417, .microPDF417: "PDF417"
        case .ean13, .ean8, .upce: "EAN/UPC barcode"
        default: "Barcode"
        }
    }

    // MARK: Color picker

    func pickColor() {
        guard sampler == nil else { return }
        let format = settings.colorFormat
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { color in
            MainActor.assumeIsolated { self.sampler = nil }
            guard let color, let rgb = color.usingColorSpace(.sRGB) else { return }
            let value = ColorFormats.format(.init(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent), as: format)
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                HUD.shared.show("eyedropper.full", value, detail: "Copied")
            }
        }
    }
}

/// On-device translation with Apple's Translation framework, shared by the result panel and
/// Shortcuts. The panel can also offer a pair that still has to be downloaded; Shortcuts can't.
enum TextTranslator {
    enum Failure: Error, LocalizedError {
        case unknownLanguage, sameLanguage(String), notDownloaded(String, String), unsupported(String, String)
        var errorDescription: String? {
            switch self {
            case .unknownLanguage: "Couldn’t tell which language the text is in."
            case .sameLanguage(let name): "The text is already in \(name)."
            case .notDownloaded(let a, let b): "Download \(a) and \(b) in System Settings > General > Language & Region > Translation Languages."
            case .unsupported(let a, let b): "macOS can’t translate \(a) to \(b)."
            }
        }
    }

    struct Route {
        let source: Locale.Language, target: Locale.Language
        let status: LanguageAvailability.Status
        var sourceName: String { ScreenModule.name(of: source) }
        var targetName: String { ScreenModule.name(of: target) }
    }

    /// The text's language, the wanted one (the system language when `code` is empty) and whether
    /// macOS can translate between them. Throws when the language is unknown or already the target.
    static func route(for text: String, into code: String?) async throws -> Route {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { throw Failure.unknownLanguage }
        let source = Locale.Language(identifier: detected.rawValue)
        let target = (code?.isEmpty ?? true) ? Locale.current.language : Locale.Language(identifier: code ?? "")
        if source.languageCode == target.languageCode { throw Failure.sameLanguage(ScreenModule.name(of: target)) }
        return Route(source: source, target: target, status: await LanguageAvailability().status(from: source, to: target))
    }

    /// Translates along a route whose pair is installed.
    static func translate(_ text: String, along route: Route) async throws -> String {
        try await TranslationSession(installedSource: route.source, target: route.target).translate(text).targetText
    }

    /// Headless translation for Shortcuts: only pairs that are already downloaded.
    static func translate(_ text: String, into code: String?) async throws -> String {
        let route = try await route(for: text, into: code)
        switch route.status {
        case .installed: return try await translate(text, along: route)
        case .supported: throw Failure.notDownloaded(route.sourceName, route.targetName)
        default: throw Failure.unsupported(route.sourceName, route.targetName)
        }
    }
}
