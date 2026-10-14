import AppKit

@MainActor
final class NodeTextEditorWindowController: NSWindowController {
    private let labelField: NSTextField
    private let horizontalAlignment = NSPopUpButton()
    private let verticalAlignment = NSPopUpButton()
    private let saveChanges: (String, String, String) -> Void

    init(node: DiagramNode, onSave: @escaping (String, String, String) -> Void) {
        labelField = NSTextField(string: node.label)
        saveChanges = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 255),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Текст фигуры"
        window.center()
        super.init(window: window)
        build(for: node)
        AppTheme.configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build(for node: DiagramNode) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let textHelp = "Текстовая подпись внутри фигуры. Она отображается на холсте и сохраняется в JSON-модели."
        let label = HelpFieldLabel("Текст фигуры", explanation: textHelp, identifier: "node-text-help")
        labelField.toolTip = textHelp
        labelField.identifier = NSUserInterfaceItemIdentifier("node-text-value")
        labelField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        root.addArrangedSubview(label)
        root.addArrangedSubview(labelField)

        root.addArrangedSubview(addChoices(horizontalAlignment, label: "По горизонтали", help: "Выравнивает подпись влево, по центру или вправо внутри границ фигуры.",
                   choices: [("left", "Влево"), ("center", "По центру"), ("right", "Вправо")], selected: node.effectiveLabelAlignment,
                   identifier: "node-text-horizontal"))
        root.addArrangedSubview(addChoices(verticalAlignment, label: "По вертикали", help: "Размещает подпись у верхней или нижней границы фигуры либо посередине.",
                   choices: [("top", "Сверху"), ("middle", "Посередине"), ("bottom", "Снизу")], selected: node.effectiveLabelVerticalAlignment,
                   identifier: "node-text-vertical"))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelPressed))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        root.addArrangedSubview(buttons)

        window?.contentView = NSView()
        window?.contentView?.addSubview(root)
        if let content = window?.contentView {
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    private func addChoices(_ popup: NSPopUpButton, label: String, help: String,
                            choices: [(String, String)], selected: String, identifier: String) -> NSStackView {
        let fieldLabel = HelpFieldLabel(label, explanation: help, identifier: "\(identifier)-help")
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.toolTip = help
        popup.widthAnchor.constraint(equalToConstant: 340).isActive = true
        for (value, title) in choices {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == selected }) { popup.select(item) }
        let row = NSStackView(views: [fieldLabel, popup])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.identifier = NSUserInterfaceItemIdentifier("\(identifier)-row")
        return row
    }

    @objc private func cancelPressed() { close() }

    @objc private func savePressed() {
        guard let horizontal = horizontalAlignment.selectedItem?.representedObject as? String,
              let vertical = verticalAlignment.selectedItem?.representedObject as? String else { return }
        saveChanges(labelField.stringValue, horizontal, vertical)
        close()
    }
}
