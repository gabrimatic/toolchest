import AppKit
import CoreText
import SwiftUI

/// Toolchest's look, in one place: the palette (docs/DESIGN.md) and the type. Every surface the app
/// draws itself takes its colours and its font from here, so no view invents either.
///
/// The palette is three colours, ink, ice and the accent, and alpha blends of them. In the dark
/// appearance the ground is ink and the text is ice; in the light appearance the ground is paper
/// (ice blended towards white) and the text is ink. The accent is the same in both.
enum Brand {
    // MARK: Palette

    struct RGB: Equatable, Sendable {
        let r: Double, g: Double, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r / 255; self.g = g / 255; self.b = b / 255 }
        init(unit r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        var luminance: Double {
            func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG contrast ratio against another colour.
        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        /// This colour at `alpha` over `ground`.
        func over(_ ground: RGB, alpha: Double) -> RGB {
            RGB(unit: r * alpha + ground.r * (1 - alpha), g * alpha + ground.g * (1 - alpha), b * alpha + ground.b * (1 - alpha))
        }

        var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    static let ink = RGB(0x1B, 0x26, 0x2C)
    static let ice = RGB(0xBB, 0xE1, 0xFA)
    static let accentRGB = RGB(0x32, 0x82, 0xB8)
    /// Ice blended towards white: the ground of the light appearance.
    static let paper = ice.over(RGB(255, 255, 255), alpha: 0.3)

    /// A colour for each appearance: a base colour of the palette at an alpha. In the light
    /// appearance the base is ink (or the accent); in the dark appearance it is ice (or the accent).
    struct Tone: Sendable {
        let light: RGB, lightAlpha: Double
        let dark: RGB, darkAlpha: Double

        /// What the tone looks like on the ground of the given appearance.
        func flattened(dark isDark: Bool) -> RGB {
            isDark ? dark.over(Brand.ink, alpha: darkAlpha) : light.over(Brand.paper, alpha: lightAlpha)
        }

        var nsColor: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let base = isDark ? dark : light
                return NSColor(srgbRed: base.r, green: base.g, blue: base.b, alpha: isDark ? darkAlpha : lightAlpha)
            }
        }

        var color: Color { Color(nsColor: nsColor) }
    }

    /// The window or panel ground.
    static let ground = Tone(light: paper, lightAlpha: 1, dark: ink, darkAlpha: 1)
    /// Text and line art.
    static let text = Tone(light: ink, lightAlpha: 1, dark: ice, darkAlpha: 1)
    /// Secondary text. Reads at 4.5:1 or better on the ground in both appearances.
    static let secondaryText = Tone(light: ink, lightAlpha: 0.68, dark: ice, darkAlpha: 0.68)
    /// The accent: one selected card, one primary button, one active bar.
    static let accent = Tone(light: accentRGB, lightAlpha: 1, dark: accentRGB, darkAlpha: 1)
    /// Hairlines around cards and panels.
    static let hairline = Tone(light: ink, lightAlpha: 0.2, dark: ice, darkAlpha: 0.25)
    /// Dividers between rows.
    static let divider = Tone(light: ink, lightAlpha: 0.08, dark: ice, darkAlpha: 0.08)
    /// A quiet card or row ground, one step off the window ground.
    static let surface = Tone(light: ink, lightAlpha: 0.05, dark: ice, darkAlpha: 0.07)
    /// A selected row.
    static let selection = Tone(light: accentRGB, lightAlpha: 0.16, dark: accentRGB, darkAlpha: 0.32)
    /// A real error, and only that. The system red, as macOS draws it.
    static let error = Color(nsColor: .systemRed)

    // MARK: Type

    enum Weight: String, CaseIterable, Sendable {
        case light = "IBMPlexSans-Light", regular = "IBMPlexSans-Regular", medium = "IBMPlexSans-Medium"
    }

    static let family = "IBM Plex Sans"

    /// IBM Plex Sans at `size`. Light to medium only: headings are never heavy. The font is a
    /// bundled file, registered for this process on first use; when it is missing the text falls
    /// back to the system font and everything still reads.
    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        _ = registration
        return .custom(weight.rawValue, fixedSize: size)
    }

    /// Where the font file is: in the app (or extension) bundle's Fonts folder, or in the source
    /// tree when run from there.
    static var fontURLs: [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "IBMPlexSans", withExtension: "ttf", subdirectory: "Fonts") { urls.append(bundled) }
        // Never from the working directory of an installed app or extension, only of a tool run in the source tree.
        let installed = ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension)
        if !installed { urls.append(URL(fileURLWithPath: "Resources/Fonts/IBMPlexSans.ttf")) }
        return urls
    }

    /// Registers the bundled font for this process. Safe to call again; reports whether the family
    /// is available afterwards.
    @discardableResult
    static func registerFonts() -> Bool { registration }

    private static let registration: Bool = {
        for url in fontURLs where FileManager.default.fileExists(atPath: url.path) {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { break }
            // Already registered (the font is installed, or another call got there first) is fine.
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            if code == CTFontManagerError.alreadyRegistered.rawValue { break }
        }
        return available
    }()

    /// Whether IBM Plex Sans resolves to the bundled font.
    static var available: Bool {
        let font = CTFontCreateWithName(Weight.regular.rawValue as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String == family
    }
}

extension View {
    /// The default for a surface the app draws itself: IBM Plex Sans in the palette's text colour,
    /// the palette's accent as the tint. Native controls inside keep the system font where macOS
    /// draws them itself.
    func toolchestSurface(size: CGFloat = 13) -> some View {
        self.font(Brand.font(size))
            .foregroundStyle(Brand.text.color)
            .tint(Brand.accent.color)
    }
}

extension ShapeStyle where Self == Color {
    /// The palette's text colour: ice in the dark appearance, ink in the light one.
    static var toolchestText: Color { Brand.text.color }
    /// The palette's secondary text colour.
    static var toolchestSecondary: Color { Brand.secondaryText.color }
    /// The palette's accent.
    static var toolchestAccent: Color { Brand.accent.color }
}
