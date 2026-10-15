import AppKit

@MainActor
final class NodeTextEditorWindowController: NSWindowController, NSTextViewDelegate, NSTextFieldDelegate {
    let nodeID: String
    private let labelField = NSTextView()
    private let fontSizeField: NSTextField
    private let horizontalAlignment = NSPopUpButton()
    private let verticalAlignment = NSPopUpButton()
    private let wrapButton = NSButton(checkboxWithTitle: "Переносить текст по ширине фигуры", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let changed: (String, String, String, Double, Bool) -> Void
    private var isUpdating = false
    private var isEditingLocked = false
    private struct Values: Equatable {
        var label: String
        var horizontal: String
        var vertical: String
        var fontSize: Double
        var wrap: Bool
        init(_ node: DiagramNode) {
            label = node.label
            horizontal = node.effectiveLabelAlignment
            vertical = node.effectiveLabelVerticalAlignment
            fontSize = node.style.effectiveFontSize
            wrap = node.effectiveLabelWrap
        }
    }
    private var values: Values

    init(node: DiagramNode, onChange: @escaping (String, String, String, Double, Bool) -> Void) {
        nodeID = node.id
        values = Values(node)
        fontSizeField = NSTextField(string: String(format: "%.1f", node.style.effectiveFontSize))
        changed = onChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 455),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Текст фигуры"
        window.identifier = NSUserInterfaceItemIdentifier("node-text-window")
        super.init(window: window)
        build(for: node)
        AppTheme.configure(window)
        refresh(node: node, editingLocked: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(node: DiagramNode, editingLocked: Bool) {
        guard node.id == nodeID else { return }
        isUpdating = true
        defer { isUpdating = false }
        isEditingLocked = editingLocked
        labelField.isEditable = !editingLocked
        let controls: [NSControl] = [fontSizeField, horizontalAlignment, verticalAlignment, wrapButton]
        controls.forEach { $0.isEnabled = !editingLocked }
        window?.title = "Текст — \(node.label.components(separatedBy: .newlines).first ?? node.label) · \(nodeID)"
        let updated = Values(node)
        guard updated != values else { return }
        values = updated
        labelField.string = values.label
        fontSizeField.stringValue = String(format: "%.1f", values.fontSize)
        select(horizontalAlignment, value: values.horizontal)
        select(verticalAlignment, value: values.vertical)
        wrapButton.state = values.wrap ? .on : .off
    }

    private func build(for node: DiagramNode) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let textHelp = "Подпись внутри фигуры. Ввод сразу обновляет холст и JSON. Enter добавляет ручной перевод строки; автоматический перенос включается отдельно."
        root.addArrangedSubview(HelpFieldLabel("Текст фигуры", explanation: textHelp, identifier: "node-text-help"))
        let textScroll = NSScrollView()
        textScroll.identifier = NSUserInterfaceItemIdentifier("node-text-scroll")
        textScroll.borderType = .bezelBorder
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.widthAnchor.constraint(equalToConstant: 340).isActive = true
        textScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        labelField.frame = NSRect(x: 0, y: 0, width: 340, height: 88)
        labelField.string = node.label
        labelField.identifier = NSUserInterfaceItemIdentifier("node-text-value")
        labelField.toolTip = textHelp
        labelField.isRichText = false
        labelField.allowsUndo = true
        labelField.font = .systemFont(ofSize: 12)
        labelField.textContainerInset = NSSize(width: 8, height: 6)
        labelField.isVerticallyResizable = true
        labelField.isHorizontallyResizable = false
        labelField.autoresizingMask = .width
        labelField.textContainer?.widthTracksTextView = true
        labelField.isAutomaticQuoteSubstitutionEnabled = false
        labelField.isAutomaticDashSubstitutionEnabled = false
        labelField.isAutomaticTextReplacementEnabled = false
        labelField.delegate = self
        textScroll.documentView = labelField
        root.addArrangedSubview(textScroll)
        let fontHelp = "Размер текста в пунктах (1–144). Каждое допустимое введённое значение сразу применяется на холсте и при экспорте."
        root.addArrangedSubview(HelpFieldLabel("Размер текста, pt", explanation: fontHelp, identifier: "node-text-font-help"))
        fontSizeField.toolTip = fontHelp
        fontSizeField.identifier = NSUserInterfaceItemIdentifier("node-text-font-size")
        fontSizeField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        fontSizeField.delegate = self
        root.addArrangedSubview(fontSizeField)
        wrapButton.state = node.effectiveLabelWrap ? .on : .off
        wrapButton.target = self
        wrapButton.action = #selector(parameterChanged(_:))
        wrapButton.identifier = NSUserInterfaceItemIdentifier("node-text-wrap")
        let wrapHelp = "Автоматически переносит слова по ширине фигуры; длинные слова разбиваются по символам. Размер фигуры сохраняется. Ручные переводы строк работают в обоих режимах."
        let wrapRow = NSStackView(views: [wrapButton, HelpIconButton(wrapHelp, identifier: "node-text-wrap-help")])
        wrapRow.orientation = .horizontal
        wrapRow.alignment = .centerY
        wrapRow.spacing = 6
        root.addArrangedSubview(wrapRow)
        root.addArrangedSubview(addChoices(horizontalAlignment, label: "По горизонтали", help: "Сразу выравнивает строки влево, по центру или вправо внутри фигуры.",
                   choices: [("left", "Влево"), ("center", "По центру"), ("right", "Вправо")], selected: node.effectiveLabelAlignment,
                   identifier: "node-text-horizontal"))
        root.addArrangedSubview(addChoices(verticalAlignment, label: "По вертикали", help: "Сразу размещает текстовый блок сверху, посередине или снизу фигуры.",
                   choices: [("top", "Сверху"), ("middle", "Посередине"), ("bottom", "Снизу")], selected: node.effectiveLabelVerticalAlignment,
                   identifier: "node-text-vertical"))
        statusLabel.stringValue = "Изменения применяются сразу. Cmd+Z отменяет изменение."
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.widthAnchor.constraint(equalToConstant: 340).isActive = true
        root.addArrangedSubview(statusLabel)
        let done = NSButton(title: "Готово", target: self, action: #selector(closePressed))
        done.identifier = NSUserInterfaceItemIdentifier("node-text-done")
        done.keyEquivalent = "\u{1B}"
        root.addArrangedSubview(done)
        window?.contentView = NSView()
        guard let content = window?.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 380, height: root.fittingSize.height))
    }

