import AppKit
import SwiftUI

@MainActor
@Observable
final class SelectorModel {
    var title = "Capture Text"
    var symbol = "text.viewfinder"
    var sizeText: String?
    /// The selection on the screen the pointer is on, in that view's top-left coordinates.
    var selection: CGRect = .zero
    var activeScreen: Int = 0
}

/// Draws the selection border over one screen's selector.
struct SelectorBorderLayer: View {
    let model: SelectorModel
    let screenIndex: Int

    var body: some View {
        let conditions = SystemConditions.shared
        ZStack(alignment: .topLeading) {
            if model.activeScreen == screenIndex && model.selection.width > 0 {
                SelectionBorder(rect: model.selection, highContrast: conditions.increaseContrast)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct SelectorHint: View {
    let model: SelectorModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 15, weight: .regular))
                .symbolRenderingMode(.monochrome)
            Text(model.title)
                .font(Brand.font(13, .medium))
            Text(model.sizeText ?? "Drag to select · Esc to cancel")
                .font(Brand.font(12))
                .monospacedDigit()
                .foregroundStyle(.toolchestSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.toolchestText)
        .flatCard(in: .capsule, lift: 8)
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

/// The view that draws the dimmed screen with a clear selection and tracks the drag.
final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var onDrag: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var selection: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        // Darker under Increase Contrast; the border itself is drawn by SelectorBorderLayer.
        let dim = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.5 : 0.32
        Brand.ink.ns.withAlphaComponent(dim).setFill()
        bounds.fill()
        guard selection.width > 0, selection.height > 0 else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        onDrag?(selection)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let result = selection.width >= 4 && selection.height >= 4 ? selection : nil
        start = nil
        onFinish?(result)
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Full-screen region selection across every display. Returns the region in global display
/// coordinates (top-left origin), the space ScreenCaptureKit's `captureImage(in:)` takes.
@MainActor
final class RegionSelector {
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private let model = SelectorModel()

    func select(title: String, symbol: String) async -> CGRect? {
        if continuation != nil { return nil }
        model.title = title
        model.symbol = symbol
        model.sizeText = nil
        model.selection = .zero
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        NSApp.activate()
        let primaryHeight = Geometry.primaryHeight
        for screen in NSScreen.screens {
            let panel = KeyablePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.setAccessibilityLabel("\(model.title). Drag to select a region, or press escape to cancel.")
            view.setAccessibilityRole(.group)
            let screenFrame = screen.frame
            let index = panels.count
            let viewHeight = screen.frame.height
            view.onDrag = { [weak self] rect in
                self?.model.sizeText = "\(Int(rect.width)) × \(Int(rect.height))"
                self?.model.activeScreen = index
                self?.model.selection = CGRect(x: rect.minX, y: viewHeight - rect.maxY, width: rect.width, height: rect.height)
            }
            view.onFinish = { [weak self] rect in
                guard let self else { return }
                let global = rect.map {
                    Geometry.axRect(fromCocoa: $0.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), primaryHeight: primaryHeight)
                }
                self.finish(global)
            }
            panel.contentView = view
            let border = NSHostingView(rootView: SelectorBorderLayer(model: model, screenIndex: index))
            border.frame = view.bounds
            border.autoresizingMask = [.width, .height]
            view.addSubview(border)
            let hint = NSHostingView(rootView: SelectorHint(model: model))
            hint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hint.topAnchor.constraint(equalTo: view.topAnchor, constant: max(screen.safeAreaInsets.top, 24) + 12),
            ])
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.frame.contains(mouse) } ?? panels.first
        keyPanel?.makeKey()
        keyPanel?.makeFirstResponder(keyPanel?.contentView)
    }

    private func finish(_ rect: CGRect?) {
        if rect != nil { Haptics.play(.tick) }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: rect)
    }
}
