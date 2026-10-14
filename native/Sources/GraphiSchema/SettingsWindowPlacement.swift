import AppKit

enum SettingsWindowPlacement {
    static func origin(size: NSSize, cursor: NSPoint, visibleFrame: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        var x = cursor.x+gap
        var y = cursor.y-gap-size.height
        if x+size.width > visibleFrame.maxX, cursor.x-gap-size.width >= visibleFrame.minX {
            x = cursor.x-gap-size.width
        }
        if y < visibleFrame.minY, cursor.y+gap+size.height <= visibleFrame.maxY {
            y = cursor.y+gap
        }
        return NSPoint(x: max(visibleFrame.minX, min(x, visibleFrame.maxX-size.width)),
                       y: max(visibleFrame.minY, min(y, visibleFrame.maxY-size.height)))
    }

    static func place(_ window: NSWindow, near cursor: NSPoint = NSEvent.mouseLocation) {
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? window.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
        window.setFrame(NSRect(origin: origin(size: size, cursor: cursor, visibleFrame: visible), size: size), display: false)
    }
}

extension NSWindowController {
    func showNearCursor(_ sender: Any?, near cursor: NSPoint = NSEvent.mouseLocation) {
        if let window { SettingsWindowPlacement.place(window, near: cursor) }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}