    private func select(_ popup: NSPopUpButton, value: String) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) { popup.select(item) }
    }

    private func addChoices(_ popup: NSPopUpButton, label: String, help: String,
                            choices: [(String, String)], selected: String, identifier: String) -> NSStackView {
        let fieldLabel = HelpFieldLabel(label, explanation: help, identifier: "\(identifier)-help")
        popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        popup.toolTip = help
        popup.widthAnchor.constraint(equalToConstant: 340).isActive = true
        popup.target = self
        popup.action = #selector(parameterChanged(_:))
        for (value, title) in choices {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        select(popup, value: selected)
        let row = NSStackView(views: [fieldLabel, popup])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.identifier = NSUserInterfaceItemIdentifier("\(identifier)-row")
        return row
    }

    func textDidChange(_ notification: Notification) { applyChanges() }
    func controlTextDidChange(_ notification: Notification) { applyChanges() }
    @objc private func parameterChanged(_ sender: NSControl) { applyChanges() }
    @objc private func closePressed() { close() }

    private func applyChanges() {
        guard !isUpdating, !isEditingLocked else { return }
        var updated = values
        let label = labelField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelValid = !label.isEmpty && label.unicodeScalars.count <= 160
        if labelValid { updated.label = label }
        let fontText = fontSizeField.currentEditor()?.string ?? fontSizeField.stringValue
        let font = Double(fontText.replacingOccurrences(of: ",", with: "."))
        let fontValid = font.map { $0.isFinite && (1...144).contains($0) } ?? false
        if fontValid, let font { updated.fontSize = font }
        updated.horizontal = horizontalAlignment.selectedItem?.representedObject as? String ?? values.horizontal
        updated.vertical = verticalAlignment.selectedItem?.representedObject as? String ?? values.vertical
        updated.wrap = wrapButton.state == .on
        statusLabel.stringValue = !labelValid ? "Подпись должна содержать от 1 до 160 символов."
            : !fontValid ? "Размер текста: от 1 до 144 pt. Применено последнее допустимое значение."
            : "Изменения применяются сразу. Cmd+Z отменяет изменение."
        guard updated != values else { return }
        values = updated
        changed(values.label, values.horizontal, values.vertical, values.fontSize, values.wrap)
    }
}
