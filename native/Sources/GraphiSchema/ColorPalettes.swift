import AppKit

@MainActor
final class PencilPaletteView: NSView {
    var isEditable = true
    var onChoose: ((NSColor) -> Void)?
    static var colors: [NSColor] {
        if let list = NSColorList.availableColorLists.first(where: { ($0.name ?? "").lowercased().contains("crayon") }) {
            let values = list.allKeys.compactMap { list.color(withKey: $0) }
            if values.count >= 24 { return Array(values.prefix(48)) }
        }
        var result: [NSColor] = []
        for index in 0..<48 {
            if index >= 44 { result.append(NSColor(white: CGFloat(index-44)/3, alpha: 1)) }
            else { result.append(NSColor(hue: CGFloat(index%11)/11, saturation: index < 22 ? 0.85 : 0.4,
                                         brightness: index.isMultiple(of: 2) ? 0.95 : 0.65, alpha: 1)) }
        }
        return result
    }
    override var isFlipped: Bool { true }
    func cell(_ index: Int) -> NSRect { NSRect(x: CGFloat(index%24)*bounds.width/24, y: CGFloat(index/24)*bounds.height/2, width: bounds.width/24, height: bounds.height/2) }
    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in Self.colors.enumerated() {
            let rect = cell(index).insetBy(dx: 1.5, dy: 3)
            let pencil = NSBezierPath(); pencil.move(to: .init(x: rect.midX, y: rect.minY))
            pencil.line(to: .init(x: rect.maxX, y: rect.minY+10)); pencil.line(to: .init(x: rect.maxX, y: rect.maxY))
            pencil.line(to: .init(x: rect.minX, y: rect.maxY)); pencil.line(to: .init(x: rect.minX, y: rect.minY+10)); pencil.close()
            color.setFill(); pencil.fill(); NSColor.labelColor.withAlphaComponent(0.35).setStroke(); pencil.lineWidth = 0.5; pencil.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = Self.colors.indices.first(where: { cell($0).contains(point) }) { onChoose?(Self.colors[index]) }
    }
}

@MainActor
final class SavedColorButton: NSButton {
    var onChoose: (() -> Void)?
    var onRemove: (() -> Void)?
    init(color: String) {
        super.init(frame: .zero)
        isBordered = false; wantsLayer = true; layer?.backgroundColor = NSColor(hex: color).cgColor
        layer?.borderWidth = 1; layer?.borderColor = NSColor.separatorColor.cgColor; layer?.cornerRadius = 3
        toolTip = color; identifier = NSUserInterfaceItemIdentifier("saved-color-\(color)")
        target = self; action = #selector(choose)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func choose() { onChoose?() }
    @objc private func removeColor() { onRemove?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); let item = NSMenuItem(title: "Удалить цвет из палитры проекта", action: #selector(removeColor), keyEquivalent: "")
        item.target = self; menu.addItem(item); return menu
    }
}
