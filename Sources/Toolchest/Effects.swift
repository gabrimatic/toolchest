import AppKit
import SwiftUI

/// The region selector's border: a still two-tone line, ink under ice, so it reads on any
/// background (light or dark) with no animation. A touch heavier under Increase Contrast.
struct SelectionBorder: View {
    let rect: CGRect
    let highContrast: Bool

    var body: some View {
        let lineWidth: CGFloat = highContrast ? 2.5 : 1.5
        ZStack {
            Rectangle().stroke(Color(nsColor: Brand.ink.ns.withAlphaComponent(0.7)), lineWidth: lineWidth + 1)
            Rectangle().stroke(Color(nsColor: Brand.ice.ns), lineWidth: lineWidth)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Animates a frame change on another app's window through Accessibility, one step per display
/// refresh (so 120 steps a second on ProMotion displays).
@MainActor
final class WindowAnimator: NSObject {
    private var link: CADisplayLink?
    private var window: AXElement?
    private var from = CGFloat(0), to = CGFloat(0), width = CGFloat(0)
    private var start: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.2

    /// Grows `window`'s height from `from` to `to` on `screen`'s display link.
    func growHeight(of window: AXElement, from: CGFloat, to: CGFloat, width: CGFloat, on screen: NSScreen) {
        link?.invalidate()
        self.window = window
        self.from = from
        self.to = to
        self.width = width
        start = 0
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        if start == 0 { start = link.timestamp }
        let t = min((link.timestamp - start) / duration, 1)
        let eased = 1 - pow(1 - t, 3)
        window?.setSize(CGSize(width: width, height: from + (to - from) * eased))
        if t >= 1 {
            link.invalidate()
            self.link = nil
            window = nil
        }
    }
}
