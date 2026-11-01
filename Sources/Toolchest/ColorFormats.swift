import Foundation

/// sRGB color formatting: hex, rgb() and oklch() (Björn Ottosson's OKLab, CSS Color 4 notation).
enum ColorFormats {
    struct RGB: Sendable, Equatable {
        /// Gamma-encoded sRGB components, 0...1.
        var r: Double, g: Double, b: Double
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    static func byte(_ value: Double) -> Int { Int((clamp(value) * 255).rounded()) }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    static func rgb(_ c: RGB) -> String {
        "rgb(\(byte(c.r)), \(byte(c.g)), \(byte(c.b)))"
    }

    private static func linear(_ v: Double) -> Double {
        let v = clamp(v)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// (L 0...1, C, hue degrees 0..<360).
    static func oklchComponents(_ c: RGB) -> (l: Double, c: Double, h: Double) {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = sqrt(A * A + B * B)
        var hue = atan2(B, A) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (L, chroma, chroma < 0.0002 ? 0 : hue)
    }

    static func oklch(_ c: RGB) -> String {
        let (l, chroma, h) = oklchComponents(c)
        let lightness = String(format: "%.1f%%", l * 100)
        if chroma < 0.0002 { return "oklch(\(lightness) 0 0)" }
        return "oklch(\(lightness) \(String(format: "%.3f", chroma)) \(String(format: "%.1f", h)))"
    }

    static func format(_ c: RGB, as format: ColorFormat) -> String {
        switch format {
        case .hex: hex(c)
        case .rgb: rgb(c)
        case .oklch: oklch(c)
        }
    }
}
