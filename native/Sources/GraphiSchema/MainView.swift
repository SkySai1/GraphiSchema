import AppKit
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
private final class ThemeRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    private let model: AppModel
    private let rootView = ThemeRootView()
    private let sidebar = SidebarView()
    private let workspace = WorkspaceView()
    private let codePanel = JSONCodePanelView()
    private let splitView = NSSplitView()
    private var styleInspector: InspectorView?
    private var styleWindowController: NSWindowController?
    private var nodeTextEditorController: NodeTextEditorWindowController?
    private var historyWindowController: VersionHistoryWindowController?
    private(set) var pendingPDFExportAlert: NSAlert?
    private let titleField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "Подключение…")
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var ollamaWindowController: OllamaAssistantWindowController?
    private var retainedActions: [ControlAction] = []
    private var didSetInitialSplitPositions = false
    private var sidebarVisible = true
    private var codePanelVisible = true
    private var projectFileURL = UserDefaults.standard.string(forKey: "GraphiSchema.projectFile").map(URL.init(fileURLWithPath:))
    private var sidebarMinimumWidth: NSLayoutConstraint?
    private var codeMinimumWidth: NSLayoutConstraint?
    private var menuItems: [String: NSMenuItem] = [:]
    private var lastCanvasDiagram: DiagramProject?
    private var lastCanvasLayout: DiagramLayout?
    private var lastCanvasSelection: DiagramSelection?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1580, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GraphiSchema"
        window.minSize = NSSize(width: 960, height: 620)
        window.center()
        super.init(window: window)
        window.contentView = rootView
        buildInterface()
        connectModel()
        installMainMenu()
        rootView.onAppearanceChange = { [weak self] in self?.model.updateSystemTheme() }
        AppTheme.configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshAll() {
        refreshSidebar()
        refreshInspector()
        refreshCanvas(force: true)
        codePanel.refresh(model: model)
        refreshHeader()
    }

    private func buildInterface() {
        rootView.wantsLayer = true
        rootView.layer?.name = "theme-surface-window"
        rootView.layer?.backgroundColor = AppTheme.surface("window").cgColor

        let header = buildHeader()
        let divider = NSBox()
        divider.boxType = .separator
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(workspace)
        splitView.addArrangedSubview(codePanel)
        sidebar.setContentCompressionResistancePriority(.required, for: .horizontal)
        codePanel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [header, divider, splitView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 46),
            divider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        sidebarMinimumWidth = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 225)
        codeMinimumWidth = codePanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 380)
        sidebarMinimumWidth?.isActive = true
        codeMinimumWidth?.isActive = true
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !didSetInitialSplitPositions,
              let splitView = notification.object as? NSSplitView,
              splitView.bounds.width > 1000 else { return }
        didSetInitialSplitPositions = true
        splitView.setPosition(250, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - 420, ofDividerAt: 1)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 && !sidebarVisible { return 0 }
        if dividerIndex == 1 && !codePanelVisible { return splitView.subviews[0].frame.width + splitView.subviews[1].frame.width }
        if dividerIndex == 0 { return 225 }
        return splitView.subviews[0].frame.width + splitView.dividerThickness + 350
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 && !sidebarVisible { return 0 }
        if dividerIndex == 1 && !codePanelVisible { return splitView.bounds.width - splitView.dividerThickness }
        if dividerIndex == 0 { return 310 }
        return splitView.bounds.width - 380 - splitView.dividerThickness
    }

    private func buildHeader() -> NSView {
        let mark = NSTextField(labelWithString: "G")
        mark.font = .systemFont(ofSize: 20, weight: .heavy)
        mark.textColor = .white
        mark.alignment = .center
        mark.wantsLayer = true
        mark.layer?.backgroundColor = NSColor(hex: "#3867E8").cgColor
        mark.layer?.cornerRadius = 9
        mark.widthAnchor.constraint(equalToConstant: 38).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let brandText = NSStackView(views: [
            makeLabel("GraphiSchema", size: 14, weight: .bold),
            makeLabel("ARCHITECTURE WORKSPACE", size: 8, weight: .medium, color: .secondaryLabelColor),
        ])
        brandText.orientation = .vertical
        brandText.alignment = .leading
        brandText.spacing = 2
        let brand = NSStackView(views: [mark, brandText])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10
        brand.widthAnchor.constraint(equalToConstant: 175).isActive = true

        let titleStack = NSStackView(views: [
            makeLabel("ЛОКАЛЬНЫЙ ПРОЕКТ", size: 8, weight: .bold, color: .secondaryLabelColor),
            titleField,
        ])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.placeholderString = "Название диаграммы"
        titleField.target = self
        titleField.action = #selector(titleChanged(_:))

        let statusDot = NSImageView()
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.contentTintColor = NSColor(hex: "#35AE78")
        statusDot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [statusDot, statusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 7
        status.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        undoButton = makeButton("Отменить", symbol: "arrow.uturn.backward") { [weak self] _ in self?.performHistoryCommand(redo: false) }
        undoButton?.keyEquivalent = "z"
        undoButton?.keyEquivalentModifierMask = .command
        redoButton = makeButton("Повторить", symbol: "arrow.uturn.forward") { [weak self] _ in self?.performHistoryCommand(redo: true) }
        redoButton?.keyEquivalent = "y"
        redoButton?.keyEquivalentModifierMask = .command
        let saveButton = makeButton("Сохранить", symbol: "checkmark.circle.fill", prominent: true) { [weak self] _ in self?.saveProject() }

        let stack = NSStackView(views: [brand, titleStack, status, NSView(), undoButton!, redoButton!, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func connectModel() {
        sidebar.onAddNode = { [weak self] item in self?.model.addNode(item) }
        sidebar.onAddContainer = { [weak self] in self?.model.addContainer() }
        sidebar.onSelect = { [weak self] selection in
            self?.model.selection = selection
            self?.refreshInspector()
            self?.refreshSidebar()
            if let self { self.refreshCanvas(force: true) }
        }
        sidebar.onShowProperties = { [weak self] in self?.showStyleWindow() }
        workspace.onSelectElement = { [weak self] selection in
            guard let self else { return }
            self.model.selection = selection
            self.refreshInspector()
            self.refreshSidebar()
            self.refreshCanvas(force: true)
        }
        workspace.onMoveNode = { [weak self] id, x, y, containerID in
            self?.model.moveNode(id, x: x, y: y, containerID: containerID)
        }
        workspace.onDetachNodeFromContainer = { [weak self] id in self?.model.detachNodeFromContainer(id) }
        workspace.onSetNodeZIndex = { [weak self] id, value in self?.model.setNodeZIndex(id, value) }
        workspace.onMoveNodeInStack = { [weak self] id, front in
            if front { self?.model.moveNodeToFront(id) } else { self?.model.moveNodeToBack(id) }
        }
        workspace.onMoveNodes = { [weak self] ids, dx, dy in self?.model.moveNodes(ids, deltaX: dx, deltaY: dy) }
        workspace.onScaleNodes = { [weak self] ids, factor in self?.model.scaleNodes(ids, factor: factor) }
        workspace.onEditNodeText = { [weak self] id in self?.showNodeTextEditor(id) }
        workspace.onResizeNode = { [weak self] id, width, height in
            self?.model.editNode(id) { $0.width = width; $0.height = height }
        }
        workspace.onSetEdgeWaypoints = { [weak self] id, points, positions in
            self?.model.setEdgeWaypoints(id, points: points, positions: positions)
        }
        workspace.onReattachEdge = { [weak self] id, source, nodeID in
            self?.model.setEdgeEndpoint(id, source: source, nodeID: nodeID)
        }
        workspace.onCreateEdge = { [weak self] source, target in
            self?.model.addEdge(from: source, to: target)
        }
        workspace.onMoveContainer = { [weak self] id, x, y in
            self?.model.moveContainer(id, deltaX: x, deltaY: y)
        }
        workspace.onResizeContainer = { [weak self] id, padding in
            self?.model.editContainer(id) { $0.padding = padding }
        }
        workspace.onResizeEmptyContainer = { [weak self] id, width, height in
            self?.model.resizeContainer(id, width: width, height: height)
        }
        workspace.onOptimizeRoutes = { [weak self] in self?.model.optimizeAllRoutes() }
        workspace.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        workspace.onToggleCodePanel = { [weak self] in self?.toggleCodePanel() }
        workspace.onToggleChat = { [weak self] in
            guard let self else { return }
            self.workspace.setChatVisible(!self.workspace.isChatVisible)
        }
        workspace.onDropPaletteItem = { [weak self] item, x, y, containerID in
            guard let self else { return }
            self.model.addNode(item, at: (x: x, y: y), inContainer: containerID)
            Task { @MainActor in
                do { try await self.model.saveNow() }
                catch { self.showAlert("Не удалось сохранить добавленный объект: \(error.localizedDescription)") }
            }
        }
        workspace.onShowStyle = { [weak self] in self?.showStyleWindow() }
        workspace.onConfigureOllama = { [weak self] in self?.showOllamaAssistant() }
        workspace.onOllamaMessage = { [weak self] prompt, mode in self?.runOllamaPrompt(prompt, mode: mode) }
        workspace.onDeleteSelection = { [weak self] in
            guard let self else { return }
            self.model.deleteSelection()
            self.refreshAll()
        }
        workspace.onApplyProposal = { [weak self] in self?.applyProposalFromChat() }
        workspace.onCancelProposal = { [weak self] in
            guard let self else { return }
            self.model.cancelCurrentProposal()
            self.workspace.appendChatMessage(role: "Ассистент", text: "Предложение отменено. Проект и его версия не изменены.")
        }

        codePanel.onSelectTab = { [weak self] tab in self?.selectTab(tab) }
        codePanel.onJSONChange = { [weak self] value in self?.model.updateJSONDraft(value) }
        codePanel.onDOTChange = { [weak self] value in self?.model.updateDOTDraft(value) }
        codePanel.onApplyJSON = { [weak self] in self?.applyJSON() }
        codePanel.onDiscardJSON = { [weak self] in self?.model.discardJSONDraft() }
        codePanel.onFormatJSON = { [weak self] in self?.formatJSONDraft() }
        codePanel.onValidateJSON = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.model.validate(); self.codePanel.refresh(model: self.model) }
        }
        codePanel.onPreviewDOT = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do { try await self.model.previewDOTDraft() }
                catch { self.showAlert(error.localizedDescription) }
            }
        }
        model.onModelChange = { [weak self] in
            guard let self else { return }
            self.refreshSidebar()
            self.refreshInspector()
            self.refreshHeader()
            self.refreshCanvasIfNeeded()
            if self.styleWindowController?.window?.isVisible == true {
                self.styleInspector?.setInteractionState(isEditingLocked: self.model.isEditingLocked)
            }
            self.workspace.refreshCounts(model: self.model)
            self.workspace.setInteractionState(model: self.model)
            self.codePanel.refresh(model: self.model)
        }
        model.onPreviewChange = { [weak self] in
            guard let self else { return }
            self.refreshCanvas(force: true)
            self.refreshInspector()
            self.refreshSidebar()
            self.refreshHeader()
            self.codePanel.refresh(model: self.model)
        }
        model.onAlert = { [weak self] message in self?.showAlert(message) }
        sidebar.update(model: model)
        refreshCanvas(force: true)
        codePanel.refresh(model: model)
        refreshHeader()
    }

    private func refreshSidebar() { sidebar.update(model: model) }
    private func refreshInspector() {
        guard let inspector = styleInspector,
              let window = styleWindowController?.window,
              window.isVisible
        else { return }
        if NSApp.windows.contains(where: { $0 is NSColorPanel && $0.isVisible }) { return }
        inspector.update(model: model)
        let targetHeight = inspector.preferredWindowContentHeight
        if abs((window.contentView?.frame.height ?? 0) - targetHeight) > 2 {
            window.setContentSize(NSSize(width: inspector.preferredWindowContentWidth, height: targetHeight))
        }
    }

    private func refreshCanvasIfNeeded() {
        guard lastCanvasDiagram != model.diagram || lastCanvasLayout != model.layout || lastCanvasSelection != model.selection else { return }
        refreshCanvas(force: true)
    }

    private func refreshCanvas(force: Bool = false) {
        guard force else { refreshCanvasIfNeeded(); return }
        workspace.refresh(model: model)
        lastCanvasDiagram = model.diagram
        lastCanvasLayout = model.layout
        lastCanvasSelection = model.selection
    }

    private func refreshHeader() {
        titleField.stringValue = model.diagram?.project.title ?? ""
        statusLabel.stringValue = model.status
        statusLabel.toolTip = model.backend.status
        AppTheme.apply(dark: model.diagram?.presentation.theme == "dark", mode: model.themeMode)
        undoButton?.isEnabled = model.history.canUndo && !model.isEditingLocked
        redoButton?.isEnabled = model.history.canRedo && !model.isEditingLocked
        menuItems["startup-template"]?.state = model.loadStarterOnLaunch ? .on : .off
        menuItems["theme-system"]?.state = model.themeMode == "system" ? .on : .off
        menuItems["theme-light"]?.state = model.themeMode == "light" ? .on : .off
        menuItems["theme-dark"]?.state = model.themeMode == "dark" ? .on : .off
        menuItems["inverse-trackpad"]?.state = model.inverseTrackpad ? .on : .off
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appRoot = NSMenuItem(title: ProcessInfo.processInfo.processName, action: nil, keyEquivalent: ""); main.addItem(appRoot)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "О GraphiSchema", action: nil, keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Завершить GraphiSchema", #selector(NSApplication.terminate(_:)), key: "q", modifiers: .command, target: NSApp))
        appRoot.submenu = appMenu

        let fileRoot = NSMenuItem(title: "Файл", action: nil, keyEquivalent: ""); main.addItem(fileRoot)
        let file = NSMenu()
        file.addItem(menuItem("Открыть проект…", #selector(openProjectFromMenu(_:)), key: "o", modifiers: .command))
        file.addItem(menuItem("Сохранить проект", #selector(saveProjectFromMenu(_:)), key: "s", modifiers: .command))
        file.addItem(menuItem("Сохранить проект как…", #selector(saveProjectAsFromMenu(_:)), key: "s", modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(menuItem("Загрузить базовый шаблон…", #selector(loadStarterFromMenu(_:))))
        file.addItem(.separator())
        file.addItem(menuItem("Импортировать JSON…", #selector(importJSONFromMenu(_:))))
        file.addItem(menuItem("Экспортировать JSON…", #selector(exportJSONFromMenu(_:))))
        file.addItem(menuItem("Экспортировать PNG…", #selector(exportPNGFromMenu(_:))))
        file.addItem(menuItem("Экспортировать PDF…", #selector(exportPDFFromMenu(_:))))
        file.addItem(menuItem("История версий…", #selector(showHistoryFromMenu(_:))))
        fileRoot.submenu = file

        let editRoot = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); main.addItem(editRoot)
        let edit = NSMenu()
        edit.addItem(menuItem("Отменить", #selector(undoFromMenu(_:)), key: "z", modifiers: .command))
        edit.addItem(menuItem("Повторить", #selector(redoFromMenu(_:)), key: "y", modifiers: .command))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editRoot.submenu = edit

        let viewRoot = NSMenuItem(title: "Вид", action: nil, keyEquivalent: ""); main.addItem(viewRoot)
        let view = NSMenu()
        view.addItem(menuItem("Показать/скрыть левую панель", #selector(toggleSidebarFromMenu(_:)), key: "1", modifiers: [.command, .option]))
        view.addItem(menuItem("Показать/скрыть свойства и код", #selector(toggleCodePanelFromMenu(_:)), key: "2", modifiers: [.command, .option]))
        view.addItem(menuItem("Показать/скрыть чат", #selector(toggleChatFromMenu(_:)), key: "3", modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(menuItem("Стиль и свойства…", #selector(showStyleFromMenu(_:))))
        view.addItem(menuItem("Оптимизировать все линии", #selector(optimizeRoutesFromMenu(_:))))
        viewRoot.submenu = view

        let settingsRoot = NSMenuItem(title: "Настройки", action: nil, keyEquivalent: ""); main.addItem(settingsRoot)
        let settings = NSMenu()
        settings.addItem(menuItem("Ollama и системный промпт…", #selector(showOllamaFromMenu(_:))))
        settings.addItem(menuItem("Переменные промпта…", #selector(showPromptVariablesFromMenu(_:))))
        let startup = menuItem("Загружать базовый шаблон при пустом проекте", #selector(toggleStarterOnLaunch(_:)))
        startup.identifier = NSUserInterfaceItemIdentifier("startup-template")
        menuItems["startup-template"] = startup; settings.addItem(startup)
        let themeRoot = NSMenuItem(title: "Цветовая тема", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (mode, title, key) in [("system", "Системная", "theme-system"), ("light", "Светлая", "theme-light"), ("dark", "Тёмная", "theme-dark")] {
            let item = menuItem(title, #selector(changeThemeFromMenu(_:)))
            item.representedObject = mode; item.identifier = NSUserInterfaceItemIdentifier(key)
            menuItems[key] = item; themeMenu.addItem(item)
        }
        themeRoot.submenu = themeMenu; settings.addItem(themeRoot)
        let inverse = menuItem("Инверсная прокрутка тачпада", #selector(toggleTrackpadFromMenu(_:)))
        inverse.identifier = NSUserInterfaceItemIdentifier("inverse-trackpad")
        menuItems["inverse-trackpad"] = inverse; settings.addItem(inverse)
        settingsRoot.submenu = settings
        NSApp.mainMenu = main
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? self
        return item
    }

    private func toggleSidebar() {
        sidebarVisible.toggle(); sidebar.isHidden = !sidebarVisible
        sidebarMinimumWidth?.isActive = sidebarVisible
        splitView.adjustSubviews()
        if sidebarVisible { splitView.setPosition(250, ofDividerAt: 0) }
        else { splitView.setPosition(0, ofDividerAt: 0) }
    }

    private func toggleCodePanel() {
        codePanelVisible.toggle(); codePanel.isHidden = !codePanelVisible
        codeMinimumWidth?.isActive = codePanelVisible
        splitView.adjustSubviews()
        if codePanelVisible { splitView.setPosition(splitView.bounds.width-420, ofDividerAt: 1) }
        else { splitView.setPosition(splitView.bounds.width-splitView.dividerThickness, ofDividerAt: 1) }
    }

    @objc private func openProjectFromMenu(_ sender: Any?) { openProjectFile() }
    @objc private func saveProjectFromMenu(_ sender: Any?) { saveProject() }
    @objc private func saveProjectAsFromMenu(_ sender: Any?) { saveProjectAs() }
    @objc private func importJSONFromMenu(_ sender: Any?) { importJSON() }
    @objc private func exportJSONFromMenu(_ sender: Any?) { exportJSON() }
    @objc private func exportPNGFromMenu(_ sender: Any?) { exportPNG() }
    @objc private func exportPDFFromMenu(_ sender: Any?) { exportPDF() }
    @objc private func showStyleFromMenu(_ sender: Any?) { showStyleWindow() }
    @objc private func showHistoryFromMenu(_ sender: Any?) { showHistory() }
    @objc private func undoFromMenu(_ sender: Any?) { performHistoryCommand(redo: false) }
    @objc private func redoFromMenu(_ sender: Any?) { performHistoryCommand(redo: true) }
    @objc private func toggleSidebarFromMenu(_ sender: Any?) { toggleSidebar() }
    @objc private func toggleCodePanelFromMenu(_ sender: Any?) { toggleCodePanel() }
    @objc private func toggleChatFromMenu(_ sender: Any?) { workspace.setChatVisible(!workspace.isChatVisible) }
    @objc private func optimizeRoutesFromMenu(_ sender: Any?) { model.optimizeAllRoutes() }
    @objc private func showOllamaFromMenu(_ sender: Any?) { showOllamaAssistant() }
    @objc private func showPromptVariablesFromMenu(_ sender: Any?) { showOllamaAssistant(showVariables: true) }
    @objc private func changeThemeFromMenu(_ sender: NSMenuItem) { model.updateThemeMode(sender.representedObject as? String ?? "system") }
    @objc private func toggleTrackpadFromMenu(_ sender: NSMenuItem) { model.inverseTrackpad.toggle() }
    @objc private func toggleStarterOnLaunch(_ sender: NSMenuItem) { model.loadStarterOnLaunch.toggle() }
    @objc private func loadStarterFromMenu(_ sender: Any?) { loadStarterTemplate() }

    private func selectTab(_ tab: WorkspaceTab) {
        Task { @MainActor in
            await model.selectTab(tab)
            codePanel.refresh(model: model)
            refreshHeader()
        }
    }

    private func formatJSONDraft() {
        guard model.activeProposal == nil else { return }
        guard let data = model.jsonDraft.data(using: .utf8) else { return }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            let formatted = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            guard let text = String(data: formatted, encoding: .utf8) else { return }
            codePanel.applyFormattedJSON(text)
        } catch {
            showAlert("JSON не удалось отформатировать: \(error.localizedDescription)")
        }
    }

    func showStyleWindow() {
        guard !model.isEditingLocked else {
            showAlert("Сначала примените или сбросьте текущий черновик.")
            return
        }
        guard model.diagram != nil else {
            showAlert("Дождитесь загрузки проекта, прежде чем открывать настройки.")
            return
        }
        let inspector: InspectorView
        if let existing = styleInspector {
            inspector = existing
        } else {
            inspector = InspectorView()
            inspector.frame = NSRect(x: 0, y: 0, width: inspector.preferredWindowContentWidth, height: 420)
            inspector.onDelete = { [weak self] in
                guard let self else { return }
                self.model.deleteSelection()
                self.refreshAll()
            }
            styleInspector = inspector
        }
        inspector.update(model: model)
        if let controller = styleWindowController {
            controller.window?.setContentSize(NSSize(width: inspector.preferredWindowContentWidth, height: inspector.preferredWindowContentHeight))
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            controller.window?.layoutIfNeeded()
            inspector.layoutSubtreeIfNeeded()
            return
        }
        let contentHeight = inspector.preferredWindowContentHeight
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: inspector.preferredWindowContentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Оформление и свойства"
        window.minSize = NSSize(width: 340, height: 280)
        inspector.frame = NSRect(x: 0, y: 0, width: inspector.preferredWindowContentWidth, height: contentHeight)
        inspector.autoresizingMask = [.width, .height]
        window.contentView = inspector
        AppTheme.configure(window)
        window.setContentSize(NSSize(width: inspector.preferredWindowContentWidth, height: contentHeight))
        let controller = NSWindowController(window: window)
        styleWindowController = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
        controller.window?.layoutIfNeeded()
        inspector.layoutSubtreeIfNeeded()
    }

    private func showNodeTextEditor(_ id: String) {
        guard let node = model.nodes.first(where: { $0.id == id }) else { return }
        let controller = NodeTextEditorWindowController(node: node) { [weak self] label, horizontal, vertical in
            self?.model.editNode(id) {
                $0.label = label
                $0.labelAlignment = horizontal
                $0.labelVerticalAlignment = vertical
            }
        }
        nodeTextEditorController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func applyJSON() {
        Task { @MainActor in
            do {
                try await model.applyJSONDraft()
                refreshAll()
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    private func saveProject() {
        Task { @MainActor in
            guard let projectFileURL else { saveProjectAs(); return }
            do {
                try await prepareForFileSave()
                try model.exportData().write(to: projectFileURL, options: .atomic)
                model.status = "Сохранено · \(projectFileURL.lastPathComponent)"
                refreshHeader()
            } catch { showAlert("Не удалось сохранить проект: \(error.localizedDescription)"); refreshHeader() }
        }
    }

    private func saveProjectAs() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await prepareForFileSave()
                let panel = NSSavePanel()
                panel.appearance = NSApp.appearance
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "\((model.diagram?.project.title ?? "graphischema-project").replacingOccurrences(of: "/", with: "-" )).json"
                panel.beginSheetModal(for: window!) { [weak self] response in
                    guard response == .OK, let url = panel.url, let self else { return }
                    do {
                        try self.model.exportData().write(to: url, options: .atomic)
                        self.setProjectFile(url)
                        self.model.status = "Сохранено · \(url.lastPathComponent)"
                        self.refreshHeader()
                    } catch { self.showAlert("Не удалось сохранить файл: \(error.localizedDescription)") }
                }
            } catch { showAlert("Не удалось подготовить проект к сохранению: \(error.localizedDescription)") }
        }
    }

    private func prepareForFileSave() async throws {
        guard model.activeProposal == nil else { throw NSError(domain: "GraphiSchema", code: 1, userInfo: [NSLocalizedDescriptionKey: "Сначала примените или отмените предложение."]) }
        if model.jsonDraftIsDirty { try await model.applyJSONDraft() }
        else { try await model.saveNow() }
    }

    private func setProjectFile(_ url: URL) {
        projectFileURL = url
        UserDefaults.standard.set(url.path, forKey: "GraphiSchema.projectFile")
    }

    private func openProjectFile() {
        guard !model.isEditingLocked else { showAlert("Сначала примените или сбросьте текущий черновик."); return }
        let panel = NSOpenPanel()
        panel.appearance = NSApp.appearance
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    if await self.model.importJSON(data) { self.setProjectFile(url) }
                    self.refreshAll()
                } catch { self.showAlert("Не удалось открыть проект: \(error.localizedDescription)") }
            }
        }
    }

    private func starterTemplateData() -> Data? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("GraphiSchema/examples/starter.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples/starter.json"),
        ].compactMap { $0 }
        return candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
    }

    private func loadStarterTemplate() {
        guard !model.isEditingLocked else { showAlert("Сначала примените или сбросьте текущий черновик."); return }
        guard let data = starterTemplateData() else { showAlert("Файл базового шаблона не найден."); return }
        Task { @MainActor in
            if await model.importJSON(data) { projectFileURL = nil; UserDefaults.standard.removeObject(forKey: "GraphiSchema.projectFile") }
            refreshAll()
        }
    }

    func loadStarterTemplateIfNeeded() async {
        guard model.loadStarterOnLaunch, model.nodes.isEmpty, model.containers.isEmpty, model.edges.isEmpty,
              let data = starterTemplateData() else { return }
        await model.importJSON(data)
        refreshAll()
    }

    private func performHistoryCommand(redo: Bool) {
        Task { @MainActor in
            do {
                if redo { try await model.redo() }
                else { try await model.undo() }
                refreshAll()
            } catch { showAlert(error.localizedDescription) }
        }
    }

    private func importJSON() {
        guard !model.isEditingLocked else {
            showAlert("Сначала примените или сбросьте текущий черновик.")
            return
        }
        let panel = NSOpenPanel()
        panel.appearance = NSApp.appearance
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = await self.model.importJSON(try Data(contentsOf: url))
                    self.refreshAll()
                } catch { self.showAlert(error.localizedDescription) }
            }
        }
    }

    private func exportJSON() {
        Task { @MainActor in
            guard model.activeProposal == nil else {
                showAlert("Сначала примените или отмените предложение перед экспортом.")
                return
            }
            if model.jsonDraftIsDirty {
                do { try await model.applyJSONDraft() }
                catch { showAlert(error.localizedDescription); return }
            } else {
                do { try await model.saveNow() }
                catch { showAlert("Экспорт отменён: проект не сохранён. \(error.localizedDescription)"); return }
            }
            let panel = NSSavePanel()
            panel.appearance = NSApp.appearance
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "graphischema-project.json"
            panel.beginSheetModal(for: window!) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try self.model.exportData().write(to: url, options: .atomic)
                } catch { self.showAlert(error.localizedDescription) }
            }
        }
    }

    private func exportPNG() {
        guard model.activeProposal == nil else {
            showAlert("Сначала примените или отмените предложение перед экспортом.")
            return
        }
        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scalePopup.addItems(withTitles: ["1×", "1.5×", "2×", "3×"])
        scalePopup.selectItem(at: 2)
        let backgroundPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        backgroundPopup.addItems(withTitles: ["Белый", "Прозрачный", "Светло-серый", "Тёмный"])
        backgroundPopup.selectItem(at: 0)

        let scaleRow = NSStackView(views: [HelpFieldLabel("Масштаб", explanation: "Множитель разрешения PNG. Большее значение создаёт более чёткое изображение и увеличивает размер файла.", identifier: "png-scale-help"), scalePopup])
        let backgroundRow = NSStackView(views: [HelpFieldLabel("Фон", explanation: "Задаёт цвет под диаграммой. Прозрачный фон удобен для вставки схемы поверх других материалов.", identifier: "png-background-help"), backgroundPopup])
        [scaleRow, backgroundRow].forEach {
            $0.orientation = .horizontal
            $0.alignment = .centerY
            $0.distribution = .fill
            $0.spacing = 12
        }
        scaleRow.widthAnchor.constraint(equalToConstant: 250).isActive = true
        backgroundRow.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let options = NSStackView(views: [scaleRow, backgroundRow])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 9

        let alert = NSAlert()
        alert.window.appearance = NSApp.appearance
        alert.messageText = "Экспорт диаграммы в PNG"
        alert.informativeText = "Выберите разрешение и фон изображения."
        alert.accessoryView = options
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let scales = [1.0, 1.5, 2.0, 3.0]
            let backgrounds = ["#FFFFFF", "transparent", "#F5F7FA", "#111827"]
            let scale = scales[min(max(scalePopup.indexOfSelectedItem, 0), scales.count - 1)]
            let background = backgrounds[min(max(backgroundPopup.indexOfSelectedItem, 0), backgrounds.count - 1)]
            let panel = NSSavePanel()
            panel.appearance = NSApp.appearance
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "graphischema-diagram.png"
            panel.beginSheetModal(for: self.window!) { saveResponse in
                guard saveResponse == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        let data = try await self.model.exportPNG(scale: scale, background: background)
                        try data.write(to: url, options: .atomic)
                        self.model.status = "PNG сохранён"
                        self.refreshHeader()
                    } catch { self.showAlert(error.localizedDescription) }
                }
            }
        }
    }

    private func exportPDF() {
        guard model.activeProposal == nil else {
            showAlert("Сначала примените или отмените предложение перед экспортом.")
            return
        }
        let pagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        pagePopup.identifier = NSUserInterfaceItemIdentifier("pdf-page-format")
        for (value, title) in [("a4-landscape", "A4 · альбомная"), ("a4-portrait", "A4 · книжная"), ("a3-landscape", "A3 · альбомная")] {
            pagePopup.addItem(withTitle: title)
            pagePopup.lastItem?.representedObject = value
        }
        let pageRow = NSStackView(views: [
            HelpFieldLabel("Размер страницы", explanation: "Формат страницы PDF. Диаграмма автоматически масштабируется и размещается в доступной области.", identifier: "pdf-page-size-help"),
            pagePopup,
        ])
        pageRow.orientation = .vertical
        pageRow.alignment = .leading
        pageRow.spacing = 4
        pagePopup.widthAnchor.constraint(equalToConstant: 235).isActive = true
        pagePopup.selectItem(at: 0)

        let legend = NSButton(checkboxWithTitle: "Добавить условные обозначения", target: nil, action: nil)
        legend.identifier = NSUserInterfaceItemIdentifier("pdf-include-legend")
        legend.state = .on
        let legendRow = NSStackView(views: [legend, HelpIconButton(
            "Формирует блок обозначений по типам компонентов и стилям связей, присутствующим в текущей схеме.",
            identifier: "pdf-legend-help")])
        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        legendRow.spacing = 5
        let options = NSStackView(views: [pageRow, legendRow])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 12
        options.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        options.heightAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        options.layoutSubtreeIfNeeded()
        let accessorySize = options.fittingSize
        options.frame = NSRect(x: 0, y: 0,
                               width: max(360, accessorySize.width),
                               height: max(104, accessorySize.height))
        options.layoutSubtreeIfNeeded()

        let alert = NSAlert()
        alert.window.appearance = NSApp.appearance
        alert.messageText = "Экспорт диаграммы в PDF"
        alert.informativeText = "Параметры экспорта указаны ниже. Диаграмма будет вписана в выбранный формат страницы."
        alert.accessoryView = options
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отмена")
        pendingPDFExportAlert = alert
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            self.pendingPDFExportAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            let page = pagePopup.selectedItem?.representedObject as? String ?? "a4-landscape"
            let pageSize: NSSize = switch page {
            case "a4-portrait": NSSize(width: 595, height: 842)
            case "a3-landscape": NSSize(width: 1191, height: 842)
            default: NSSize(width: 842, height: 595)
            }
            let panel = NSSavePanel()
            panel.appearance = NSApp.appearance
            panel.allowedContentTypes = [.pdf]
            let projectTitle = self.model.diagram?.project.title ?? ""
            let safeTitle = projectTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = "\(safeTitle.isEmpty ? "graphischema-diagram" : safeTitle).pdf"
            panel.beginSheetModal(for: self.window!) { saveResponse in
                guard saveResponse == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        if self.model.jsonDraftIsDirty { try await self.model.applyJSONDraft() }
                        guard let project = self.model.diagram, let layout = self.model.layout else {
                            throw NSError(domain: "GraphiSchema.PDF", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Не удалось получить компоновку диаграммы для PDF."])
                        }
                        let pageView = DiagramPDFExportView(project: project, layout: layout, pageSize: pageSize,
                                                            includeLegend: legend.state == .on)
                        pageView.layoutSubtreeIfNeeded()
                        let data = pageView.dataWithPDF(inside: pageView.bounds)
                        try data.write(to: url, options: .atomic)
                        self.model.status = "PDF сохранён"
                        self.refreshAll()
                    } catch { self.showAlert("Не удалось экспортировать PDF: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func showHistory() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard model.activeProposal == nil else {
                    showAlert("Сначала примените или отмените предложение перед открытием истории.")
                    return
                }
                if model.jsonDraftIsDirty {
                    try await model.applyJSONDraft()
                } else {
                    try await model.saveNow()
                }
                let versions = try await model.fetchVersions()
                let controller: VersionHistoryWindowController
                if let current = historyWindowController {
                    controller = current
                } else {
                    controller = VersionHistoryWindowController(model: model, onRestore: { [weak self] in
                        self?.refreshAll()
                    }, onShowDiff: { [weak self] diff in
                        self?.showVersionDiff(diff)
                    })
                    historyWindowController = controller
                }
                controller.update(versions)
                controller.showWindow(self)
                controller.window?.makeKeyAndOrderFront(self)
            } catch { showAlert("Не удалось сохранить изменения или загрузить историю: \(error.localizedDescription)") }
        }
    }

    private func showOllamaAssistant(showVariables: Bool = false) {
        if let controller = ollamaWindowController {
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            if showVariables { controller.showVariables() }
            return
        }
        let controller = OllamaAssistantWindowController(model: model)
        ollamaWindowController = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
        if showVariables { controller.showVariables() }
    }

    private func runOllamaPrompt(_ prompt: String, mode: Int) {
        let preferences = model.ollamaPreferences
        guard !preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !preferences.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            workspace.appendChatMessage(role: "Ассистент", text: "Сначала задайте endpoint и модель в настройках ИИ.")
            showOllamaAssistant()
            return
        }
        workspace.setOllamaBusy(true)
        Task { @MainActor in
            defer { self.workspace.setOllamaBusy(false) }
            do {
                if mode == 2 {
                    let response = try await self.model.reviewWithOllama(prompt)
                    self.workspace.appendChatMessage(role: "Ассистент · проверка", text: response.report.text)
                } else {
                    let proposal = try await self.model.generateWithOllama(prompt, editing: mode == 1)
                    let summary = proposal.changes.entries.isEmpty
                        ? "Модель не предложила изменений."
                        : "Предложение подготовлено (\(proposal.changes.entries.count) изменений):\n" + proposal.changes.entries.joined(separator: "\n")
                    self.workspace.appendChatMessage(role: "Ассистент · предложение", text: summary + "\n\nJSON-кандидат показан в правой панели. Нажмите «Применить · сохранить версию», чтобы записать его в проект и историю.")
                }
                self.refreshAll()
            } catch {
                self.workspace.appendChatMessage(role: "Ассистент · ошибка", text: error.localizedDescription)
            }
        }
    }

    private func applyProposalFromChat() {
        Task { @MainActor in
            do {
                try await model.applyCurrentProposal()
                refreshAll()
                workspace.appendChatMessage(role: "Ассистент", text: "Изменения применены, проект сохранён как новая версия \(model.revision).")
            } catch {
                showAlert(error.localizedDescription)
                workspace.appendChatMessage(role: "Ассистент · ошибка", text: error.localizedDescription)
            }
        }
    }

    private func showVersionDiff(_ diff: VersionDiff) {
        var lines: [String] = []
        let fields: [(String, [String])] = [
            ("Проект", diff.project), ("Компоновка", diff.diagram), ("Оформление", diff.presentation),
        ]
        for (title, changed) in fields where !changed.isEmpty {
            lines.append("\(title): \(changed.joined(separator: ", "))")
        }
        for (title, changes) in [("Контейнеры", diff.containers), ("Компоненты", diff.nodes), ("Связи", diff.edges)] {
            let details = [
                changes.added.isEmpty ? nil : "добавлены \(changes.added.joined(separator: ", "))",
                changes.removed.isEmpty ? nil : "удалены \(changes.removed.joined(separator: ", "))",
                changes.details.isEmpty ? nil : "изменены " + changes.details.map { "\($0.id) (\($0.fields.joined(separator: ", ")))" }.joined(separator: ", "),
            ].compactMap { $0 }
            if !details.isEmpty { lines.append("\(title): \(details.joined(separator: "; "))") }
        }
        let alert = NSAlert()
        alert.window.appearance = NSApp.appearance
        alert.messageText = "Отличия от версии «\(diff.versionTitle)»"
        alert.informativeText = lines.isEmpty ? "Изменений нет." : lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Закрыть")
        alert.beginSheetModal(for: window!)
    }

    @objc private func titleChanged(_ sender: NSTextField) { model.updateTitle(sender.stringValue) }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.window.appearance = NSApp.appearance
        alert.messageText = "GraphiSchema"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Закрыть")
        alert.beginSheetModal(for: window!)
    }
}

@MainActor
final class VersionHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let compareButton = makeButton("Сравнить", symbol: "arrow.left.arrow.right") { _ in }
    private let restoreButton = makeButton("Восстановить", symbol: "clock.arrow.circlepath") { _ in }
    private var versions: [ProjectVersion] = []
    private var onRestore: (() -> Void)?
    private var onShowDiff: ((VersionDiff) -> Void)?

    init(model: AppModel, onRestore: @escaping () -> Void, onShowDiff: @escaping (VersionDiff) -> Void) {
        self.model = model
        self.onRestore = onRestore
        self.onShowDiff = onShowDiff
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "История проекта"
        window.minSize = NSSize(width: 620, height: 380)
        super.init(window: window)
        buildInterface()
        AppTheme.configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ versions: [ProjectVersion]) {
        self.versions = versions
        tableView.reloadData()
        if versions.isEmpty {
            statusLabel.stringValue = "Сохранённых версий пока нет."
        } else {
            statusLabel.stringValue = "Снимков: \(versions.count). Выберите снимок для сравнения или восстановления."
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    func showError(_ message: String) {
        statusLabel.stringValue = message
    }

    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard versions.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        let version = versions[row]
        let cellIdentifier = NSUserInterfaceItemIdentifier("history-cell-\(key)")
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        cell.identifier = cellIdentifier
        cell.font = key == "revision" ? .monospacedSystemFont(ofSize: 10, weight: .regular) : .systemFont(ofSize: 11)
        switch key {
        case "date": cell.stringValue = version.createdAt.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
        case "title": cell.stringValue = version.title
        default: cell.stringValue = String(version.revision.prefix(12))
        }
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        tableView.identifier = NSUserInterfaceItemIdentifier("version-history-table")
        compareButton.identifier = NSUserInterfaceItemIdentifier("version-history-compare")
        restoreButton.identifier = NSUserInterfaceItemIdentifier("version-history-restore")
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Дата"
        dateColumn.width = 205
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Название"
        titleColumn.width = 375
        let revisionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("revision"))
        revisionColumn.title = "Ревизия"
        revisionColumn.width = 130
        [dateColumn, titleColumn, revisionColumn].forEach(tableView.addTableColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        compareButton.target = self
        compareButton.action = #selector(compareSelected)
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        let refreshButton = makeButton("Обновить", symbol: "arrow.clockwise") { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        let closeButton = makeButton("Закрыть", symbol: "xmark") { [weak self] _ in self?.close() }
        let buttons = NSStackView(views: [compareButton, restoreButton, refreshButton, NSView(), closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)
        content.addSubview(scrollView)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.heightAnchor.constraint(equalToConstant: 30),
        ])
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = versions.indices.contains(tableView.selectedRow)
        compareButton.isEnabled = hasSelection
        restoreButton.isEnabled = hasSelection
    }

    private func reload() async {
        statusLabel.stringValue = "Загрузка истории…"
        do { update(try await model.fetchVersions()) }
        catch { showError("Не удалось загрузить версии: \(error.localizedDescription)") }
    }

    @objc private func compareSelected() {
        let row = tableView.selectedRow
        guard versions.indices.contains(row) else { return }
        let id = versions[row].id
        Task { @MainActor in
            do { onShowDiff?(try await model.fetchVersionDiff(id)) }
            catch { showError("Не удалось сравнить версию: \(error.localizedDescription)") }
        }
    }

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard versions.indices.contains(row) else { return }
        let version = versions[row]
        let alert = NSAlert()
        alert.window.appearance = NSApp.appearance
        alert.messageText = "Восстановить выбранную версию?"
        alert.informativeText = "Текущий проект будет сохранён в истории, затем его состояние заменится выбранным снимком."
        alert.addButton(withTitle: "Восстановить")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                do {
                    try await self.model.restoreVersion(version.id)
                    self.onRestore?()
                    await self.reload()
                    self.statusLabel.stringValue = "Версия восстановлена. Снимок текущего состояния добавлен в историю."
                } catch {
                    self.showError("Не удалось восстановить версию: \(error.localizedDescription)")
                }
            }
        }
    }
}

@MainActor
private final class PaletteItemView: NSView, NSDraggingSource {
    let item: PaletteObject
    var onClick: (() -> Void)?
    var isEditingLocked = false {
        didSet { alphaValue = isEditingLocked ? 0.55 : 1 }
    }

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private var pointerDown: NSPoint?
    private var startedDragging = false
    private var didLoadIcon = false

    init(item: PaletteObject) {
        self.item = item
        titleLabel = makeLabel(item.title, size: 11, weight: .semibold)
        detailLabel = makeLabel(item.detail, size: 9, weight: .regular, color: .secondaryLabelColor)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("palette-item-\(item.id)")
        wantsLayer = true
        layer?.name = "theme-surface-control"
        layer?.backgroundColor = AppTheme.surface("control").cgColor
        layer?.cornerRadius = 7
        iconView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyDown
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let row = NSStackView(views: [iconView, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        toolTip = "Нажмите, чтобы добавить, или перетащите на холст."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillDraw() {
        super.viewWillDraw()
        guard !didLoadIcon, !visibleRect.isEmpty else { return }
        didLoadIcon = true
        item.loadIconAsync { [weak self] image in
            guard let self, let image else { return }
            self.iconView.image = image
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditingLocked else { return }
        pointerDown = convert(event.locationInWindow, from: nil)
        startedDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEditingLocked else { return }
        guard let pointerDown, !startedDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pointerDown.x, point.y - pointerDown.y) >= 4 else { return }
        startedDragging = true
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id, forType: PaletteItem.pasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 7, yRadius: 7).fill()
        image.unlockFocus()
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !startedDragging { onClick?() }
        pointerDown = nil
        startedDragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

@MainActor
private final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SidebarView: NSView {
    var onAddNode: ((PaletteObject) -> Void)?
    var onAddContainer: (() -> Void)?
    var onSelect: ((DiagramSelection) -> Void)?
    var onShowProperties: (() -> Void)?

    private let scrollView = NSScrollView()
    private let stack = TopAlignedStackView()
    private let paletteStack = TopAlignedStackView()
    private let paletteBodyStack = TopAlignedStackView()
    private let contentStack = TopAlignedStackView()
    private let bottomSpacer = NSView()
    private let searchField = NSSearchField()
    private let collectionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var paletteToggleButton = NSButton(title: "", target: nil, action: nil)
    private var paletteCollapsed = false
    private var selectedCollectionID = "all"
    private var lastPaletteFingerprint: String?
    private var lastContentFingerprint: String?
    private var lastPaletteLockState: Bool?
    private var paletteItemViews: [String: PaletteItemView] = [:]
    private var widthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var actions: [ControlAction] = []
    private var rowActions: [ControlAction] = []
    private weak var currentModel: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("diagram-palette")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.identifier = NSUserInterfaceItemIdentifier("sidebar-document-stack")
        for column in [paletteStack, contentStack] {
            column.orientation = .vertical
            column.alignment = .leading
            column.distribution = .fill
            column.spacing = 5
            column.setContentHuggingPriority(.required, for: .vertical)
            column.setContentCompressionResistancePriority(.required, for: .vertical)
            column.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(column)
            column.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        bottomSpacer.identifier = NSUserInterfaceItemIdentifier("sidebar-bottom-spacer")
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        paletteStack.identifier = NSUserInterfaceItemIdentifier("palette-collection-list")
        paletteBodyStack.orientation = .vertical
        paletteBodyStack.alignment = .leading
        paletteBodyStack.spacing = 5
        paletteBodyStack.translatesAutoresizingMaskIntoConstraints = false
        paletteBodyStack.identifier = NSUserInterfaceItemIdentifier("palette-collection-body")
        contentStack.identifier = NSUserInterfaceItemIdentifier("sidebar-project-elements")
        searchField.placeholderString = "Найти объект…"
        searchField.identifier = NSUserInterfaceItemIdentifier("palette-search-field")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchPalette)
        collectionPicker.identifier = NSUserInterfaceItemIdentifier("palette-collection-picker")
        for collection in PaletteLibrary.collections {
            collectionPicker.addItem(withTitle: "\(collection.title) · \(collection.objects.count)")
            collectionPicker.lastItem?.representedObject = collection.id
        }
        collectionPicker.target = self
        collectionPicker.action = #selector(selectCollection)
        collectionPicker.font = .systemFont(ofSize: 10)
        paletteToggleButton = makeButton("", symbol: "chevron.up") { [weak self] _ in self?.togglePaletteVisibility() }
        paletteToggleButton.imagePosition = .imageOnly
        paletteToggleButton.isBordered = false
        paletteToggleButton.bezelStyle = .regularSquare
        paletteToggleButton.imageScaling = .scaleProportionallyDown
        paletteToggleButton.contentTintColor = .secondaryLabelColor
        paletteToggleButton.toolTip = "Свернуть поиск и выбор объектов коллекции"
        paletteToggleButton.controlSize = .small
        paletteToggleButton.identifier = NSUserInterfaceItemIdentifier("palette-collection-toggle")
        paletteToggleButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        paletteToggleButton.heightAnchor.constraint(equalToConstant: 27).isActive = true
        paletteToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        paletteToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let collectionTitle = section("КОЛЛЕКЦИЯ ОБЪЕКТОВ")
        collectionTitle.lineBreakMode = .byTruncatingTail
        collectionTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        collectionTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let paletteHeading = NSStackView(views: [collectionTitle, NSView(), paletteToggleButton])
        paletteHeading.orientation = .horizontal
        paletteHeading.alignment = .centerY
        paletteHeading.distribution = .fill
        paletteHeading.identifier = NSUserInterfaceItemIdentifier("palette-collection-heading")
        paletteHeading.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        addArranged(paletteHeading, to: paletteStack)
        addArranged(paletteBodyStack, to: paletteStack)
        addArranged(collectionPicker, to: paletteBodyStack)
        addArranged(searchField, to: paletteBodyStack)
        addArranged(hint("Нажмите или перетащите объект на холст"), to: paletteBodyStack)
        scrollView.documentView = stack
        scrollView.identifier = NSUserInterfaceItemIdentifier("palette-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.autoresizingMask = [.width, .height]
        addArranged(bottomSpacer, to: stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        currentModel = model
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let selectionKey: String
        switch model.selection {
        case .project: selectionKey = "project"
        case .node(let id): selectionKey = "node:\(id)"
        case .nodes(let ids): selectionKey = "nodes:\(ids.sorted().joined(separator: ","))"
        case .container(let id): selectionKey = "container:\(id)"
        case .edge(let id): selectionKey = "edge:\(id)"
        }
        func encoded(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        let paletteFingerprint = "\(selectedCollectionID)|\(query)"
        let contentFingerprint = [
            selectionKey, String(model.isEditingLocked),
            model.containers.map { encoded($0.id) + encoded($0.label) + encoded($0.style.stroke) }.joined(),
            model.nodes.map { encoded($0.id) + encoded($0.label) + encoded($0.style.stroke) }.joined(),
            model.edges.map { encoded($0.id) + encoded($0.label) + encoded($0.source) + encoded($0.target) + encoded($0.style.color) }.joined(),
        ].joined(separator: "|")
        if lastPaletteLockState != model.isEditingLocked {
            lastPaletteLockState = model.isEditingLocked
            for itemView in paletteItemViews.values {
                itemView.isEditingLocked = model.isEditingLocked
            }
        }
        let paletteChanged = paletteFingerprint != lastPaletteFingerprint
        if paletteChanged {
            lastPaletteFingerprint = paletteFingerprint
            rebuildPalette(model: model, query: query)
        }
        let contentChanged = contentFingerprint != lastContentFingerprint
        if contentChanged {
            lastContentFingerprint = contentFingerprint
            rebuildContent(model: model)
        }
        if !contentChanged && !paletteChanged { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func rebuildPalette(model: AppModel, query: String) {
        for view in Array(paletteBodyStack.arrangedSubviews.dropFirst(3)) {
            widthConstraints.removeValue(forKey: ObjectIdentifier(view))?.isActive = false
            paletteBodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let selected = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == selectedCollectionID }) {
            collectionPicker.select(selected)
        }
        let paletteItems = (PaletteLibrary.collection(id: selectedCollectionID)?.objects ?? []).filter {
            query.isEmpty || $0.title.localizedLowercase.contains(query) || $0.detail.localizedLowercase.contains(query) || $0.kind.localizedLowercase.contains(query)
        }
        let resultsHeading = section("ОБЪЕКТЫ · \(paletteItems.count)")
        resultsHeading.identifier = NSUserInterfaceItemIdentifier("palette-results-heading")
        addArranged(resultsHeading, to: paletteBodyStack)
        for item in paletteItems {
            let paletteItem = paletteItemViews[item.id] ?? PaletteItemView(item: item)
            paletteItemViews[item.id] = paletteItem
            paletteItem.isEditingLocked = model.isEditingLocked
            if paletteItem.onClick == nil { paletteItem.onClick = { [weak self] in self?.onAddNode?(item) } }
            addArranged(paletteItem, to: paletteBodyStack)
        }
        if paletteItems.isEmpty {
            let emptyState = hint("Объекты не найдены")
            emptyState.identifier = NSUserInterfaceItemIdentifier("palette-empty-state")
            addArranged(emptyState, to: paletteBodyStack)
        }
        paletteBodyStack.isHidden = paletteCollapsed
        paletteBodyStack.needsLayout = true
        paletteStack.needsLayout = true
        stack.needsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    private func togglePaletteVisibility() {
        paletteCollapsed.toggle()
        paletteBodyStack.isHidden = paletteCollapsed
        paletteToggleButton.image = NSImage(systemSymbolName: paletteCollapsed ? "chevron.down" : "chevron.up",
                                            accessibilityDescription: paletteCollapsed ? "Развернуть коллекцию объектов" : "Свернуть коллекцию объектов")
        paletteToggleButton.toolTip = paletteCollapsed
            ? "Развернуть поиск и выбор объектов коллекции"
            : "Свернуть поиск и выбор объектов коллекции"
        if paletteCollapsed {
            paletteStack.removeArrangedSubview(paletteBodyStack)
            paletteBodyStack.isHidden = true
        } else {
            paletteBodyStack.isHidden = false
            paletteStack.insertArrangedSubview(paletteBodyStack, at: 1)
        }
        paletteBodyStack.needsLayout = true
        paletteStack.needsLayout = true
        stack.needsLayout = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    private func scrollToTop() {
        let documentHeight = scrollView.documentView?.bounds.height ?? stack.bounds.height
        let top = stack.isFlipped ? CGFloat.zero : max(0, documentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func rebuildContent(model: AppModel) {
        clearArrangedSubviews(from: contentStack)
        actions.removeAll()
        rowActions.removeAll()
        addArranged(separator(), to: contentStack)
        let actionsHeading = section("ДЕЙСТВИЯ")
        actionsHeading.identifier = NSUserInterfaceItemIdentifier("sidebar-actions-heading")
        addArranged(actionsHeading, to: contentStack)
        let addContainer = actionButton("Добавить контейнер", symbol: "rectangle.3.group") { [weak self] in self?.onAddContainer?() }
        addContainer.isEnabled = !model.isEditingLocked
        addArranged(addContainer, to: contentStack)
        addArranged(separator(), to: contentStack)
        addArranged(section("КОНТЕЙНЕРЫ · \(model.containers.count)"), to: contentStack)
        if model.containers.isEmpty { addArranged(hint("Нет контейнеров"), to: contentStack) }
        for container in model.containers {
            addArranged(elementButton(container.label, symbol: "rectangle.dashed", color: NSColor(hex: container.style.stroke), selected: model.selection == .container(container.id), action: { [weak self] in self?.onSelect?(.container(container.id)) }, context: { [weak self] in self?.onSelect?(.container(container.id)); self?.onShowProperties?() }), to: contentStack)
        }
        addArranged(separator(), to: contentStack)
        addArranged(section("КОМПОНЕНТЫ · \(model.nodes.count)"), to: contentStack)
        if model.nodes.isEmpty { addArranged(hint("Нет компонентов"), to: contentStack) }
        for node in model.nodes {
            addArranged(elementButton(node.label, symbol: "square", color: NSColor(hex: node.style.stroke), selected: model.selection == .node(node.id), action: { [weak self] in self?.onSelect?(.node(node.id)) }, context: { [weak self] in self?.onSelect?(.node(node.id)); self?.onShowProperties?() }), to: contentStack)
        }
        addArranged(separator(), to: contentStack)
        addArranged(section("СВЯЗИ · \(model.edges.count)"), to: contentStack)
        if model.edges.isEmpty { addArranged(hint("Нет связей"), to: contentStack) }
        let nodeLabels = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, $0.label) })
        for edge in model.edges {
            let source = nodeLabels[edge.source] ?? edge.source
            let target = nodeLabels[edge.target] ?? edge.target
            let title = edge.label.isEmpty ? "\(source) → \(target)" : edge.label
            addArranged(elementButton(title, symbol: "arrow.right", color: NSColor(hex: edge.style.color), selected: model.selection == .edge(edge.id), action: { [weak self] in self?.onSelect?(.edge(edge.id)) }, context: { [weak self] in self?.onSelect?(.edge(edge.id)); self?.onShowProperties?() }), to: contentStack)
        }
        addArranged(separator(), to: contentStack)
        let local = makeLabel("●  Данные и backend остаются локально", size: 9, weight: .medium, color: NSColor(hex: "#3F8064"))
        local.lineBreakMode = .byWordWrapping
        addArranged(local, to: contentStack)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentView.bounds.width
        let height = documentHeight(for: stack)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 1))
        stack.needsLayout = true
        stack.layoutSubtreeIfNeeded()
    }

    @objc private func searchPalette() {
        guard let currentModel else { return }
        update(model: currentModel)
    }

    @objc private func selectCollection() {
        guard let collectionID = collectionPicker.selectedItem?.representedObject as? String,
              PaletteLibrary.collection(id: collectionID) != nil
        else { return }
        selectedCollectionID = collectionID
        if let currentModel { update(model: currentModel) }
    }

    private func addArranged(_ view: NSView, to column: NSStackView) {
        column.addArrangedSubview(view)
        let constraint = view.widthAnchor.constraint(equalTo: column.widthAnchor)
        widthConstraints[ObjectIdentifier(view)] = constraint
        constraint.isActive = true
    }

    private func clearArrangedSubviews(from column: NSStackView) {
        for view in column.arrangedSubviews {
            widthConstraints.removeValue(forKey: ObjectIdentifier(view))?.isActive = false
        }
        column.removeAllArrangedSubviews()
    }

    private func documentHeight(for stack: NSStackView) -> CGFloat {
        let visibleViews = stack.arrangedSubviews.filter {
            !$0.isHidden && $0.identifier?.rawValue != "sidebar-bottom-spacer"
        }
        let viewsHeight = visibleViews.reduce(CGFloat.zero) { total, view in
            return total + (view is NSStackView ? documentHeight(for: view as! NSStackView) : max(view.fittingSize.height, view.frame.height))
        }
        let spacing = stack.spacing * CGFloat(max(0, visibleViews.count - 1))
        return viewsHeight + spacing + stack.edgeInsets.top + stack.edgeInsets.bottom
    }

    private func actionButton(_ title: String, symbol: String, key: String? = nil, action: @escaping () -> Void) -> NSButton {
        let button = makeButton(title, symbol: symbol) { _ in action() }
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        button.alignment = .left
        if let key { button.keyEquivalent = key; button.keyEquivalentModifierMask = .command }
        return button
    }

    private func elementButton(_ title: String, symbol: String, color: NSColor, selected: Bool,
                               action: @escaping () -> Void, context: @escaping () -> Void) -> NSButton {
        let button = SidebarElementButton(title: title, target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        button.onContext = context
        let proxy = ControlAction { _ in action() }
        button.target = proxy
        button.action = #selector(ControlAction.invoke(_:))
        rowActions.append(proxy)
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = selected ? .controlAccentColor : color
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: button.font ?? NSFont.systemFont(ofSize: 11),
        ])
        if selected { button.wantsLayer = true; button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor; button.layer?.cornerRadius = 5 }
        return button
    }

    private func section(_ text: String) -> NSTextField {
        let field = makeLabel(text, size: 8, weight: .bold, color: .secondaryLabelColor)
        field.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return field
    }

    private func hint(_ text: String) -> NSTextField { makeLabel(text, size: 9, weight: .regular, color: .tertiaryLabelColor) }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

@MainActor
private final class SidebarElementButton: NSButton {
    var onContext: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) { onContext?() }
}

@MainActor
private final class WorkspaceView: NSView {
    var onSelectElement: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double, String?) -> Void)?
    var onDetachNodeFromContainer: ((String) -> Void)?
    var onSetNodeZIndex: ((String, Int) -> Void)?
    var onMoveNodeInStack: ((String, Bool) -> Void)?
    var onMoveNodes: ((Set<String>, Double, Double) -> Void)?
    var onResizeNode: ((String, Double, Double) -> Void)?
    var onScaleNodes: ((Set<String>, Double) -> Void)?
    var onEditNodeText: ((String) -> Void)?
    var onCreateEdge: ((String, String) -> Void)?
    var onSetEdgeWaypoints: ((String, [RoutePoint], [LayoutNode]) -> Void)?
    var onReattachEdge: ((String, Bool, String) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?
    var onResizeEmptyContainer: ((String, Double, Double) -> Void)?
    var onDropPaletteItem: ((PaletteObject, Double, Double, String?) -> Void)?
    var onOptimizeRoutes: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onToggleCodePanel: (() -> Void)?
    var onToggleChat: (() -> Void)?
    var onShowStyle: (() -> Void)?
    var onConfigureOllama: (() -> Void)?
    var onOllamaMessage: ((String, Int) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onApplyProposal: (() -> Void)?
    var onCancelProposal: (() -> Void)?

    private let headerScroll = NSScrollView()
    private let header = NSStackView()
    private let content = NSView()
    private let canvasView = DiagramCanvasView()
    private let chatPanel = OllamaChatPanelView()
    private let footer = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let layoutLabel = NSTextField(labelWithString: "")
    private var styleButton = NSButton(title: "Стиль", target: nil, action: nil)
    private var applyProposalButton = NSButton(title: "Применить", target: nil, action: nil)
    private var cancelProposalButton = NSButton(title: "Отмена", target: nil, action: nil)
    private var actions: [ControlAction] = []
    private var showingProposal = false
    private var chatHeightConstraint: NSLayoutConstraint?
    private(set) var isChatVisible = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(model: AppModel) {
        countLabel.stringValue = "\(model.nodes.count) объектов · \(model.edges.count) связей"
        updateCanvasStatus(model)
        let proposal = model.activeProposal
        canvasView.isReadOnly = model.isEditingLocked
        canvasView.inverseTrackpad = model.inverseTrackpad
        canvasView.update(
            diagram: proposal?.diagram ?? model.diagram,
            layout: proposal?.layout ?? model.layout,
            selection: proposal == nil ? model.selection : .project
        )
        chatPanel.update(model: model)
        let hasProposal = proposal != nil
        applyProposalButton.isHidden = !hasProposal
        cancelProposalButton.isHidden = !hasProposal
        applyProposalButton.isEnabled = hasProposal
        cancelProposalButton.isEnabled = hasProposal
        styleButton.isEnabled = !model.isEditingLocked
        if let proposal {
            footer.stringValue = "Предложение · \(proposal.changes.entries.count) изменений · проверьте и примените или отмените"
            footer.toolTip = proposal.changes.entries.joined(separator: "\n")
            if !showingProposal { canvasView.fitToContent() }
            showingProposal = true
        } else if model.jsonDraftIsDirty {
            showingProposal = false
            footer.stringValue = "JSON не применён · проверьте код и нажмите «Применить JSON»"
            footer.toolTip = "Холст заблокирован, пока черновик JSON не применён или не отменён."
        } else {
            showingProposal = false
            updateCanvasStatus(model)
        }
    }

    func setInteractionState(model: AppModel) {
        canvasView.isReadOnly = model.isEditingLocked
        canvasView.inverseTrackpad = model.inverseTrackpad
        styleButton.isEnabled = !model.isEditingLocked
        if model.activeProposal == nil {
            if model.jsonDraftIsDirty {
                footer.stringValue = "JSON не применён · проверьте код и нажмите «Применить JSON»"
                footer.toolTip = "Холст заблокирован, пока черновик JSON не применён или не отменён."
            } else {
                updateCanvasStatus(model)
            }
        }
    }

    func refreshCounts(model: AppModel?) {
        guard let model else { return }
        countLabel.stringValue = "\(model.nodes.count) объектов · \(model.edges.count) связей"
        updateCanvasStatus(model)
    }

    func appendChatMessage(role: String, text: String) { chatPanel.appendMessage(role: role, text: text) }
    func setOllamaBusy(_ busy: Bool) { chatPanel.setBusy(busy) }
    func setChatVisible(_ visible: Bool) {
        isChatVisible = visible
        chatPanel.isHidden = !visible
        chatHeightConstraint?.constant = visible ? 205 : 0
    }

    private func updateCanvasStatus(_ model: AppModel) {
        footer.stringValue = "Ревизия \(model.revision.isEmpty ? "—" : model.revision) · узлы: движение/размер · синий маркер: связь · ⌥ панорама"
        footer.toolTip = "Перетаскивайте компоненты из левой палитры на холст. Выберите узел: нижний правый маркер меняет размер, синий маркер справа создаёт связь перетаскиванием к другому узлу. Нажмите линию, чтобы выбрать связь и открыть её стиль. Option панорамирует; Command + прокрутка и щипок меняют масштаб."
        if model.diagram?.diagram.layoutMode == "manual" {
            layoutLabel.stringValue = "Размещение вручную · Graphviz маршрутизирует"
            layoutLabel.toolTip = "В ручном режиме координаты узлов задаёт пользователь. Graphviz neato -n2 сохраняет эти координаты и рассчитывает пути связей."
        } else {
            layoutLabel.stringValue = "Автоматически · Graphviz \(model.layout?.engine ?? model.diagram?.diagram.layoutEngine ?? "dot")"
            layoutLabel.toolTip = "Graphviz \(model.layout?.engine ?? model.diagram?.diagram.layoutEngine ?? "dot") размещает узлы и рассчитывает соединения."
        }
    }

    private func build() {
        wantsLayer = true
        layer?.name = "theme-surface-window"
        layer?.backgroundColor = AppTheme.surface("window").cgColor

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.setContentCompressionResistancePriority(.required, for: .horizontal)
        let zoomOut = makeButton("−", symbol: "minus.magnifyingglass") { [weak self] _ in self?.canvasView.zoom(by: 0.82) }
        zoomOut.toolTip = "Уменьшить масштаб"
        let zoomIn = makeButton("+", symbol: "plus.magnifyingglass") { [weak self] _ in self?.canvasView.zoom(by: 1.22) }
        zoomIn.toolTip = "Увеличить масштаб"
        let fit = makeButton("Вписать", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] _ in self?.canvasView.fitToContent() }
        fit.toolTip = "Вписать диаграмму в холст"
        let grid = makeButton("Сетка", symbol: "circle.grid.3x3") { [weak self] sender in
            guard let self else { return }
            self.canvasView.isGridVisible.toggle()
            (sender as? NSButton)?.contentTintColor = self.canvasView.isGridVisible
                ? NSColor.controlAccentColor
                : NSColor.secondaryLabelColor
        }
        grid.toolTip = "Показать или скрыть сетку"
        let sidebarToggle = makeButton("", symbol: "sidebar.left") { [weak self] _ in self?.onToggleSidebar?() }
        sidebarToggle.imagePosition = .imageOnly; sidebarToggle.toolTip = "Показать или скрыть левую панель"
        let codeToggle = makeButton("", symbol: "sidebar.right") { [weak self] _ in self?.onToggleCodePanel?() }
        codeToggle.imagePosition = .imageOnly; codeToggle.toolTip = "Показать или скрыть панель свойств и кода"
        let chatToggle = makeButton("", symbol: "bubble.left.and.bubble.right") { [weak self] _ in self?.onToggleChat?() }
        chatToggle.imagePosition = .imageOnly; chatToggle.toolTip = "Показать или скрыть чат Ollama"
        let optimize = makeButton("Оптимизировать линии", symbol: "arrow.trianglehead.2.clockwise") { [weak self] _ in self?.onOptimizeRoutes?() }
        optimize.toolTip = "Удаляет ручные изгибы и индивидуальные настройки маршрута. Операция попадает в историю и отменяется через ⌘Z."
        styleButton = makeButton("Стиль", symbol: "paintpalette") { [weak self] _ in self?.onShowStyle?() }
        applyProposalButton = makeButton("Применить", symbol: "checkmark.circle.fill") { [weak self] _ in self?.onApplyProposal?() }
        cancelProposalButton = makeButton("Отменить", symbol: "xmark") { [weak self] _ in self?.onCancelProposal?() }
        [applyProposalButton, cancelProposalButton].forEach { $0.controlSize = .small; $0.isHidden = true }
        canvasView.onSelect = { [weak self] selection in self?.onSelectElement?(selection) }
        canvasView.onMoveNode = { [weak self] id, x, y, containerID in self?.onMoveNode?(id, x, y, containerID) }
        canvasView.onDetachNodeFromContainer = { [weak self] id in self?.onDetachNodeFromContainer?(id) }
        canvasView.onSetNodeZIndex = { [weak self] id, value in self?.onSetNodeZIndex?(id, value) }
        canvasView.onMoveNodeInStack = { [weak self] id, front in self?.onMoveNodeInStack?(id, front) }
        canvasView.onMoveNodes = { [weak self] ids, dx, dy in self?.onMoveNodes?(ids, dx, dy) }
        canvasView.onResizeNode = { [weak self] id, width, height in self?.onResizeNode?(id, width, height) }
        canvasView.onScaleNodes = { [weak self] ids, factor in self?.onScaleNodes?(ids, factor) }
        canvasView.onEditNodeText = { [weak self] id in self?.onEditNodeText?(id) }
        canvasView.onSetEdgeWaypoints = { [weak self] id, points, positions in self?.onSetEdgeWaypoints?(id, points, positions) }
        canvasView.onReattachEdge = { [weak self] id, source, nodeID in self?.onReattachEdge?(id, source, nodeID) }
        canvasView.onCreateEdge = { [weak self] source, target in self?.onCreateEdge?(source, target) }
        canvasView.onMoveContainer = { [weak self] id, x, y in self?.onMoveContainer?(id, x, y) }
        canvasView.onResizeContainer = { [weak self] id, padding in self?.onResizeContainer?(id, padding) }
        canvasView.onResizeEmptyContainer = { [weak self] id, width, height in self?.onResizeEmptyContainer?(id, width, height) }
        canvasView.onDropPaletteItem = { [weak self] item, x, y, containerID in self?.onDropPaletteItem?(item, x, y, containerID) }
        canvasView.onRequestStyle = { [weak self] in self?.onShowStyle?() }
        canvasView.onDeleteSelection = { [weak self] in self?.onDeleteSelection?() }
        chatPanel.onConfigure = { [weak self] in self?.onConfigureOllama?() }
        chatPanel.onSend = { [weak self] prompt, mode in self?.onOllamaMessage?(prompt, mode) }
        chatPanel.onApplyProposal = { [weak self] in self?.onApplyProposal?() }
        chatPanel.onCancelProposal = { [weak self] in self?.onCancelProposal?() }
        chatPanel.onPromptExpansionChanged = { [weak self] expanded in
            self?.chatHeightConstraint?.constant = expanded ? 270 : 205
        }
        let spacer = NSView()
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        layoutLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        layoutLabel.textColor = .controlAccentColor
        header.addArrangedSubview(styleButton)
        header.addArrangedSubview(applyProposalButton)
        header.addArrangedSubview(cancelProposalButton)
        header.addArrangedSubview(zoomOut)
        header.addArrangedSubview(zoomIn)
        header.addArrangedSubview(fit)
        header.addArrangedSubview(grid)
        header.addArrangedSubview(optimize)
        header.addArrangedSubview(sidebarToggle)
        header.addArrangedSubview(codeToggle)
        header.addArrangedSubview(chatToggle)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(countLabel)
        header.addArrangedSubview(makeLabel("·", size: 10, weight: .regular, color: .tertiaryLabelColor))
        header.addArrangedSubview(layoutLabel)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in header.arrangedSubviews where !(control is NSTextField) && control !== spacer {
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        countLabel.lineBreakMode = .byTruncatingTail
        layoutLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        layoutLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerScroll.identifier = NSUserInterfaceItemIdentifier("workspace-toolbar-scroll")
        headerScroll.hasHorizontalScroller = true
        headerScroll.hasVerticalScroller = false
        headerScroll.autohidesScrollers = true
        headerScroll.scrollerStyle = .overlay
        headerScroll.borderType = .noBorder
        headerScroll.drawsBackground = false
        headerScroll.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = true
        headerScroll.documentView = header
        header.setFrameSize(NSSize(width: max(header.fittingSize.width, 700), height: 48))

        content.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        chatPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvasView)
        content.addSubview(chatPanel)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: content.leadingAnchor), canvasView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: content.topAnchor), canvasView.bottomAnchor.constraint(equalTo: chatPanel.topAnchor),
            chatPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8), chatPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            chatPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        chatHeightConstraint = chatPanel.heightAnchor.constraint(equalToConstant: 205)
        chatHeightConstraint?.isActive = true

        footer.font = .systemFont(ofSize: 9)
        footer.textColor = .tertiaryLabelColor
        header.wantsLayer = true
        header.layer?.name = "theme-surface-window"
        header.layer?.backgroundColor = AppTheme.surface("window").cgColor
        let separator = NSBox()
        separator.boxType = .separator
        [headerScroll, separator, content, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            headerScroll.leadingAnchor.constraint(equalTo: leadingAnchor), headerScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerScroll.topAnchor.constraint(equalTo: topAnchor), headerScroll.heightAnchor.constraint(equalToConstant: 48),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor), separator.topAnchor.constraint(equalTo: headerScroll.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: separator.bottomAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    override func layout() {
        super.layout()
        let viewportWidth = headerScroll.contentView.bounds.width
        let naturalWidth = header.fittingSize.width
        let documentWidth = max(max(viewportWidth, naturalWidth), 700)
        if abs(header.frame.width - documentWidth) > 0.5 || abs(header.frame.height - 48) > 0.5 {
            header.setFrameSize(NSSize(width: documentWidth, height: 48))
            header.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class JSONCodePanelView: NSView, NSTextViewDelegate {
    var onSelectTab: ((WorkspaceTab) -> Void)?
    var onJSONChange: ((String) -> Void)?
    var onDOTChange: ((String) -> Void)?
    var onApplyJSON: (() -> Void)?
    var onDiscardJSON: (() -> Void)?
    var onValidateJSON: (() -> Void)?
    var onFormatJSON: (() -> Void)?
    var onPreviewDOT: (() -> Void)?

    private let modeControl = NSSegmentedControl(labels: ["JSON", "DOT"], trackingMode: .selectOne, target: nil, action: nil)
    private let codeScroll = NSScrollView()
    private let codeTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Ожидание локального backend…")
    private let formatButton = makeButton("Формат", symbol: "text.alignleft") { _ in }
    private let validateButton = makeButton("Проверить", symbol: "checkmark.magnifyingglass") { _ in }
    private let applyJSONButton = makeButton("Применить JSON", symbol: "checkmark.circle.fill") { _ in }
    private let discardJSONButton = makeButton("Сбросить", symbol: "arrow.uturn.backward") { _ in }
    private let previewDOTButton = makeButton("Проверить DOT", symbol: "checkmark.magnifyingglass") { _ in }
    private var actions: [ControlAction] = []
    private var lastCode = ""
    private var isUpdatingCode = false
    private var currentModel: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(model: AppModel) {
        currentModel = model
        let tab: WorkspaceTab = model.workspaceTab == .dot ? .dot : .json
        modeControl.selectedSegment = tab == .dot ? 1 : 0
        let source: String
        if tab == .json, let proposal = model.activeProposal {
            source = model.prettyJSON(proposal.diagram)
        } else {
            source = tab == .json ? model.jsonDraft : model.dotSource
        }
        if source != lastCode {
            isUpdatingCode = true
            lastCode = source
            codeTextView.string = source
            isUpdatingCode = false
        }
        let isJSON = tab == .json
        modeControl.isEnabled = model.activeProposal == nil
        codeTextView.isEditable = model.activeProposal == nil
        formatButton.isHidden = !isJSON || model.activeProposal != nil
        validateButton.isHidden = !isJSON || model.activeProposal != nil
        applyJSONButton.isHidden = !isJSON || model.activeProposal != nil
        discardJSONButton.isHidden = !isJSON || model.activeProposal != nil
        previewDOTButton.isHidden = isJSON || model.activeProposal != nil
        discardJSONButton.isEnabled = isJSON && model.jsonDraftIsDirty
        updateJSONStatus()
        if !isJSON { statusLabel.stringValue = model.status }
    }

    private func build() {
        identifier = NSUserInterfaceItemIdentifier("diagram-code-editor")
        wantsLayer = true
        layer?.name = "theme-surface-panel"
        layer?.backgroundColor = AppTheme.surface("panel").cgColor
        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .rounded
        modeControl.widthAnchor.constraint(equalToConstant: 150).isActive = true
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))

        codeTextView.isRichText = false
        codeTextView.identifier = NSUserInterfaceItemIdentifier("diagram-json-editor")
        codeTextView.isAutomaticQuoteSubstitutionEnabled = false
        codeTextView.isAutomaticDashSubstitutionEnabled = false
        codeTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeTextView.textColor = .labelColor
        codeTextView.backgroundColor = .textBackgroundColor
        codeTextView.insertionPointColor = .labelColor
        codeTextView.textContainerInset = NSSize(width: 10, height: 10)
        codeTextView.delegate = self
        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.hasHorizontalScroller = true
        codeScroll.drawsBackground = true
        codeScroll.backgroundColor = .textBackgroundColor

        let formatAction = ControlAction { [weak self] _ in self?.onFormatJSON?() }
        let validateAction = ControlAction { [weak self] _ in self?.onValidateJSON?() }
        let applyAction = ControlAction { [weak self] _ in self?.onApplyJSON?() }
        let discardAction = ControlAction { [weak self] _ in self?.onDiscardJSON?() }
        let dotAction = ControlAction { [weak self] _ in self?.onPreviewDOT?() }
        for (button, action) in [
            (formatButton, formatAction), (validateButton, validateAction), (applyJSONButton, applyAction),
            (discardJSONButton, discardAction), (previewDOTButton, dotAction),
        ] {
            button.target = action
            button.action = #selector(ControlAction.invoke(_:))
            actions.append(action)
        }

        let modeRow = NSStackView(views: [makeLabel("СТРУКТУРА ПРОЕКТА · JSON", size: 8, weight: .bold, color: .secondaryLabelColor), NSView(), modeControl])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        let jsonActions = NSStackView(views: [formatButton, validateButton, applyJSONButton, discardJSONButton])
        jsonActions.orientation = .horizontal
        jsonActions.alignment = .centerY
        jsonActions.spacing = 5
        let dotActions = NSStackView(views: [previewDOTButton])
        dotActions.orientation = .horizontal
        dotActions.alignment = .centerY
        let toolbar = NSStackView(views: [jsonActions, dotActions])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let root = NSStackView(views: [modeRow, toolbar, statusLabel, codeScroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            modeRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            codeScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            codeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        codeScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        codeScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        codeTextView.minSize = .zero
        codeTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeTextView.isVerticallyResizable = true
        codeTextView.isHorizontallyResizable = true
        codeTextView.autoresizingMask = [.width]
        codeTextView.textContainer?.widthTracksTextView = true
        codeTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        modeRow.setContentHuggingPriority(.required, for: .vertical)
        toolbar.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        onSelectTab?(sender.selectedSegment == 1 ? .dot : .json)
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingCode else { return }
        lastCode = codeTextView.string
        if currentModel?.workspaceTab == .dot {
            onDOTChange?(lastCode)
            statusLabel.stringValue = "DOT изменён · проверьте совместимость перед применением"
        } else {
            onJSONChange?(lastCode)
            updateJSONStatus()
        }
    }

    func applyFormattedJSON(_ value: String) {
        isUpdatingCode = true
        codeTextView.string = value
        lastCode = value
        isUpdatingCode = false
        onJSONChange?(value)
        updateJSONStatus()
    }

    private func updateJSONStatus() {
        guard currentModel?.workspaceTab != .dot else { return }
        if currentModel?.activeProposal != nil {
            statusLabel.stringValue = "JSON предложения · только просмотр до применения или отмены"
            statusLabel.textColor = .controlAccentColor
            applyJSONButton.isEnabled = false
            return
        }
        if currentModel?.jsonDraftIsDirty != true {
            statusLabel.stringValue = currentModel?.diagram == nil
                ? "Ожидание локального backend…" : "Синхронизировано с холстом"
            statusLabel.textColor = .secondaryLabelColor
            applyJSONButton.isEnabled = false
            return
        }
        guard let data = codeTextView.string.data(using: .utf8) else {
            statusLabel.stringValue = "JSON: текст невозможно прочитать"
            statusLabel.textColor = .systemRed
            applyJSONButton.isEnabled = false
            return
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            statusLabel.stringValue = currentModel?.jsonDraftIsDirty == true
                ? "JSON синтаксически корректен · нажмите «Применить JSON»"
                : "Синхронизировано с холстом"
            statusLabel.textColor = currentModel?.jsonDraftIsDirty == true ? .controlAccentColor : .secondaryLabelColor
            applyJSONButton.isEnabled = currentModel?.jsonDraftIsDirty == true
        } catch {
            statusLabel.stringValue = "Ошибка JSON: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            applyJSONButton.isEnabled = false
        }
    }
}

@MainActor
private final class InspectorView: NSView {
    var onDelete: (() -> Void)?

    private let heading = NSTextField(labelWithString: "СВОЙСТВА")
    private let title = NSTextField(labelWithString: "Проект")
    private let scrollView = NSScrollView()
    private let stack = TopAlignedStackView()
    private let header = NSStackView()
    private var actions: [ControlAction] = []
    private var editableControls: [NSControl] = []
    private var isEditingLocked = false
    private var deleteButton: NSButton?
    private var displayedDiagram: DiagramProject?
    private var displayedSelection: DiagramSelection?
    private weak var currentModel: AppModel?
    private var figureCollectionID: String?
    private var figureNodeID: String?

    var preferredWindowContentHeight: CGFloat {
        min(620, max(280, documentHeight(for: stack) + 50))
    }
    var preferredWindowContentWidth: CGFloat { 360 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        currentModel = model
        deleteButton?.isHidden = model.selection == .project
        if displayedDiagram == model.diagram && displayedSelection == model.selection {
            setInteractionState(isEditingLocked: model.isEditingLocked)
            return
        }
        displayedDiagram = model.diagram
        displayedSelection = model.selection
        actions.removeAll()
        editableControls.removeAll()
        isEditingLocked = model.isEditingLocked
        stack.removeAllArrangedSubviews()
        deleteButton?.isEnabled = model.selection != .project && !model.isEditingLocked
        addFullWidth(separator())

        switch model.selection {
        case .project:
            title.stringValue = "Проект"
            addSection("СВЕДЕНИЯ")
            addText("Название проекта", value: model.diagram?.project.title ?? "") { value in model.updateTitle(value) }
            addPopup("Направление", value: model.diagram?.diagram.direction ?? "LR", choices: [
                ("LR", "Слева направо"), ("TB", "Сверху вниз"), ("RL", "Справа налево"), ("BT", "Снизу вверх"),
            ], tooltip: "Задаёт направление ранжирования компонентов: слева направо, сверху вниз или в обратную сторону.") { value in model.updateDirection(value) }
            addEdgeRouting(model: model, label: "Маршрут связей")
            addPopup("Тема", value: model.themeMode, choices: [("system", "Системная"), ("light", "Светлая"), ("dark", "Тёмная")]) { model.updateThemeMode($0) }
            addPopup("Тачпад", value: model.inverseTrackpad ? "inverse" : "follow", choices: [("follow", "За пальцами"), ("inverse", "Против пальцев")], tooltip: "Задаёт, движется ли холст вслед за пальцами по обеим осям или в обратную сторону.") { model.inverseTrackpad = $0 == "inverse" }
            addSection("КОМПОНОВКА")
            addPopup("Движок Graphviz", value: model.diagram?.diagram.layoutEngine ?? "dot", choices: [
                ("dot", "dot · иерархия"), ("neato", "neato · свободная сеть"), ("fdp", "fdp · силовая компоновка"),
                ("sfdp", "sfdp · большая сеть"), ("twopi", "twopi · радиальная"), ("circo", "circo · кольцевая"),
            ], tooltip: model.diagram?.diagram.layoutMode == "manual"
                ? "При ручном размещении Graphviz neato -n2 сохраняет координаты узлов и маршрутизирует связи. Этот движок применяется после возврата в автоматический режим."
                : "Выбранный Graphviz-движок размещает узлы и прокладывает связи.") { model.updateLayoutEngine($0) }
            addPopup("Режим", value: model.diagram?.diagram.layoutMode ?? "auto", choices: [
                ("auto", "Автоматический"), ("manual", "Ручной"),
            ], tooltip: "Автоматический: Graphviz размещает узлы. Ручной: координаты остаются фиксированными, neato -n2 пересчитывает связи.") { value in model.updateLayoutMode(value) }
        case .nodes(let ids):
            title.stringValue = "\(ids.count) компонентов"
            addSection("ГРУППА")
            addFullWidth(makeLabel("Компоненты можно перемещать, масштабировать за общий маркер или удалить вместе.", size: 10, weight: .regular, color: .secondaryLabelColor))
        case .node(let id):
            title.stringValue = "Компонент"
            if let node = model.nodes.first(where: { $0.id == id }) {
                addSection("ОБЩЕЕ")
                addText("Название", value: node.label) { value in model.editNode(id) { $0.label = value } }
                addText("Тип", value: node.kind, tooltip: "Семантический класс компонента. Учитывается при анализе и генерации Ollama, но не меняет форму и геометрию.") { value in model.editNode(id) { $0.kind = value } }
                addText("Z-index", value: String(node.effectiveZIndex), tooltip: "Порядок отрисовки перекрывающихся объектов. Большее число рисуется поверх меньшего; Graphviz не управляет этим порядком.") { value in
                    guard let index = Int(value), (-1_000_000...1_000_000).contains(index) else { return }
                    model.setNodeZIndex(id, index)
                }
                addReadOnly("ID", value: node.id)
                addPopup("Контейнер", value: node.containerId ?? "", choices: [("", "Без контейнера")] + model.containers.map { ($0.id, $0.label) }) { value in
                    model.editNode(id) { $0.containerId = value.isEmpty ? nil : value }
                }
                if figureNodeID != id {
                    figureNodeID = id
                    figureCollectionID = PaletteLibrary.allObjects.first(where: { $0.iconPath == node.icon })?.collectionID ?? "templates"
                }
                addPopup("Коллекция", value: figureCollectionID ?? "templates", choices: PaletteLibrary.collections.map { ($0.id, $0.title) }) { [weak self] value in
                    self?.figureCollectionID = value
                    self?.displayedDiagram = nil
                    self?.update(model: model)
                }
                let figures = PaletteLibrary.collection(id: figureCollectionID ?? "templates")?.objects ?? []
                addPopup("Фигура", value: figures.first(where: { $0.iconPath == node.icon })?.id ?? "", choices: [("", "Выберите фигуру…")] + figures.map { ($0.id, $0.title) }) { value in
                    if let figure = PaletteLibrary.object(id: value) { model.replaceFigure(id, with: figure) }
                }
                if model.diagram?.diagram.layoutMode == "manual" {
                    addText("X координата", value: node.x.map { String(format: "%.3f", $0) } ?? "") { value in
                        guard let coordinate = Double(value) else { return }
                        model.editNode(id) { $0.x = coordinate }
                    }
                    addText("Y координата", value: node.y.map { String(format: "%.3f", $0) } ?? "") { value in
                        guard let coordinate = Double(value) else { return }
                        model.editNode(id) { $0.y = coordinate }
                    }
                }
                addText("Описание", value: node.description) { value in model.editNode(id) { $0.description = value } }
                addSection("ВНЕШНИЙ ВИД")
                addColor("Заливка", value: node.style.fill) { color in model.editNode(id) { $0.style.fill = color } }
                addColor("Граница", value: node.style.stroke) { color in model.editNode(id) { $0.style.stroke = color } }
                addColor("Текст", value: node.style.text) { color in model.editNode(id) { $0.style.text = color } }
                addPopup("Выравнивание текста", value: node.effectiveLabelAlignment, choices: [
                    ("left", "Влево"), ("center", "По центру"), ("right", "Вправо"),
                ]) { value in model.editNode(id) { $0.labelAlignment = value } }
                addPopup("Положение текста", value: node.effectiveLabelVerticalAlignment, choices: [
                    ("top", "Сверху"), ("middle", "Посередине"), ("bottom", "Снизу"),
                ]) { value in model.editNode(id) { $0.labelVerticalAlignment = value } }
            }
        case .container(let id):
            title.stringValue = "Контейнер"
            if let item = model.containers.first(where: { $0.id == id }) {
                addSection("ОБЩЕЕ")
                addText("Название", value: item.label) { value in model.editContainer(id) { $0.label = value } }
                addReadOnly("ID", value: item.id)
                let descendants = model.descendantContainerIDs(of: id)
                let parents = [("", "Корневой контейнер")] + model.containers
                    .filter { $0.id != id && !descendants.contains($0.id) }
                    .map { ($0.id, $0.label) }
                addPopup("Родитель", value: item.parentId ?? "", choices: parents) { value in model.editContainer(id) { $0.parentId = value.isEmpty ? nil : value } }
                addText("Отступ, pt", value: String(format: "%.1f", item.padding)) { value in
                    guard let padding = Double(value) else { return }
                    model.editContainer(id) { $0.padding = min(48, max(4, padding)) }
                }
                addSection("ВНЕШНИЙ ВИД")
                addColor("Заливка", value: item.style.fill) { color in model.editContainer(id) { $0.style.fill = color } }
                addColor("Граница", value: item.style.stroke) { color in model.editContainer(id) { $0.style.stroke = color } }
                addColor("Текст", value: item.style.text) { color in model.editContainer(id) { $0.style.text = color } }
            }
        case .edge(let id):
            title.stringValue = "Связь"
            if let item = model.edges.first(where: { $0.id == id }) {
                addSection("СОЕДИНЕНИЕ")
                addText("Подпись", value: item.label) { value in model.editEdge(id) { $0.label = value } }
                let nodes = model.nodes.map { ($0.id, $0.label) }
                addPopup("Источник", value: item.source, choices: nodes) { value in model.editEdge(id) { $0.source = value; $0.sourcePort = "auto" } }
                addPopup("Цель", value: item.target, choices: nodes) { value in model.editEdge(id) { $0.target = value; $0.targetPort = "auto" } }
                addPopup("Направление", value: item.direction, choices: [
                    ("forward", "Односторонняя"), ("both", "Двусторонняя"), ("none", "Без стрелок"),
                ], tooltip: "Определяет, показывается ли стрелка к целевому компоненту, на обоих концах связи или не показывается.") { value in model.editEdge(id) { $0.direction = value } }
                addPopup("Стиль линии", value: item.style.lineStyle, choices: [
                    ("solid", "Сплошная"), ("dashed", "Пунктирная"), ("dotted", "Точечная"), ("bold", "Жирная"),
                ]) { value in model.editEdge(id) { $0.style.lineStyle = value } }
                addPopup("Маршрут этой связи", value: item.routing ?? "", choices: [("", "Как у диаграммы"), ("straight", "Прямая"), ("angled", "Косая ломаная"), ("orthogonal", "Прямоугольная"), ("curved", "Кривая · Graphviz")]) { value in model.editEdge(id) { $0.routing = value.isEmpty ? nil : value } }
                addPopup("Привязка источника", value: item.sourcePort, choices: CanvasGeometry.portChoices(model.nodes.first { $0.id == item.source })) { value in model.editEdge(id) { $0.sourcePort = value } }
                addPopup("Привязка цели", value: item.targetPort, choices: CanvasGeometry.portChoices(model.nodes.first { $0.id == item.target })) { value in model.editEdge(id) { $0.targetPort = value } }
                addPopup("Наконечник", value: item.style.arrowhead, choices: ["normal", "vee", "none", "diamond", "dot", "box", "crow", "tee"].map { ($0, $0) }) { value in model.editEdge(id) { $0.style.arrowhead = value } }
                addPopup("Хвост", value: item.style.arrowtail, choices: ["none", "normal", "vee", "diamond", "dot", "box", "crow", "tee"].map { ($0, $0) }) { value in model.editEdge(id) { $0.style.arrowtail = value } }
                addText("Толщина", value: String(item.style.penwidth)) { value in
                    if let width = Double(value), (0.5...10).contains(width) { model.editEdge(id) { $0.style.penwidth = width } }
                }
                let resetRoute = makeButton("Сбросить точки пути", symbol: "arrow.counterclockwise") { _ in model.editEdge(id) { $0.waypoints = [] } }
                resetRoute.identifier = NSUserInterfaceItemIdentifier("inspector-reset-route")
                editableControls.append(resetRoute); addFullWidth(resetRoute)
                addReadOnly("Точки пути", value: "\(item.waypoints.count) · двойной щелчок по линии добавляет точку")
                addColor("Цвет", value: item.style.color) { color in model.editEdge(id) { $0.style.color = color } }
                addReadOnly("ID", value: item.id)
            }
        }
        if stack.arrangedSubviews.count <= 2 {
            addFullWidth(makeLabel("Выбранный элемент не найден. Выберите объект на холсте или в списке слева.", size: 9, weight: .regular, color: .tertiaryLabelColor))
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setInteractionState(isEditingLocked: Bool) {
        self.isEditingLocked = isEditingLocked
        for control in editableControls { control.isEnabled = !isEditingLocked }
        deleteButton?.isHidden = title.stringValue == "Проект"
        deleteButton?.isEnabled = !isEditingLocked && title.stringValue != "Проект"
    }

    private func build() {
        wantsLayer = true
        layer?.name = "theme-surface-window"
        layer?.backgroundColor = AppTheme.surface("window").cgColor
        heading.font = .systemFont(ofSize: 8, weight: .bold)
        heading.textColor = .secondaryLabelColor
        heading.stringValue = "СВОЙСТВА"
        title.identifier = NSUserInterfaceItemIdentifier("inspector-title")
        title.font = .systemFont(ofSize: 14, weight: .bold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        scrollView.identifier = NSUserInterfaceItemIdentifier("inspector-properties-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        let delete = makeButton("Удалить", symbol: "trash") { [weak self] _ in self?.onDelete?() }
        delete.identifier = NSUserInterfaceItemIdentifier("inspector-delete")
        delete.isBordered = false
        delete.contentTintColor = .systemRed
        deleteButton = delete
        let titleRow = NSStackView(views: [delete, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12
        delete.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        delete.setContentHuggingPriority(.required, for: .horizontal)
        delete.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(heading)
        header.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        addSubview(header)
        addSubview(scrollView)
        header.autoresizingMask = [.minYMargin, .width]
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 32
        let topPadding: CGFloat = 14
        let scrollTopGap: CGFloat = 4
        header.frame = NSRect(x: 16, y: max(0, bounds.height - topPadding - headerHeight), width: max(0, bounds.width - 32), height: headerHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topPadding - headerHeight - scrollTopGap))
        let width = scrollView.contentView.bounds.width
        let height = documentHeight(for: stack)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        stack.layoutSubtreeIfNeeded()
    }

    private func documentHeight(for stack: NSStackView) -> CGFloat {
        let heights = stack.arrangedSubviews.map(measuredHeight)
        let contentHeight: CGFloat
        if stack.orientation == .vertical {
            contentHeight = heights.reduce(0, +)
        } else {
            contentHeight = heights.max() ?? 0
        }
        let spacing = stack.orientation == .vertical
            ? stack.spacing * CGFloat(max(0, stack.arrangedSubviews.count - 1)) : 0
        return contentHeight + spacing + stack.edgeInsets.top + stack.edgeInsets.bottom
    }

    private func measuredHeight(_ view: NSView) -> CGFloat {
        if let nestedStack = view as? NSStackView {
            return documentHeight(for: nestedStack)
        }
        let constrainedHeight = view.constraints
            .filter { $0.firstAttribute == .height && $0.relation == .equal }
            .map(\.constant)
            .max() ?? 0
        let height = max(view.fittingSize.height, view.intrinsicContentSize.height, constrainedHeight)
        if height > 0 { return height }
        if view is NSColorWell { return 26 }
        if view is NSControl { return 22 }
        if view is NSBox { return 1 }
        return 0
    }

    private func addSection(_ text: String) {
        let label = makeLabel(text, size: 8, weight: .bold, color: .secondaryLabelColor)
        label.identifier = NSUserInterfaceItemIdentifier("inspector-section-\(text)")
        addFullWidth(label)
    }

    private func addEdgeRouting(model: AppModel, label: String) {
        addPopup(label, value: model.diagram?.diagram.edgeRouting ?? "angled", choices: [
            ("straight", "Прямые"), ("angled", "Косые ломаные"), ("orthogonal", "Прямоугольные"), ("curved", "Кривые · Graphviz"),
        ], tooltip: "Выбирает общий способ прокладки связей. Индивидуальная связь может задать собственный маршрут.") { value in model.updateEdgeRouting(value) }
    }

    private func addText(_ label: String, value: String, tooltip: String? = nil, changed: @escaping (String) -> Void) {
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        field.font = .systemFont(ofSize: 11)
        field.toolTip = tooltip
        field.cell?.sendsActionOnEndEditing = true
        addField(label, control: field, tooltip: tooltip) { sender in changed((sender as? NSTextField)?.stringValue ?? "") }
    }

    private func addReadOnly(_ label: String, value: String) {
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = .secondaryLabelColor
        addField(label, control: field, action: nil)
    }

    private func addPopup(_ label: String, value: String, choices: [(String, String)], tooltip: String? = nil, changed: @escaping (String) -> Void) {
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        popup.toolTip = tooltip
        for (key, title) in choices {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = key
            if label == "Фигура", let item = PaletteLibrary.object(id: key) {
                popup.lastItem?.image = CanvasGeometry.thumbnail(icon: item.iconPath)
            }
        }
        if let selected = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) { popup.select(selected) }
        popup.font = .systemFont(ofSize: 10)
        addField(label, control: popup, tooltip: tooltip) { sender in
            guard let selected = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            changed(selected)
        }
    }

    private func addColor(_ label: String, value: String, changed: @escaping (String) -> Void) {
        NSColorPanel.shared.showsAlpha = true
        let well = ThemedColorWell()
        well.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        well.color = NSColor(hex: value)
        well.isContinuous = true
        well.onPanelClosed = { [weak self] in
            guard let self, let model = self.currentModel else { return }
            self.displayedDiagram = nil
            self.update(model: model)
        }
        addField(label, control: well) { sender in changed((sender as? NSColorWell)?.color.hexRGBA ?? value) }
    }

    private func addField(_ label: String, control: NSControl, tooltip: String? = nil, action: ((NSControl) -> Void)?) {
        let title = HelpFieldLabel(label, explanation: tooltip ?? Self.fieldHelp[label] ?? "Настройка определяет значение или поведение этого свойства.", identifier: "inspector-help-\(label)")
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 245).isActive = true
        let row = NSStackView(views: [title, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        addFullWidth(row)
        guard let action else { return }
        control.isEnabled = !isEditingLocked
        editableControls.append(control)
        let proxy = ControlAction(action)
        control.target = proxy
        control.action = #selector(ControlAction.invoke(_:))
        actions.append(proxy)
    }

    private static let fieldHelp: [String: String] = [
        "Название проекта": "Имя диаграммы. Отображается в верхней панели и используется в имени файла проекта и PDF-экспорта.",
        "Маршрут связей": "Выбирает общий вид линий на диаграмме. Отдельная связь может переопределить это значение.",
        "Тема": "Системная тема следует macOS; светлая и тёмная темы задаются вручную и применяются к окнам и холсту.",
        "Тачпад": "Инверсная навигация двигает холст против движения пальцев; системная повторяет направление прокрутки macOS.",
        "Движок Graphviz": "Выбирает алгоритм автоматической компоновки. В ручном режиме позиции узлов фиксирует neato -n2.",
        "Режим": "Автоматический режим размещает узлы Graphviz. Ручной сохраняет заданные координаты и пересчитывает маршруты.",
        "Название": "Подпись объекта на холсте. Изменение подписи не меняет стабильный идентификатор и связи.",
        "Тип": "Семантическая категория компонента. Используется в анализе и запросах Ollama, но не меняет геометрию.",
        "ID": "Стабильный идентификатор для связей, версий и обмена JSON. Переименование его не меняет.",
        "Контейнер": "Помещает компонент в логическую зону. Узлы внутри неё показываются в кластере.",
        "Коллекция": "Выбирает библиотеку фигур, из которой будет взята иконка компонента.",
        "Фигура": "Заменяет векторную фигуру компонента. Идентификатор, подпись и связи сохраняются.",
        "X координата": "Положение центра компонента по горизонтали в дюймах; доступно в ручном режиме.",
        "Y координата": "Положение центра компонента по вертикали в дюймах; доступно в ручном режиме.",
        "Описание": "Текстовое описание для контекста Ollama и подсказки компонента.",
        "Заливка": "Внутренний цвет фигуры. Поддерживает прозрачность через alpha-канал.",
        "Граница": "Цвет внешнего контура и внутренних линий векторной фигуры; поддерживает прозрачность.",
        "Текст": "Цвет подписи компонента или контейнера; поддерживает прозрачность.",
        "Выравнивание текста": "Выбирает размещение подписи по горизонтали внутри фигуры.",
        "Положение текста": "Размещает подпись у верхнего края, по центру или у нижнего края фигуры.",
        "Родитель": "Перемещает контейнер внутрь другого контейнера или на корневой уровень.",
        "Отступ, pt": "Расстояние вокруг содержимого контейнера. Изменяет размер кластера относительно вложенных объектов.",
        "Подпись": "Текст, отображаемый у линии связи.",
        "Источник": "Начальный компонент направленной связи.",
        "Цель": "Конечный компонент направленной связи.",
        "Направление": "Определяет стрелку в сторону цели, в обе стороны или линию без стрелок.",
        "Стиль линии": "Задаёт сплошное, пунктирное, точечное или утолщённое отображение связи.",
        "Маршрут этой связи": "Переопределяет общий маршрут диаграммы только для выбранной связи.",
        "Привязка источника": "Задаёт точку выхода линии из исходной фигуры: ближайший контур, сторону или вершину.",
        "Привязка цели": "Задаёт точку входа линии в целевую фигуру: ближайший контур, сторону или вершину.",
        "Наконечник": "Форма стрелки на целевой стороне однонаправленной связи.",
        "Хвост": "Форма стрелки на исходной стороне двунаправленной связи.",
        "Толщина": "Толщина линии связи в пунктах; влияет также на наконечники и PDF/SVG-экспорт.",
        "Точки пути": "Число пользовательских изгибов связи. Двойной щелчок по линии добавляет точку.",
        "Цвет": "Цвет линии и её наконечников; поддерживает прозрачность через alpha-канал.",
    ]

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
}

private final class ControlAction: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func invoke(_ sender: NSControl) { handler(sender) }
}

private func makeLabel(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

private func makeButton(_ title: String, symbol: String, prominent: Bool = false, handler: @escaping (NSControl) -> Void) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    button.imagePosition = .imageLeading
    button.controlSize = .small
    button.bezelStyle = prominent ? .rounded : .rounded
    button.font = .systemFont(ofSize: 10, weight: .medium)
    let action = ControlAction(handler)
    button.target = action
    button.action = #selector(ControlAction.invoke(_:))
    objc_setAssociatedObject(button, Unmanaged.passUnretained(action).toOpaque(), action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return button
}

private extension NSStackView {
    func removeAllArrangedSubviews() {
        for item in Array(arrangedSubviews) where item.superview === self {
            item.removeFromSuperview()
        }
    }
}
