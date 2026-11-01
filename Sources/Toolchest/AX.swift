import AppKit
import ApplicationServices

/// A thin, Sendable wrapper over AXUIElement. AX calls are thread-safe; every element gets a short
/// messaging timeout so a hung app can never stall Toolchest (or the event tap) for long.
struct AXElement: @unchecked Sendable, Hashable {
    let ref: AXUIElement

    init(_ ref: AXUIElement, timeout: Float = 0.25) {
        self.ref = ref
        AXUIElementSetMessagingTimeout(ref, timeout)
    }

    static func application(_ pid: pid_t, timeout: Float = 0.25) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid), timeout: timeout)
    }

    static func systemWide(timeout: Float = 0.1) -> AXElement {
        AXElement(AXUIElementCreateSystemWide(), timeout: timeout)
    }

    static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(ref)) }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }
    func int(_ attribute: String) -> Int? { (value(attribute) as? NSNumber)?.intValue }

    func element(_ attribute: String) -> AXElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let array = value(attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return AXElement(unsafeDowncast(item, to: AXUIElement.self))
        }
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var children: [AXElement] { elements(kAXChildrenAttribute) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(ref, &pid) == .success ? pid : nil
    }

    var position: CGPoint? {
        guard let value = value(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let value = value(kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }

    /// Frame in AX (top-left origin, global) coordinates.
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, attribute as CFString, value) == .success
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(kAXSizeAttribute, value)
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(ref, action as CFString) == .success
    }

    /// The element at a global top-left point, asked of this element (an app or the system-wide element).
    func hitTest(_ point: CGPoint) -> AXElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(ref, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        return AXElement(element, timeout: 0.1)
    }

    /// Walks up to the enclosing window.
    var window: AXElement? {
        if role == kAXWindowRole { return self }
        if let window = element(kAXWindowAttribute) { return window }
        var current: AXElement? = self
        for _ in 0..<12 {
            guard let parent = current?.element(kAXParentAttribute) else { return nil }
            if parent.role == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }
}

enum Geometry {
    /// Height of the primary display, the reference for flipping between Cocoa and AX coordinates.
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (bottom-left origin) rect to AX/CG global (top-left origin) rect.
    static func axRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AX/CG global (top-left origin) rect to Cocoa (bottom-left origin) rect.
    static func cocoaRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Whether two frames match within a couple of points (apps round sizes to their own grid).
    static func roughlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
