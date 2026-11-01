import AppKit
import SwiftUI

/// A borderless, non-activating, click-through panel that floats above everything on every Space.
@MainActor
func makeOverlayPanel(size: CGSize, level: NSWindow.Level = .statusBar, clickThrough: Bool = true) -> NSPanel {
    let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = level
    panel.ignoresMouseEvents = clickThrough
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    // Hide Others, or a hidden launch, must not take this off the screen.
    panel.canHide = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

@MainActor
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// The screen under the pointer, else the main screen.
@MainActor
var screenUnderMouse: NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
}

@MainActor
func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

// MARK: HUD

struct HUDContent: Equatable {
    var symbol: String
    var title: String
    var detail: String?
    var token = 0
}

@MainActor
@Observable
final class HUDModel {
    var content = HUDContent(symbol: "checkmark", title: "")
    var visible = false
}

/// Fits its content and wraps it only past `maxWidth`. `.frame(maxWidth:)` is not that: it always
/// grows to the maximum when there is room, which left short messages in the middle of a wide bar.
private struct HuggingWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    func hugging(maxWidth: CGFloat) -> some View {
        HuggingWidth(maxWidth: maxWidth) { self }
    }
}

/// A flat card for the app's own floating surfaces (the HUD, the hold ring, the hint pill, the result
/// panels): the palette's ground, a hairline, and a soft shadow so it separates from any desktop.
/// Glass is for what you click; these are quiet.
struct FlatCard: ViewModifier {
    let shape: AnyShape
    var lift: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(Brand.ground.color.opacity(0.97), in: shape)
            .overlay(shape.stroke(Brand.hairline.color, lineWidth: SystemConditions.shared.increaseContrast ? 1.5 : 1))
            .shadow(color: .black.opacity(0.22), radius: lift, y: lift / 3)
    }
}

extension View {
    func flatCard<S: Shape>(in shape: S, lift: CGFloat = 14) -> some View {
        modifier(FlatCard(shape: AnyShape(shape), lift: lift))
    }
}

struct HUDView: View {
    let model: HUDModel

    var body: some View {
        let isError = model.content.symbol.hasPrefix("exclamationmark")
        HStack(spacing: 12) {
            Image(systemName: model.content.symbol)
                .font(.system(size: 20, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isError ? Brand.error : Brand.accent.color)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.content.title)
                    .font(Brand.font(14, .medium))
                    .lineLimit(2)
                if let detail = model.content.detail {
                    Text(detail)
                        .font(Brand.font(12))
                        .foregroundStyle(.toolchestSecondary)
                        .lineLimit(3)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.toolchestText)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .hugging(maxWidth: 420)
        .flatCard(in: .rect(cornerRadius: model.content.detail == nil ? 30 : 24))
        .scaleEffect(model.visible || reduceMotionNow ? 1 : 0.96)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotionNow ? .easeOut(duration: 0.15) : .easeOut(duration: 0.22), value: model.visible)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var reduceMotionNow: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A short message in a flat card at the bottom centre of the screen under the pointer.
@MainActor
final class HUD {
    static let shared = HUD()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ symbol: String, _ title: String, detail: String? = nil, duration: TimeInterval = 1.8) {
        let panel = self.panel ?? {
            let panel = makeOverlayPanel(size: CGSize(width: 480, height: 120))
            panel.contentView = NSHostingView(rootView: HUDView(model: model))
            self.panel = panel
            return panel
        }()
        model.content = HUDContent(symbol: symbol, title: title, detail: detail, token: model.content.token + 1)
        if let screen = screenUnderMouse {
            let size = CGSize(width: 480, height: 120)
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 90,
                                  width: size.width, height: size.height), display: false)
        }
        panel.orderFrontRegardless()
        model.visible = true
        announce(detail.map { "\(title). \($0)" } ?? title)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    func error(_ title: String, _ detail: String? = nil) {
        show("exclamationmark.triangle", title, detail: detail, duration: 3.2)
    }
}

// MARK: Hold ring

@MainActor
@Observable
final class RingModel {
    var progress: Double = 0
    var visible = false
    var completed = false
    var symbol = "power"
}

struct RingView: View {
    let model: RingModel

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.toolchestText.opacity(SystemConditions.shared.increaseContrast ? 0.4 : 0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: model.progress)
                .stroke(Brand.accent.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: model.completed ? "checkmark" : model.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.toolchestText)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 26, height: 26)
        .padding(9)
        .flatCard(in: .circle, lift: 6)
        .scaleEffect(model.visible || reduceMotionNow ? 1 : 0.6)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotionNow ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.8), value: model.visible)
        .padding(10)
        .accessibilityLabel("Hold to confirm")
        .accessibilityValue("\(Int(model.progress * 100)) percent")
    }

    private var reduceMotionNow: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A small progress ring next to the pointer that fills while a guarded key is held.
@MainActor
final class HoldRing {
    static let shared = HoldRing()

    private let model = RingModel()
    private var panel: NSPanel?
    private static let size = CGSize(width: 64, height: 64)

    /// Below and right of the pointer; near the right or bottom edge it flips to the other side,
    /// and it never leaves the visible area of the screen.
    static func origin(pointer: CGPoint, size: CGSize, in area: CGRect?, gap: CGFloat = 8) -> CGPoint {
        var origin = CGPoint(x: pointer.x + gap, y: pointer.y - size.height - gap)
        guard let area else { return origin }
        if origin.x + size.width > area.maxX { origin.x = pointer.x - size.width - gap }
        if origin.y < area.minY { origin.y = pointer.y + gap }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        return origin
    }

    func show(duration: TimeInterval, symbol: String) {
        let panel = self.panel ?? {
            let panel = makeOverlayPanel(size: Self.size, level: .popUpMenu)
            panel.contentView = NSHostingView(rootView: RingView(model: model))
            self.panel = panel
            return panel
        }()
        let mouse = NSEvent.mouseLocation
        let area = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
        panel.setFrameOrigin(Self.origin(pointer: mouse, size: Self.size, in: area))
        model.symbol = symbol
        model.completed = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { model.progress = 0 }
        panel.orderFrontRegardless()
        model.visible = true
        Haptics.play(.tick)
        withAnimation(.linear(duration: duration)) { model.progress = 1 }
    }

    func hide(completed: Bool) {
        if completed {
            model.completed = true
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { model.progress = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (completed ? 0.25 : 0)) { [weak self] in
            guard let self else { return }
            self.model.visible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !self.model.visible { self.panel?.orderOut(nil) }
            }
        }
    }
}

// MARK: Glass helpers

extension View {
    func toolchestGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        self.glassEffect(glass, in: shape)
    }

    @ViewBuilder
    func toolchestGlassButton(prominent: Bool = false) -> some View {
        if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
    }
}
