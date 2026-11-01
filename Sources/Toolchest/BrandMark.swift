import AppKit

/// Toolchest's mark: a spanner crossed over a screwdriver with a blue handle.
/// One drawing on a 24-unit grid, y down: solid ice, one accent part, detail cut out of it.
/// `scripts/make-icon.swift` paints it on the app icon's tile and `menuBarImage` draws it as a
/// template, so the two can never differ.
enum BrandMark {
    static let grid: CGFloat = 24

    /// The spanner: an open jaw at the top right, turned to stand on the diagonal.
    private static func spanner() -> CGPath {
        let head: CGFloat = 5.8, jaw: CGFloat = 2.7, shaft: CGFloat = 2.5, length: CGFloat = 22.4
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -shaft))
        path.addArc(center: .zero, radius: shaft, startAngle: 1.5 * .pi, endAngle: 0.5 * .pi, clockwise: true)
        path.addLine(to: CGPoint(x: length - 8, y: shaft))
        path.addArc(center: CGPoint(x: length - 4.2, y: 0), radius: head, startAngle: 2.5, endAngle: 0.62, clockwise: true)
        path.addLine(to: CGPoint(x: length - 4.4, y: jaw * 0.72))
        path.addLine(to: CGPoint(x: length - 4.4, y: -jaw * 0.72))
        path.addLine(to: CGPoint(x: length - 4.2 + head * cos(0.62), y: -head * sin(0.62)))
        path.addArc(center: CGPoint(x: length - 4.2, y: 0), radius: head, startAngle: -0.62, endAngle: -2.5, clockwise: true)
        path.closeSubpath()
        var turn = CGAffineTransform(translationX: 3.2, y: 20.8).rotated(by: -.pi / 4)
        return path.copy(using: &turn) ?? path
    }

    /// The screwdriver's steel, from the tip to the handle.
    private static func steel() -> CGPath {
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: CGRect(x: 1.6, y: -1.4, width: 13, height: 2.8), cornerWidth: 0.4, cornerHeight: 0.4, transform: nil))
        path.addLines(between: [CGPoint(x: 1.8, y: -1.4), CGPoint(x: 0, y: -0.7), CGPoint(x: 0, y: 0.7), CGPoint(x: 1.8, y: 1.4)])
        path.closeSubpath()
        var turn = screwdriverTurn
        return path.copy(using: &turn) ?? path
    }

    /// The one accent part: the screwdriver's handle.
    private static func handle() -> CGPath {
        var turn = screwdriverTurn
        return CGPath(roundedRect: CGRect(x: 13.4, y: -2.9, width: 11.6, height: 5.8), cornerWidth: 2.2, cornerHeight: 2.2, transform: &turn)
    }

    private static var screwdriverTurn: CGAffineTransform { CGAffineTransform(translationX: 2.9, y: 3.1).rotated(by: .pi / 4) }

    /// Paints the mark on a context whose unit is one grid unit, y down. The screwdriver passes behind
    /// the spanner with a clean gap around it.
    static func draw(in context: CGContext, ice: CGColor, accent: CGColor) {
        context.saveGState()
        let outside = CGMutablePath()
        outside.addRect(CGRect(x: -1, y: -1, width: grid + 2, height: grid + 2))
        outside.addPath(spanner().copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 4).normalized())
        context.addPath(outside)
        context.clip(using: .evenOdd)
        context.setFillColor(ice)
        context.addPath(steel())
        context.fillPath()
        context.setFillColor(accent)
        context.addPath(handle())
        context.fillPath()
        context.restoreGState()
        context.setFillColor(ice)
        context.addPath(spanner())
        context.fillPath()
    }

    /// The menu bar image: the same drawing in one colour, as a template so macOS tints it.
    /// `active` adds a dot under the tools, for a state that is on (Keep Awake).
    static func menuBarImage(description: String, active: Bool = false) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: side / grid, y: -side / grid)
            draw(in: context, ice: NSColor.black.cgColor, accent: NSColor.black.cgColor)
            if active {
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: 10, y: 19.2, width: 4.4, height: 4.4))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
