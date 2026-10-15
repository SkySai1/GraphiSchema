import AppKit

/// Project-owned definitions and the two-column legend constructor.
@MainActor
final class DiagramLibraryWindowController: NSWindowController, ProjectThemedWindow, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let projectModel: AppModel
    let documentID: String?
    private let tabs = NSTabView()
    private let typePicker = NSPopUpButton()
    private let name = NSTextField(), identifier = NSTextField(), descriptionField = NSTextField()
    private let line = NSPopUpButton(), direction = NSPopUpButton(), route = NSPopUpButton()
    private let head = NSPopUpButton(), tail = NSPopUpButton(), colorMode = NSPopUpButton(), textMode = NSPopUpButton()
    private let width = NSTextField(), fontSize = NSTextField(), weight = NSTextField(), minlen = NSTextField()
    private let color = NSColorWell(), textColor = NSColorWell()
    private let transparent = NSButton(checkboxWithTitle: "Прозрачный фон подписи", target: nil, action: nil)
    private let constraint = NSButton(checkboxWithTitle: "Влияет на ранжирование", target: nil, action: nil)
    private let applySelected = NSButton(checkboxWithTitle: "Применить к выделенным связям", target: nil, action: nil)
    private let mode = NSPopUpButton()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var editingID: String?
    private var isPopulating = false
    private var isDirty = false
    private var lastProject: DiagramProject?
    private var controls: [NSControl] = []
    private var rows: [LegendEntry] { projectModel.diagram?.presentation.effectiveLegendEntries ?? [] }
    private var definitions: [EdgeTypeDefinition] { projectModel.diagram?.effectiveEdgeTypes ?? [] }

    init(model: AppModel) {
        projectModel = model; documentID = model.projectID
        let panel = InspectorPanel(contentRect: NSRect(x: 0,y: 0,width: 660,height: 670), styleMask: [.titled,.closable,.resizable], backing: .buffered,defer: false)
        panel.title = "Типы связей и условные обозначения"; panel.minSize = NSSize(width: 560,height: 520)
        super.init(window: panel)
        build(); NSColorPanel.shared.showsAlpha = true; AppTheme.configure(panel); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(legend: Bool) { refresh(); tabs.selectTabViewItem(at: legend ? 1 : 0); showNearCursor(nil) }

    func refresh() {
        guard let project = projectModel.diagram else { return }
        controls.forEach { $0.isEnabled = !projectModel.isEditingLocked }
        table.isEnabled = !projectModel.isEditingLocked
        guard project != lastProject else { return }
        let selected = editingID
        isPopulating = true
        typePicker.removeAllItems(); typePicker.addItem(withTitle: "Новый тип…"); typePicker.lastItem?.representedObject = ""
        for definition in project.effectiveEdgeTypes {
            typePicker.addItem(withTitle: "\(definition.name) · \(definition.id)"); typePicker.lastItem?.representedObject = definition.id
        }
        if let selected, let index = typePicker.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) { typePicker.selectItem(at: index) }
        if !isDirty || (selected != nil && !definitions.contains(where: { $0.id == selected })) { loadType(selected) }
        select(mode,project.presentation.effectiveLegendMode)
        let row = table.selectedRow
        table.reloadData(); if rows.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row),byExtendingSelection: false) }
        isPopulating = false; lastProject = project
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let typeTab = NSTabViewItem(identifier: "types"); typeTab.label = "Типы связей"
        let legendTab = NSTabViewItem(identifier: "legend"); legendTab.label = "Условные обозначения"
        tabs.addTabViewItem(typeTab); tabs.addTabViewItem(legendTab)
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 7
        let pickerRow = NSStackView(views: [typePicker,ActionButton("Из выделенной связи") { [weak self] in self?.createType(fromSelection: true) },ActionButton("Новый") { [weak self] in self?.createType(fromSelection: false) }]); pickerRow.spacing = 6
        typePicker.target = self; typePicker.action = #selector(pickedType)
        form.addArrangedSubview(pickerRow)
        pickerRow.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        typePicker.setContentCompressionResistancePriority(.defaultLow,for: .horizontal)
        addField(form,"ID типа",identifier,"Постоянный идентификатор типа внутри проекта. Создаётся автоматически и не меняется при переименовании.")
        addField(form,"Название",name,"Название типа в списке выбора. Не добавляет подпись на линии.")
        addField(form,"Описание",descriptionField,"Смысл этого типа связи. Подставляется в легенду, пока у её строки не задано собственное описание.")
        fill(line,DiagramStyleOptions.edgeLines); fill(direction,DiagramStyleOptions.directions); fill(route,DiagramStyleOptions.routes)
        fill(head,DiagramStyleOptions.arrows); fill(tail,DiagramStyleOptions.arrows)
        fill(colorMode,[("theme","По теме"),("inverse","Чёрный/белый по теме"),("custom","Свой цвет")]); fill(textMode,[("theme","По теме"),("inverse","Чёрный/белый по теме"),("custom","Свой цвет")])
        addField(form,"Линия",line,"Общий стиль обводки всех связей этого типа.")
        addField(form,"Направление",direction,"Показывает наконечник у цели, на обоих концах или скрывает наконечники.")
        addField(form,"Маршрут",route,"Общий способ прокладки: настройка проекта, прямая, ломаная, прямоугольная или кривая.")
        addField(form,"Наконечник / хвост",NSStackView(views: [head,tail]),"Формы наконечников у цели и источника. Хвост виден при направлении в обе стороны.")
        addField(form,"Цвет линии",NSStackView(views: [colorMode,color]),"Режим темы или собственный цвет линии, включая прозрачность.")
        addField(form,"Цвет текста",NSStackView(views: [textMode,textColor]),"Цвет подписей связей. Режим темы автоматически обеспечивает контраст.")
        addField(form,"Толщина, pt",width,"Толщина линии от 0.5 до 10 пунктов.")
        addField(form,"Текст, pt",fontSize,"Размер подписей от 1 до 144 пунктов.")
        addField(form,"Вес / minlen",NSStackView(views: [weight,minlen]),"Вес 0–100 влияет на компоновку; minlen 1–20 задаёт минимальное число рангов для dot.")
        addField(form,"Фон текста",transparent,"При включении под текстом не рисуется непрозрачная плашка.")
        addField(form,"Ранжирование",constraint,"Влияет ли эта связь на иерархию при компоновке dot.")
        addField(form,"Применение",applySelected,"При сохранении назначает тип всем выделенным связям. Связи, уже использующие этот тип, обновляются всегда.")
        let buttons = NSStackView(views: [ActionButton("Сохранить тип") { [weak self] in self?.saveType() }, ActionButton("Удалить тип") { [weak self] in if let self,let id = editingID { projectModel.deleteEdgeType(id); isDirty = false; loadType(nil); refresh() } }]); buttons.spacing = 8
        form.addArrangedSubview(buttons)
        let explanation = NSTextField(wrappingLabelWithString: "Правки общего типа обновляют все использующие его связи. Индивидуальная правка стиля связи отключает её от общего типа. Все изменения отменяются через ⌘Z.")
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor; form.addArrangedSubview(explanation)
        typeTab.view = scrolled(form)
        identifier.isEditable = false; identifier.isSelectable = true
        for field in [name,descriptionField,width,fontSize,weight,minlen] { field.delegate = self }
        for popup in [line,direction,route,head,tail,colorMode,textMode] { popup.target = self; popup.action = #selector(markDirty) }
        for button in [transparent,constraint,applySelected] { button.target = self; button.action = #selector(markDirty) }
        for well in [color,textColor] { well.target = self; well.action = #selector(markDirty) }
        controls += buttons.arrangedSubviews.compactMap { $0 as? NSControl }
        controls += pickerRow.arrangedSubviews.compactMap { $0 as? NSControl }
        controls += [typePicker,name,descriptionField,line,direction,route,head,tail,colorMode,textMode,width,fontSize,weight,minlen,color,textColor,transparent,constraint,applySelected]

        let legend = NSView(); legendTab.view = legend
        fill(mode,[("auto","Автоматическая легенда"),("manual","Ручная таблица")]); mode.target = self; mode.action = #selector(modeChanged)
        let heading = NSStackView(views: [HelpFieldLabel("Режим",explanation: "Автоматический собирает символы из схемы. Ручной экспортирует строки конструктора в заданном порядке, в том числе типы, которых пока нет на холсте.",identifier: "legend-mode-help"),mode]); heading.spacing = 8
        for (id,title) in [("symbol","Объект или тип связи"),("description","Описание")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = id == "symbol" ? 230 : 310
            column.minWidth = id == "symbol" ? 160 : 180; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 36; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let addNode = ActionButton("+ Объект") { [weak self] in self?.appendLegend(type: false) }
        let addEdge = ActionButton("+ Тип связи") { [weak self] in self?.appendLegend(type: true) }
        let remove = ActionButton("−") { [weak self] in self?.removeLegend() }
        let up = ActionButton("↑") { [weak self] in self?.moveLegend(-1) }, down = ActionButton("↓") { [weak self] in self?.moveLegend(1) }
        let reset = ActionButton("Автоописание") { [weak self] in self?.resetDescription() }
        let addActions = NSStackView(views: [addNode,addEdge,remove]); addActions.spacing = 6
        let orderActions = NSStackView(views: [up,down,reset]); orderActions.spacing = 6
        let actions = NSStackView(views: [addActions,orderActions]); actions.orientation = .vertical; actions.alignment = .leading; actions.spacing = 6
        let hint = NSTextField(wrappingLabelWithString: "В первой колонке выберите объект с холста, фигуру коллекции или тип связи. Во второй измените описание. «Автоописание» возвращает текст типа или название объекта. Строки сохраняются в проекте и используются при экспорте.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        [heading,scroll,actions,hint].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; legend.addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: legend.topAnchor,constant: 12),heading.leadingAnchor.constraint(equalTo: legend.leadingAnchor,constant: 12),heading.trailingAnchor.constraint(equalTo: legend.trailingAnchor,constant: -12),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor,constant: 10),scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),scroll.bottomAnchor.constraint(equalTo: actions.topAnchor,constant: -10),
            actions.leadingAnchor.constraint(equalTo: heading.leadingAnchor),actions.bottomAnchor.constraint(equalTo: hint.topAnchor,constant: -10),
            hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor),hint.trailingAnchor.constraint(equalTo: heading.trailingAnchor),hint.bottomAnchor.constraint(equalTo: legend.bottomAnchor,constant: -12)
        ])
        controls += [mode,addNode,addEdge,remove,up,down,reset]
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        tabs.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs); content.addSubview(status)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 12),tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -12),tabs.topAnchor.constraint(equalTo: content.topAnchor,constant: 12),tabs.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -8),status.leadingAnchor.constraint(equalTo: tabs.leadingAnchor),status.trailingAnchor.constraint(equalTo: tabs.trailingAnchor),status.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -10)])
    }

    private func scrolled(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedLibraryView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,constant: 12),stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,constant: -12),stack.topAnchor.constraint(equalTo: document.topAnchor,constant: 12),stack.bottomAnchor.constraint(equalTo: document.bottomAnchor,constant: -12)])
        return scroll
    }
    private func addField(_ stack: NSStackView,_ title: String,_ view: NSView,_ help: String) {
        let label = HelpFieldLabel(title,explanation: help,identifier: "library-\(title)")
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let row = NSStackView(views: [label,view]); row.alignment = .centerY; row.spacing = 8
        stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let nested = view as? NSStackView { nested.spacing = 8 }
        if let control = view as? NSControl { control.setContentHuggingPriority(.defaultLow,for: .horizontal) }
    }
    private func fill(_ popup: NSPopUpButton,_ choices: [(value: String,title: String)]) { for choice in choices { popup.addItem(withTitle: choice.title); popup.lastItem?.representedObject = choice.value } }
    private func select(_ popup: NSPopUpButton,_ value: String) { popup.selectItem(at: popup.itemArray.firstIndex { $0.representedObject as? String == value } ?? 0) }
    private func value(_ popup: NSPopUpButton) -> String { popup.selectedItem?.representedObject as? String ?? "" }
    private func defaultStyle() -> EdgeStyle { EdgeStyle(colorMode: "theme",textMode: "theme",lineStyle: "solid",color: "#64748B",penwidth: 1.5,arrowhead: "normal",arrowtail: "none",constraint: true,weight: 1,minlen: 1,labelBackgroundTransparent: true) }
    private func loadType(_ id: String?) {
        isPopulating = true; defer { isPopulating = false }
        let definition = definitions.first { $0.id == id }
        editingID = definition?.id; identifier.stringValue = definition?.id ?? "type_\(UUID().uuidString.prefix(8).lowercased())"
        name.stringValue = definition?.name ?? "Новый тип"; descriptionField.stringValue = definition?.description ?? ""
        let style = definition?.style ?? defaultStyle()
        select(line,style.lineStyle); select(direction,definition?.direction ?? "forward"); select(route,definition?.routing ?? "")
        select(head,style.arrowhead); select(tail,style.arrowtail); select(colorMode,style.colorMode ?? "custom"); select(textMode,style.textMode ?? "custom")
        color.color = NSColor(hex: style.color); textColor.color = NSColor(hex: style.text ?? "#172238")
        width.stringValue = String(style.penwidth); fontSize.stringValue = String(style.effectiveFontSize); weight.stringValue = String(style.weight); minlen.stringValue = String(style.minlen)
        transparent.state = style.effectiveLabelBackgroundTransparent ? .on : .off; constraint.state = style.constraint ? .on : .off
        applySelected.state = .off; isDirty = false
    }
    private func createType(fromSelection: Bool) {
        editingID = nil; typePicker.selectItem(at: 0); loadType(nil)
        if fromSelection,let edge = projectModel.edges.first(where: { projectModel.selection.edgeIDs.contains($0.id) }) {
            name.stringValue = edge.label.isEmpty ? "Новый тип" : edge.label
            select(line,edge.style.lineStyle); select(direction,edge.direction); select(route,edge.routing ?? "")
            select(head,edge.style.arrowhead); select(tail,edge.style.arrowtail)
            select(colorMode,edge.style.colorMode ?? "custom"); select(textMode,edge.style.textMode ?? "custom")
            color.color = NSColor(hex: edge.style.color); textColor.color = NSColor(hex: edge.style.text ?? "#172238")
            width.stringValue = String(edge.style.penwidth); fontSize.stringValue = String(edge.style.effectiveFontSize)
            weight.stringValue = String(edge.style.weight); minlen.stringValue = String(edge.style.minlen)
            transparent.state = edge.style.effectiveLabelBackgroundTransparent ? .on : .off; constraint.state = edge.style.constraint ? .on : .off
            applySelected.state = .on
        }
        isDirty = true
    }
    private func saveType() {
        guard !projectModel.isEditingLocked else { return }
        window?.makeFirstResponder(nil)
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,title.unicodeScalars.count<=120,descriptionField.stringValue.unicodeScalars.count<=2000,
              let pen = Double(width.stringValue),pen.isFinite,(0.5...10).contains(pen),
              let font = Double(fontSize.stringValue),font.isFinite,(1...144).contains(font),
              let w = Int(weight.stringValue),(0...100).contains(w),let m = Int(minlen.stringValue),(1...20).contains(m) else {
            status.stringValue = "Проверьте название и диапазоны числовых полей (подсказки рядом с полями)."; return
        }
        var style = defaultStyle(); style.lineStyle = value(line); style.penwidth = pen; style.fontSize = font
        style.colorMode = value(colorMode); style.textMode = value(textMode); style.color = color.color.hexRGBA; style.text = textColor.color.hexRGBA
        style.arrowhead = value(head); style.arrowtail = value(tail); style.weight = w; style.minlen = m
        style.constraint = constraint.state == .on; style.labelBackgroundTransparent = transparent.state == .on
        let id = identifier.stringValue
        let definition = EdgeTypeDefinition(id: id,name: title,description: descriptionField.stringValue,style: style,direction: value(direction),routing: value(route).isEmpty ? nil : value(route))
        editingID = id; isDirty = false
        projectModel.saveEdgeType(definition,applyingTo: applySelected.state == .on ? projectModel.selection.edgeIDs : [])
        lastProject = nil; refresh(); status.stringValue = "Тип сохранён. Связи обновлены."
    }
    @objc private func pickedType() {
        let requested = value(typePicker)
        if isDirty {
            let alert = NSAlert(); alert.messageText = "Сохранить изменения типа перед переключением?"; alert.addButton(withTitle: "Сохранить"); alert.addButton(withTitle: "Отменить правки")
            if alert.runModal() == .alertFirstButtonReturn { saveType(); if isDirty { select(typePicker,editingID ?? ""); return } }
        }
        select(typePicker,requested); loadType(requested.isEmpty ? nil : requested)
    }
    @objc private func markDirty() { if !isPopulating { isDirty = true } }
    func controlTextDidChange(_ obj: Notification) { if !isPopulating && !(obj.object is LegendDescriptionField) { isDirty = true } }
    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? LegendDescriptionField { descriptionChanged(field) }
    }
    @objc private func modeChanged() { projectModel.updateLegend(mode: value(mode),entries: rows) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard rows.indices.contains(row),let project = projectModel.diagram else { return nil }
        let entry = rows[row]
        if column?.identifier.rawValue == "symbol" {
            let popup = NSPopUpButton(); popup.tag = row; popup.target = self; popup.action = #selector(symbolChanged(_:))
            for node in project.nodes { popup.addItem(withTitle: "Объект: \(node.label.isEmpty ? node.id : node.label)"); popup.lastItem?.representedObject = "node:\(node.id)"; if let icon = node.icon { popup.lastItem?.image = CanvasGeometry.thumbnail(icon: icon) } }
            for type in definitions { popup.addItem(withTitle: "Связь: \(type.name)"); popup.lastItem?.representedObject = "type:\(type.id)"; popup.lastItem?.image = LegendSymbols.image(type,theme: project.presentation.theme) }
            for item in PaletteLibrary.allObjects {
                popup.addItem(withTitle: "Фигура: \(item.title)"); popup.lastItem?.representedObject = "figure:\(item.id)"
                popup.lastItem?.image = CanvasGeometry.thumbnail(icon: item.iconPath)
            }
            let selected: String
            if let id = entry.nodeId { selected = "node:\(id)" }
            else if let id = entry.edgeTypeId { selected = "type:\(id)" }
            else { selected = "figure:\(PaletteLibrary.allObjects.first(where: { $0.iconPath == entry.icon && $0.shape == entry.shape })?.id ?? "")" }
            select(popup,selected); popup.isEnabled = !projectModel.isEditingLocked
            return popup
        }
        let field = LegendDescriptionField(string: resolvedDescription(entry,in: project)); field.rowID = entry.id; field.originalValue = field.stringValue
        field.isEditable = !projectModel.isEditingLocked; field.delegate = self; field.target = self; field.action = #selector(descriptionChanged(_:))
        field.placeholderString = "Описание"; field.toolTip = "Пустое значение — пустая ячейка. Для возвращения текста типа нажмите «Автоописание»."
        field.font = .systemFont(ofSize: 12); return field
    }
    private func resolvedDescription(_ entry: LegendEntry,in project: DiagramProject) -> String {
        entry.description ?? entry.edgeTypeId.flatMap { id in definitions.first { $0.id == id }?.description }
            ?? entry.nodeId.flatMap { id in project.nodes.first { $0.id == id }?.label }
            ?? PaletteLibrary.allObjects.first { $0.iconPath == entry.icon && $0.shape == entry.shape }?.title ?? ""
    }
    @objc private func symbolChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        var updated = rows; let token = value(sender)
        var entry = LegendEntry(id: updated[sender.tag].id,kind: "node",description: updated[sender.tag].description)
        if token.hasPrefix("node:") { entry.nodeId = String(token.dropFirst(5)) }
        else if token.hasPrefix("type:") { entry.kind = "edge_type"; entry.edgeTypeId = String(token.dropFirst(5)) }
        else if let item = PaletteLibrary.object(id: String(token.dropFirst(7))) { entry.icon = item.iconPath; entry.shape = item.shape; if entry.description == nil { entry.description = item.title } }
        updated[sender.tag] = entry; projectModel.updateLegend(mode: "manual",entries: updated)
    }
    @objc private func descriptionChanged(_ sender: LegendDescriptionField) {
        guard sender.stringValue != sender.originalValue else { return }
        guard sender.stringValue.unicodeScalars.count<=2000,let index = rows.firstIndex(where: { $0.id == sender.rowID }) else { status.stringValue = "Описание — до 2000 символов."; return }
        var updated = rows; updated[index].description = sender.stringValue; projectModel.updateLegend(mode: "manual",entries: updated)
    }
    private func appendLegend(type: Bool) {
        guard rows.count<500 else { return }
        var entry = LegendEntry(id: "legend_\(UUID().uuidString.prefix(8).lowercased())",kind: type ? "edge_type" : "node")
        if type { guard let definition = definitions.first else { status.stringValue = "Сначала создайте тип связи на соседней вкладке."; return }; entry.edgeTypeId = definition.id }
        else {
            entry.nodeId = projectModel.nodes.first?.id
            if entry.nodeId == nil,let item = PaletteLibrary.allObjects.first { entry.icon = item.iconPath; entry.shape = item.shape; entry.description = item.title }
        }
        projectModel.updateLegend(mode: "manual",entries: rows+[entry]); table.selectRowIndexes(IndexSet(integer: rows.count-1),byExtendingSelection: false)
    }
    private func removeLegend() { let row = table.selectedRow; guard rows.indices.contains(row) else { return }; var updated = rows; updated.remove(at: row); projectModel.updateLegend(mode: "manual",entries: updated) }
    private func moveLegend(_ delta: Int) { let row = table.selectedRow; guard rows.indices.contains(row),rows.indices.contains(row+delta) else { return }; var updated = rows; updated.swapAt(row,row+delta); projectModel.updateLegend(mode: "manual",entries: updated); table.selectRowIndexes(IndexSet(integer: row+delta),byExtendingSelection: false) }
    private func resetDescription() { let row = table.selectedRow; guard rows.indices.contains(row) else { return }; var updated = rows; updated[row].description = nil; projectModel.updateLegend(mode: "manual",entries: updated) }

}

private final class FlippedLibraryView: NSView { override var isFlipped: Bool { true } }
private final class LegendDescriptionField: NSTextField { var rowID = ""; var originalValue = "" }
