import AppKit

extension NSMenuItem {
    /// A menu's first line: the app's name at full strength, with its state under it when it has one.
    /// It is a view because macOS dims a disabled item's title whatever colour it is given.
    @MainActor static func appName(_ name: String, state: String? = nil) -> NSMenuItem {
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.textColor = .labelColor
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 16, bottom: 3, right: 16)
        if let state {
            let line = NSTextField(labelWithString: state)
            line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            line.textColor = .secondaryLabelColor
            stack.addArrangedSubview(line)
        }
        stack.setFrameSize(stack.fittingSize)
        stack.autoresizingMask = [.width]
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.view = stack
        return item
    }
}
