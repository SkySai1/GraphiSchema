import AppKit

@MainActor
final class ActionButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
        bezelStyle = .rounded
        target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func invoke() { handler() }
}

@MainActor
private func promptName(window: NSWindow?, title: String, detail: String, initial: String, completion: @escaping (String) -> Void) {
    guard let window else { return }
    let alert = NSAlert()
    alert.messageText = title; alert.informativeText = detail
    let field = NSTextField(string: initial)
    field.identifier = NSUserInterfaceItemIdentifier("management-name")
    field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Создать"); alert.addButton(withTitle: "Отмена")
    alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    window.attachedSheet?.makeFirstResponder(field)
}

@MainActor
final class ProjectManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate, ProjectThemedWindow {
    var projectModel: AppModel { model }
    private let model: AppModel
    private let onOpen: (ProjectWorkspace, Bool) -> Void
    private let table = NSTableView()
    private let search = NSSearchField()
    private let branch = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private var projects: [ProjectSummary] = []
    private var filtered: [ProjectSummary] = []
    private var branches: [BranchSummary] = []
    private var loadTask: Task<Void, Never>?
    private var branchTask: Task<Void, Never>?
    private var openButtons: [NSButton] = []

    init(model: AppModel, onOpen: @escaping (ProjectWorkspace, Bool) -> Void) {
        self.model = model; self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Менеджер схем"; window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reloadAndShow() {
        showNearCursor(nil)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let projects = try await model.fetchProjects()
                guard !Task.isCancelled else { return }
                self.projects = projects
                filterProjects()
                status.stringValue = "Схем: \(projects.count). Выберите проект и ветку."
            } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let project = filtered[row]
        let value = switch tableColumn?.identifier.rawValue {
        case "title": project.title
        case "branches": String(project.branchCount)
        case "date": project.updatedAt.replacingOccurrences(of: "T", with: " ")
        default: project.id
        }
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 11); field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        return field
    }
    func controlTextDidChange(_ notification: Notification) { filterProjects() }
    func tableViewSelectionDidChange(_ notification: Notification) { loadBranches() }
    private var selected: ProjectSummary? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    private var selectedWorkspace: ProjectWorkspace? {
        guard branches.indices.contains(branch.indexOfSelectedItem) else { return nil }
        return branches[branch.indexOfSelectedItem].workspace
    }
    private func filterProjects() {
        let id = selected?.id, query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = projects.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: filtered.firstIndex { $0.id == id } ?? 0), byExtendingSelection: false) }
        loadBranches()
    }
    private func loadBranches() {
        branchTask?.cancel(); branches = []; branch.removeAllItems()
        openButtons.forEach { $0.isEnabled = false }
        guard let selected else { return }
        branchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let choices = try await model.fetchBranches(projectID: selected.id)
                guard !Task.isCancelled, self.selected?.id == selected.id else { return }
                branches = choices
                branch.addItems(withTitles: choices.map { "\($0.name) · коммит №\($0.headVersionNumber ?? $0.headVersionId)" })
                if let current = choices.firstIndex(where: { $0.id == self.model.branchID }) { branch.selectItem(at: current) }
                openButtons.forEach { $0.isEnabled = !choices.isEmpty }
            } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
        }
    }
    func createProject() {
        promptName(window: window, title: "Новая схема", detail: "Создаётся независимый проект с пустым холстом и веткой main.", initial: "Новая схема") { [weak self] title in
            guard let self else { return }
            Task { do { let target = try await self.model.createProject(title: title); self.reloadAndShow(); self.onOpen(target, true) }
                   catch { self.status.stringValue = error.localizedDescription } }
        }
    }
    private func forkSelected() {
        guard let target = selectedWorkspace, let selected else { return }
        promptName(window: window, title: "Форк схемы", detail: "Копия выбранной ветки получит новый ID проекта. Исходная схема сохранится.", initial: "\(selected.title) — форк") { [weak self] title in
            guard let self else { return }
            Task { do { let fork = try await self.model.forkWorkspace(target, title: title); self.reloadAndShow(); self.onOpen(fork, true) }
                   catch { self.status.stringValue = error.localizedDescription } }
        }
    }
    private func build() {
        guard let content = window?.contentView else { return }
        search.identifier = NSUserInterfaceItemIdentifier("project-manager-search")
        search.placeholderString = "Поиск по названию или ID"; search.delegate = self
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        table.identifier = NSUserInterfaceItemIdentifier("project-manager-table")
        for (id, title, width) in [("title", "Проект", 310.0), ("branches", "Ветки", 60.0), ("date", "Изменён (UTC)", 180.0), ("id", "ID", 320.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let create = ActionButton("Новая схема", symbol: "plus") { [weak self] in self?.createProject() }
        create.identifier = NSUserInterfaceItemIdentifier("project-manager-create")
        let refresh = ActionButton("Обновить", symbol: "arrow.clockwise") { [weak self] in self?.reloadAndShow() }
        let top = NSStackView(views: [search, create, refresh]); top.orientation = .horizontal; top.spacing = 8
        let open = ActionButton("Открыть здесь") { [weak self] in if let self, let target = selectedWorkspace { onOpen(target, false) } }
        let newWindow = ActionButton("В новом окне", symbol: "macwindow.on.rectangle") { [weak self] in if let self, let target = selectedWorkspace { onOpen(target, true) } }
        let fork = ActionButton("Форк проекта", symbol: "arrow.triangle.branch") { [weak self] in self?.forkSelected() }
        openButtons = [open, newWindow, fork]
        open.identifier = NSUserInterfaceItemIdentifier("project-manager-open")
        newWindow.identifier = NSUserInterfaceItemIdentifier("project-manager-new-window")
        branch.identifier = NSUserInterfaceItemIdentifier("project-manager-branch")
        let bottom = NSStackView(views: [branch, open, newWindow, fork]); bottom.orientation = .horizontal; bottom.spacing = 8
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
        [top, scroll, bottom, status].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), top.heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: top.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10), bottom.heightAnchor.constraint(equalToConstant: 30),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor), status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }
    func windowWillClose(_ notification: Notification) { loadTask?.cancel(); branchTask?.cancel() }
}

