import AppKit

@MainActor
enum AppTheme {
    private static var currentDark: Bool?
    private static var currentMode = "system"

    static func apply(dark: Bool, mode: String = "manual") {
        guard currentDark != dark || currentMode != mode else { return }
        currentMode = mode
        NSApp.appearance = mode == "system" ? nil : NSAppearance(named: dark ? .darkAqua : .aqua)
        currentDark = dark
        for window in NSApp.windows {
            configure(window)
        }
    }

    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        let dark = currentDark ?? false
        window.appearance = currentMode == "system" ? nil : NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = surface("window")
        if let root = window.contentView { refresh(root, dark: dark) }
    }

    static func surface(_ role: String) -> NSColor {
        let dark = currentDark ?? false
        switch role {
        case "control": return NSColor(hex: dark ? "#352C43" : "#FFFFFF")
        case "window": return NSColor(hex: dark ? "#292135" : "#F5F7FA")
        default: return NSColor(hex: dark ? "#251D32" : "#F8FAFC")
        }
    }

    private static func refresh(_ view: NSView, dark: Bool) {
        if let surface = view.layer?.name, surface.hasPrefix("theme-surface-") {
            let color: String
            switch surface {
            case "theme-surface-control": color = dark ? "#352C43" : "#FFFFFF"
            case "theme-surface-window": color = dark ? "#292135" : "#F5F7FA"
            default: color = dark ? "#251D32" : "#F8FAFC"
            }
            view.layer?.backgroundColor = NSColor(hex: color).cgColor
        }
        if let text = view as? NSTextView {
            text.backgroundColor = NSColor(hex: dark ? "#21172F" : "#FFFFFF")
            text.textColor = .labelColor
            text.insertionPointColor = .labelColor
        }
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
            scroll.backgroundColor = NSColor(hex: dark ? "#21172F" : "#FFFFFF")
        }
        for child in view.subviews { refresh(child, dark: dark) }
        view.needsDisplay = true
    }
}

@MainActor
final class ThemedColorWell: NSColorWell {
    var onOpenEditor: (() -> Void)?

    override func activate(_ exclusive: Bool) {
        onOpenEditor?()
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { onOpenEditor?() }
    }
}
