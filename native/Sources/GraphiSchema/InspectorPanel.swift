import AppKit

/// Keeps editable properties above document windows while GraphiSchema is active.
@MainActor
final class InspectorPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        collectionBehavior.insert(.fullScreenAuxiliary)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