@MainActor
final class ApplicationSettingsWindowController: NSWindowController, ProjectThemedWindow {
    var projectModel: AppModel { model }
    private let model: AppModel
    private let sizeLabel = NSTextField(labelWithString: "Загрузка размера базы…")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private var loadTask: Task<Void, Never>?
    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки GraphiSchema"
        super.init(window: window)
        build(); AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func reloadAndShow() {
        showNearCursor(nil)
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let info = try await model.fetchStorageInfo()
                guard !Task.isCancelled else { return }
                sizeLabel.stringValue = "\(ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file)) · проектов: \(info.projectCount) · коммитов: \(info.versionCount)"
                sizeLabel.toolTip = "База: \(info.databaseBytes) байт; WAL: \(info.walBytes); SHM: \(info.shmBytes). Всего: \(info.totalBytes) байт."
                pathLabel.stringValue = info.databasePath
            } catch { sizeLabel.stringValue = error.localizedDescription }
        }
    }
    private func build() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        let mode = NSPopUpButton(); mode.identifier = NSUserInterfaceItemIdentifier("settings-theme")
        for (value, title) in [("system", "Системная"), ("light", "Светлая"), ("dark", "Тёмная")] {
            mode.addItem(withTitle: title); mode.lastItem?.representedObject = value
        }
        if let item = mode.itemArray.first(where: { ($0.representedObject as? String) == model.themeMode }) { mode.select(item) }
        mode.target = self; mode.action = #selector(changeTheme(_:))
        root.addArrangedSubview(HelpFieldLabel("Тема", explanation: "Системная следует оформлению macOS. Светлая и тёмная задаются вручную для открытой схемы.", identifier: "settings-theme-help"))
        root.addArrangedSubview(mode)
        let inverse = NSButton(checkboxWithTitle: "Обратное движение холста на тачпаде", target: self, action: #selector(changeInverse(_:)))
        inverse.state = model.inverseTrackpad ? .on : .off
        let nav = NSStackView(views: [inverse, HelpIconButton("При включении холст движется против направления пальцев по обеим осям. При выключении следует за пальцами.", identifier: "settings-inverse-help")])
        nav.orientation = .horizontal; root.addArrangedSubview(nav)
        let starter = NSButton(checkboxWithTitle: "Загружать базовый шаблон при запуске", target: self, action: #selector(changeStarter(_:)))
        starter.state = model.loadStarterOnLaunch ? .on : .off
        let template = NSStackView(views: [starter, HelpIconButton("Заполняет пустую стартовую схему базовым примером. Существующая диаграмма сохраняется.", identifier: "settings-template-help")])
        template.orientation = .horizontal; root.addArrangedSubview(template)
        root.addArrangedSubview(HelpFieldLabel("Размер базы данных", explanation: "Фактический размер SQLite вместе с файлами журнала WAL и разделяемой памяти SHM. Обновляется при открытии настроек и по кнопке.", identifier: "settings-database-help"))
        sizeLabel.identifier = NSUserInterfaceItemIdentifier("settings-database-size")
        sizeLabel.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(sizeLabel)
        pathLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular); pathLabel.isSelectable = true
        pathLabel.maximumNumberOfLines = 2; pathLabel.widthAnchor.constraint(equalToConstant: 470).isActive = true
        root.addArrangedSubview(pathLabel)
        let alignment = NSButton(checkboxWithTitle: "Помощь в выравнивании объектов", target: self, action: #selector(changeAlignment(_:)))
        alignment.state = model.alignmentGuides ? .on : .off; alignment.identifier = NSUserInterfaceItemIdentifier("settings-alignment")
        root.addArrangedSubview(NSStackView(views: [alignment, HelpIconButton("При перемещении притягивает границы и центры объектов на расстоянии до 6 экранных точек. Розовые направляющие показывают совпадение. Cmd+Shift+A включает или выключает помощь.", identifier: "settings-alignment-help")]))
        let config = NSTextField(wrappingLabelWithString: "Настройки: \(SettingsStore.shared.fileURL.path)")
        config.font = .systemFont(ofSize: 10); config.isSelectable = true; config.widthAnchor.constraint(equalToConstant: 470).isActive = true
        root.addArrangedSubview(config)
        root.addArrangedSubview(ActionButton("Обновить размер", symbol: "arrow.clockwise") { [weak self] in self?.reloadAndShow() })
        window?.contentView = NSView(); guard let content = window?.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        window?.setContentSize(NSSize(width: 510, height: max(320, root.fittingSize.height)))
    }
    @objc private func changeTheme(_ sender: NSPopUpButton) { if let mode = sender.selectedItem?.representedObject as? String { model.updateThemeMode(mode) } }
    @objc private func changeAlignment(_ sender: NSButton) { model.alignmentGuides = sender.state == .on }
    @objc private func changeInverse(_ sender: NSButton) { model.inverseTrackpad = sender.state == .on }
    @objc private func changeStarter(_ sender: NSButton) { model.loadStarterOnLaunch = sender.state == .on }
}
