import AppKit

@MainActor
final class PromptVariablesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let promptSource: () -> String
    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let valueView = NSTextView()
    private let status = NSTextField(labelWithString: "Подстановка: {{ имя_переменной }}. Значения хранятся локально.")
    private var variables: [String: String]
    private var names: [String] { variables.keys.sorted() }
    private var selectedName: String?
    private var previewController: NSWindowController?
    private var actions: [PromptVariableAction] = []

    init(model: AppModel, promptSource: @escaping () -> String) {
        self.model = model; self.promptSource = promptSource
        variables = ["graphviz_attributes": ProjectResources.graphvizDeclaration].merging(model.ollamaPreferences.variables) { _, custom in custom }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 830, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Переменные системного промпта"
        window.minSize = NSSize(width: 740, height: 480)
        window.center()
        super.init(window: window)
        build()
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        loadSelection()
        AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let root = NSView(); root.wantsLayer = true; root.layer?.name = "theme-surface-window"
        root.layer?.backgroundColor = AppTheme.surface("window").cgColor; window?.contentView = root
        let left = NSStackView(); left.orientation = .vertical; left.alignment = .leading; left.spacing = 12
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("variable"))
        column.title = "Переменная"; column.width = 210
        table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self
        table.identifier = NSUserInterfaceItemIdentifier("prompt-variables-list")
        table.rowHeight = 28
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        left.addArrangedSubview(list)
        let add = button("Добавить", identifier: "prompt-variable-add") { [weak self] in self?.addVariable() }
        let delete = button("Удалить", identifier: "prompt-variable-delete") { [weak self] in self?.deleteVariable() }
        let listActions = NSStackView(views: [add, delete]); listActions.spacing = 7; left.addArrangedSubview(listActions)

        nameField.identifier = NSUserInterfaceItemIdentifier("prompt-variable-name")
        valueView.identifier = NSUserInterfaceItemIdentifier("prompt-variable-value")
        valueView.isRichText = false; valueView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueView.isAutomaticQuoteSubstitutionEnabled = false; valueView.isAutomaticDashSubstitutionEnabled = false
        valueView.textContainerInset = NSSize(width: 12, height: 12)
        valueView.isVerticallyResizable = true; valueView.isHorizontallyResizable = false
        valueView.autoresizingMask = [.width]; valueView.textContainer?.widthTracksTextView = true
        let editor = NSScrollView(); editor.documentView = valueView; editor.hasVerticalScroller = true; editor.borderType = .bezelBorder
        let save = button("Сохранить", identifier: "prompt-variable-save") { [weak self] in self?.saveVariable() }
        let reset = button("По умолчанию", identifier: "prompt-variable-reset") { [weak self] in self?.resetDefault() }
        let preview = button("Предпросмотр промпта", identifier: "prompt-variable-preview") { [weak self] in self?.preview() }
        let row = NSStackView(views: [save, reset, preview]); row.spacing = 8
        let right = NSStackView(views: [NSTextField(labelWithString: "Имя (латинские буквы, цифры и _)"), nameField, editor, row, status])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 10
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byWordWrapping
        [left, right].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            left.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), left.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            left.widthAnchor.constraint(equalToConstant: 210), list.widthAnchor.constraint(equalTo: left.widthAnchor),
            list.heightAnchor.constraint(equalTo: left.heightAnchor, constant: -40),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 20), right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), right.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            nameField.widthAnchor.constraint(equalTo: right.widthAnchor), editor.widthAnchor.constraint(equalTo: right.widthAnchor),
            editor.heightAnchor.constraint(equalTo: right.heightAnchor, constant: -140),
            status.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: names[row]); field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingTail; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }
    private func loadSelection() {
        guard names.indices.contains(table.selectedRow) else { return }
        selectedName = names[table.selectedRow]
        nameField.stringValue = selectedName ?? ""; valueView.string = variables[selectedName ?? ""] ?? ""
        nameField.isEditable = selectedName != "graphviz_attributes"
    }
    private func persist(select name: String) {
        var preferences = model.ollamaPreferences; preferences.variables = variables
        model.updateOllamaPreferences(preferences)
        table.reloadData()
        if let index = names.firstIndex(of: name) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        loadSelection()
    }
    private func saveVariable() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
              valueView.string.count <= 32000 else { status.stringValue = "Проверьте имя и длину значения (до 32000 символов)."; return }
        if name != selectedName && variables[name] != nil { status.stringValue = "Переменная с таким именем уже существует."; return }
        let total = variables.filter { $0.key != selectedName }.values.reduce(0) { $0+$1.count } + valueView.string.count
        guard total <= 128000 else { status.stringValue = "Суммарный размер переменных превышает 128000 символов."; return }
        if let old = selectedName, old != name { variables.removeValue(forKey: old) }
        variables[name] = valueView.string; persist(select: name)
        status.stringValue = "Сохранено. Подстановка: {{ \(name) }}"
    }
    private func addVariable() {
        guard variables.count < 128 else { status.stringValue = "Доступно не более 128 переменных."; return }
        var index = 1
        while variables["variable_\(index)"] != nil { index += 1 }
        let name = "variable_\(index)"; variables[name] = ""; persist(select: name)
        window?.makeFirstResponder(nameField)
    }
    private func deleteVariable() {
        guard let name = selectedName else { return }
        guard name != "graphviz_attributes" else { status.stringValue = "Встроенную переменную можно восстановить по умолчанию."; return }
        variables.removeValue(forKey: name); persist(select: "graphviz_attributes")
        status.stringValue = "Переменная удалена."
    }
    private func resetDefault() {
        guard selectedName == "graphviz_attributes" else { status.stringValue = "Значение по умолчанию есть у graphviz_attributes."; return }
        variables["graphviz_attributes"] = ProjectResources.graphvizDeclaration; persist(select: "graphviz_attributes")
        status.stringValue = "Справочник Graphviz восстановлен."
    }
    private func preview() {
        var previewVariables = variables
        if let name = selectedName { previewVariables[name] = valueView.string }
        status.stringValue = "Подстановка переменных…"
        Task { @MainActor in
            do {
                let prompt = try await model.previewSystemPrompt(promptSource(), variables: previewVariables)
                let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = "Предпросмотр системного промпта"
                let text = NSTextView(); text.isEditable = false; text.isRichText = false
                text.string = prompt; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                text.textContainerInset = NSSize(width: 20, height: 20)
                let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
                text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
                panel.contentView = scroll; panel.center(); AppTheme.configure(panel)
                previewController = NSWindowController(window: panel); previewController?.showWindow(nil)
                status.stringValue = "Шаблон проверен; Ollama не вызывалась."
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    private func button(_ title: String, identifier: String, action: @escaping () -> Void) -> NSButton {
        let target = PromptVariableAction(action); actions.append(target)
        let button = NSButton(title: title, target: target, action: #selector(PromptVariableAction.invoke))
        button.bezelStyle = .rounded; button.identifier = NSUserInterfaceItemIdentifier(identifier); return button
    }
}

@MainActor
private final class PromptVariableAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}
