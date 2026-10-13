import AppKit
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, NSSplitViewDelegate {
    private let model: AppModel
    private let rootView = NSView()
    private let sidebar = SidebarView()
    private let workspace = WorkspaceView()
    private let codePanel = JSONCodePanelView()
    private var styleInspector: InspectorView?
    private var styleWindowController: NSWindowController?
    private var historyWindowController: VersionHistoryWindowController?
    private let titleField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "Подключение…")
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var importButton: NSButton?
    private var ollamaWindowController: OllamaAssistantWindowController?
    private var retainedActions: [ControlAction] = []
    private var didSetInitialSplitPositions = false
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
        window.minSize = NSSize(width: 1280, height: 720)
        window.center()
        super.init(window: window)
        window.contentView = rootView
        buildInterface()
        connectModel()
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
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = buildHeader()
        let divider = NSBox()
        divider.boxType = .separator
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(workspace)
        split.addArrangedSubview(codePanel)
        sidebar.setContentCompressionResistancePriority(.required, for: .horizontal)
        codePanel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [header, divider, split].forEach {
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
            split.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            split.topAnchor.constraint(equalTo: divider.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 225).isActive = true
        codePanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
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
        if dividerIndex == 0 { return 225 }
        return splitView.subviews[0].frame.width + splitView.dividerThickness + 600
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
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
        brand.widthAnchor.constraint(equalToConstant: 205).isActive = true

        let titleStack = NSStackView(views: [
            makeLabel("ЛОКАЛЬНЫЙ ПРОЕКТ", size: 8, weight: .bold, color: .secondaryLabelColor),
            titleField,
        ])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
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

        importButton = makeButton("Импорт", symbol: "square.and.arrow.down") { [weak self] _ in self?.importJSON() }
        let exportButton = makeButton("Экспорт", symbol: "square.and.arrow.up") { [weak self] _ in self?.exportJSON() }
        let pngButton = makeButton("PNG", symbol: "photo") { [weak self] _ in self?.exportPNG() }
        let historyButton = makeButton("История", symbol: "clock.arrow.circlepath") { [weak self] _ in self?.showHistory() }
        let ollamaButton = makeButton("Настройки ИИ", symbol: "gearshape") { [weak self] _ in self?.showOllamaAssistant() }
        undoButton = makeButton("Отменить", symbol: "arrow.uturn.backward") { [weak self] _ in self?.performHistoryCommand(redo: false) }
        redoButton = makeButton("Повторить", symbol: "arrow.uturn.forward") { [weak self] _ in self?.performHistoryCommand(redo: true) }
        undoButton?.keyEquivalent = "z"
        undoButton?.keyEquivalentModifierMask = .command
        redoButton?.keyEquivalent = "z"
        redoButton?.keyEquivalentModifierMask = [.command, .shift]
        let saveButton = makeButton("Сохранить", symbol: "checkmark.circle.fill", prominent: true) { [weak self] _ in self?.saveProject() }

        let stack = NSStackView(views: [brand, titleStack, status, importButton!, exportButton, pngButton, historyButton, ollamaButton, undoButton!, redoButton!, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func connectModel() {
        sidebar.onAddNode = { [weak self] item in self?.model.addNode(item) }
        sidebar.onAddContainer = { [weak self] in self?.model.addContainer() }
        sidebar.onAddEdge = { [weak self] in self?.model.addEdge() }
        sidebar.onSelect = { [weak self] selection in
            self?.model.selection = selection
            self?.refreshInspector()
            self?.refreshSidebar()
            if let self { self.refreshCanvas(force: true) }
        }
        workspace.onSelectElement = { [weak self] selection in
            guard let self else { return }
            self.model.selection = selection
            self.refreshInspector()
            self.refreshSidebar()
            self.refreshCanvas(force: true)
        }
        workspace.onMoveNode = { [weak self] id, x, y in
            self?.model.moveNode(id, x: x, y: y)
        }
        workspace.onResizeNode = { [weak self] id, width, height in
            self?.model.editNode(id) { $0.width = width; $0.height = height }
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
        inspector.update(model: model)
        let targetHeight = inspector.preferredWindowContentHeight
        if abs((window.contentView?.frame.height ?? 0) - targetHeight) > 2 {
            window.setContentSize(NSSize(width: max(440, window.contentView?.frame.width ?? 460), height: targetHeight))
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
        importButton?.isEnabled = !model.isEditingLocked
        undoButton?.isEnabled = model.history.canUndo && !model.isEditingLocked
        redoButton?.isEnabled = model.history.canRedo && !model.isEditingLocked
    }

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
            inspector.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
            inspector.onDelete = { [weak self] in
                guard let self else { return }
                self.model.deleteSelection()
                self.refreshAll()
            }
            styleInspector = inspector
        }
        inspector.update(model: model)
        if let controller = styleWindowController {
            controller.window?.setContentSize(NSSize(width: max(440, controller.window?.contentView?.frame.width ?? 460), height: inspector.preferredWindowContentHeight))
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            controller.window?.layoutIfNeeded()
            inspector.layoutSubtreeIfNeeded()
            return
        }
        let contentHeight = inspector.preferredWindowContentHeight
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Оформление и свойства"
        window.minSize = NSSize(width: 440, height: 280)
        inspector.frame = NSRect(x: 0, y: 0, width: 460, height: contentHeight)
        inspector.autoresizingMask = [.width, .height]
        window.contentView = inspector
        window.setContentSize(NSSize(width: 460, height: contentHeight))
        let controller = NSWindowController(window: window)
        styleWindowController = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
        controller.window?.layoutIfNeeded()
        inspector.layoutSubtreeIfNeeded()
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
            guard model.activeProposal == nil else {
                showAlert("Сначала примените или отмените предложение.")
                return
            }
            if model.jsonDraftIsDirty {
                do { try await model.applyJSONDraft() }
                catch { showAlert(error.localizedDescription); return }
            } else {
                do { try await model.saveNow() }
                catch { showAlert("Не удалось сохранить проект: \(error.localizedDescription)"); refreshHeader(); return }
            }
            refreshHeader()
        }
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
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    await self.model.importJSON(try Data(contentsOf: url))
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

        let scaleRow = NSStackView(views: [makeLabel("Масштаб", size: 11, weight: .medium, color: .labelColor), scalePopup])
        let backgroundRow = NSStackView(views: [makeLabel("Фон", size: 11, weight: .medium, color: .labelColor), backgroundPopup])
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

    private func showOllamaAssistant() {
        if let controller = ollamaWindowController {
            controller.showWindow(self)
            controller.window?.makeKeyAndOrderFront(self)
            return
        }
        let controller = OllamaAssistantWindowController(model: model)
        ollamaWindowController = controller
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
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
        alert.messageText = "Отличия от версии «\(diff.versionTitle)»"
        alert.informativeText = lines.isEmpty ? "Изменений нет." : lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Закрыть")
        alert.beginSheetModal(for: window!)
    }

    @objc private func titleChanged(_ sender: NSTextField) { model.updateTitle(sender.stringValue) }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
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
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
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
private final class SidebarView: NSView {
    var onAddNode: ((PaletteObject) -> Void)?
    var onAddContainer: (() -> Void)?
    var onAddEdge: (() -> Void)?
    var onSelect: ((DiagramSelection) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let paletteStack = NSStackView()
    private let contentStack = NSStackView()
    private let searchField = NSSearchField()
    private let collectionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var selectedCollectionID = "all"
    private var lastPaletteFingerprint: String?
    private var lastContentFingerprint: String?
    private var lastPaletteLockState: Bool?
    private var paletteItemViews: [String: PaletteItemView] = [:]
    private var widthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var actions: [ControlAction] = []
    private weak var currentModel: AppModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("diagram-palette")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for column in [paletteStack, contentStack] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 5
            column.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(column)
            column.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        searchField.placeholderString = "Найти объект…"
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
        scrollView.documentView = stack
        scrollView.identifier = NSUserInterfaceItemIdentifier("palette-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        currentModel = model
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let selectionKey: String
        switch model.selection {
        case .project: selectionKey = "project"
        case .node(let id): selectionKey = "node:\(id)"
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
        clearArrangedSubviews(from: paletteStack)
        actions.removeAll()
        if let selected = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == selectedCollectionID }) {
            collectionPicker.select(selected)
        }
        addArranged(section("КОЛЛЕКЦИЯ ОБЪЕКТОВ"), to: paletteStack)
        addArranged(collectionPicker, to: paletteStack)
        addArranged(searchField, to: paletteStack)
        addArranged(hint("Нажмите или перетащите объект на холст"), to: paletteStack)
        let paletteItems = (PaletteLibrary.collection(id: selectedCollectionID)?.objects ?? []).filter {
            query.isEmpty || $0.title.localizedLowercase.contains(query) || $0.detail.localizedLowercase.contains(query) || $0.kind.localizedLowercase.contains(query)
        }
        addArranged(section("ОБЪЕКТЫ · \(paletteItems.count)"), to: paletteStack)
        for item in paletteItems {
            let paletteItem = paletteItemViews[item.id] ?? PaletteItemView(item: item)
            paletteItemViews[item.id] = paletteItem
            paletteItem.isEditingLocked = model.isEditingLocked
            if paletteItem.onClick == nil { paletteItem.onClick = { [weak self] in self?.onAddNode?(item) } }
            addArranged(paletteItem, to: paletteStack)
        }
        if paletteItems.isEmpty { addArranged(hint("Объекты не найдены"), to: paletteStack) }
    }

    private func rebuildContent(model: AppModel) {
        clearArrangedSubviews(from: contentStack)
        actions.removeAll()
        addArranged(separator(), to: contentStack)
        addArranged(section("ДЕЙСТВИЯ"), to: contentStack)
        let addContainer = actionButton("Добавить контейнер", symbol: "rectangle.3.group") { [weak self] in self?.onAddContainer?() }
        addContainer.isEnabled = !model.isEditingLocked
        addArranged(addContainer, to: contentStack)
        let addEdge = actionButton("Добавить связь", symbol: "arrow.up.right", key: "e") { [weak self] in self?.onAddEdge?() }
        addEdge.isEnabled = !model.isEditingLocked
        addArranged(addEdge, to: contentStack)
        addArranged(separator(), to: contentStack)
        addArranged(section("КОНТЕЙНЕРЫ · \(model.containers.count)"), to: contentStack)
        if model.containers.isEmpty { addArranged(hint("Нет контейнеров"), to: contentStack) }
        for container in model.containers {
            addArranged(elementButton(container.label, symbol: "rectangle.dashed", color: NSColor(hex: container.style.stroke), selected: model.selection == .container(container.id)) { [weak self] in self?.onSelect?(.container(container.id)) }, to: contentStack)
        }
        addArranged(separator(), to: contentStack)
        addArranged(section("КОМПОНЕНТЫ · \(model.nodes.count)"), to: contentStack)
        if model.nodes.isEmpty { addArranged(hint("Нет компонентов"), to: contentStack) }
        for node in model.nodes {
            addArranged(elementButton(node.label, symbol: "square", color: NSColor(hex: node.style.stroke), selected: model.selection == .node(node.id)) { [weak self] in self?.onSelect?(.node(node.id)) }, to: contentStack)
        }
        addArranged(separator(), to: contentStack)
        addArranged(section("СВЯЗИ · \(model.edges.count)"), to: contentStack)
        if model.edges.isEmpty { addArranged(hint("Нет связей"), to: contentStack) }
        let nodeLabels = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.id, $0.label) })
        for edge in model.edges {
            let source = nodeLabels[edge.source] ?? edge.source
            let target = nodeLabels[edge.target] ?? edge.target
            let title = edge.label.isEmpty ? "\(source) → \(target)" : edge.label
            addArranged(elementButton(title, symbol: "arrow.right", color: NSColor(hex: edge.style.color), selected: model.selection == .edge(edge.id)) { [weak self] in self?.onSelect?(.edge(edge.id)) }, to: contentStack)
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
        stack.frame = NSRect(x: 0, y: 0, width: width, height: max(height, scrollView.contentView.bounds.height))
        stack.layoutSubtreeIfNeeded()
    }

    @objc private func searchPalette() {
        guard let currentModel else { return }
        update(model: currentModel)
        window?.makeFirstResponder(searchField)
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
        let viewsHeight = stack.arrangedSubviews.reduce(CGFloat.zero) { total, view in
            total + (view is NSStackView ? documentHeight(for: view as! NSStackView) : max(view.fittingSize.height, view.frame.height))
        }
        let spacing = stack.spacing * CGFloat(max(0, stack.arrangedSubviews.count - 1))
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

    private func elementButton(_ title: String, symbol: String, color: NSColor, selected: Bool, action: @escaping () -> Void) -> NSButton {
        let button = makeButton(title, symbol: symbol) { _ in action() }
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = selected ? .controlAccentColor : color
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
private final class WorkspaceView: NSView {
    var onSelectElement: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double) -> Void)?
    var onResizeNode: ((String, Double, Double) -> Void)?
    var onCreateEdge: ((String, String) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?
    var onDropPaletteItem: ((PaletteObject, Double, Double, String?) -> Void)?
    var onShowStyle: (() -> Void)?
    var onConfigureOllama: (() -> Void)?
    var onOllamaMessage: ((String, Int) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onApplyProposal: (() -> Void)?
    var onCancelProposal: (() -> Void)?

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

    private func updateCanvasStatus(_ model: AppModel) {
        footer.stringValue = "Ревизия \(model.revision.isEmpty ? "—" : model.revision) · узлы: движение/размер · синий маркер: связь · ⌥ панорама"
        footer.toolTip = "Перетаскивайте компоненты из левой палитры на холст. Выберите узел: нижний правый маркер меняет размер, синий маркер справа создаёт связь перетаскиванием к другому узлу. Нажмите линию, чтобы выбрать связь и открыть её стиль. Option панорамирует; Command + прокрутка и щипок меняют масштаб."
        if model.diagram?.diagram.layoutMode == "manual" {
            layoutLabel.stringValue = "Graphviz · neato · вручную"
        } else {
            layoutLabel.stringValue = "Graphviz · \(model.layout?.engine ?? model.diagram?.diagram.layoutEngine ?? "dot")"
        }
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: "#F5F7FA").cgColor

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false
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
        styleButton = makeButton("Стиль", symbol: "paintpalette") { [weak self] _ in self?.onShowStyle?() }
        applyProposalButton = makeButton("Применить", symbol: "checkmark.circle.fill") { [weak self] _ in self?.onApplyProposal?() }
        cancelProposalButton = makeButton("Отменить", symbol: "xmark") { [weak self] _ in self?.onCancelProposal?() }
        [applyProposalButton, cancelProposalButton].forEach { $0.controlSize = .small; $0.isHidden = true }
        canvasView.onSelect = { [weak self] selection in self?.onSelectElement?(selection) }
        canvasView.onMoveNode = { [weak self] id, x, y in self?.onMoveNode?(id, x, y) }
        canvasView.onResizeNode = { [weak self] id, width, height in self?.onResizeNode?(id, width, height) }
        canvasView.onCreateEdge = { [weak self] source, target in self?.onCreateEdge?(source, target) }
        canvasView.onMoveContainer = { [weak self] id, x, y in self?.onMoveContainer?(id, x, y) }
        canvasView.onResizeContainer = { [weak self] id, padding in self?.onResizeContainer?(id, padding) }
        canvasView.onDropPaletteItem = { [weak self] item, x, y, containerID in self?.onDropPaletteItem?(item, x, y, containerID) }
        canvasView.onRequestStyle = { [weak self] in self?.onShowStyle?() }
        canvasView.onDeleteSelection = { [weak self] in self?.onDeleteSelection?() }
        chatPanel.onConfigure = { [weak self] in self?.onConfigureOllama?() }
        chatPanel.onSend = { [weak self] prompt, mode in self?.onOllamaMessage?(prompt, mode) }
        chatPanel.onApplyProposal = { [weak self] in self?.onApplyProposal?() }
        chatPanel.onCancelProposal = { [weak self] in self?.onCancelProposal?() }
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
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(countLabel)
        header.addArrangedSubview(makeLabel("·", size: 10, weight: .regular, color: .tertiaryLabelColor))
        header.addArrangedSubview(layoutLabel)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        chatPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvasView)
        content.addSubview(chatPanel)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: content.leadingAnchor), canvasView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: content.topAnchor), canvasView.bottomAnchor.constraint(equalTo: chatPanel.topAnchor),
            chatPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8), chatPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            chatPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6), chatPanel.heightAnchor.constraint(equalToConstant: 205),
        ])

        footer.font = .systemFont(ofSize: 9)
        footer.textColor = .tertiaryLabelColor
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let separator = NSBox()
        separator.boxType = .separator
        [header, separator, content, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 48),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor), separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: separator.bottomAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 30),
        ])
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
        layer?.backgroundColor = NSColor(hex: "#F8FAFC").cgColor
        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .rounded
        modeControl.widthAnchor.constraint(equalToConstant: 150).isActive = true
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))

        codeTextView.isRichText = false
        codeTextView.isAutomaticQuoteSubstitutionEnabled = false
        codeTextView.isAutomaticDashSubstitutionEnabled = false
        codeTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeTextView.textColor = NSColor(hex: "#D6DEEC")
        codeTextView.backgroundColor = NSColor(hex: "#111827")
        codeTextView.insertionPointColor = .white
        codeTextView.textContainerInset = NSSize(width: 10, height: 10)
        codeTextView.delegate = self
        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.hasHorizontalScroller = true
        codeScroll.drawsBackground = true
        codeScroll.backgroundColor = NSColor(hex: "#111827")

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
    private let stack = NSStackView()
    private let header = NSStackView()
    private var actions: [ControlAction] = []
    private var editableControls: [NSControl] = []
    private var isEditingLocked = false
    private var deleteButton: NSButton?
    private var displayedDiagram: DiagramProject?
    private var displayedSelection: DiagramSelection?

    var preferredWindowContentHeight: CGFloat {
        min(620, max(280, documentHeight(for: stack) + 63))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
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
            ]) { value in model.updateDirection(value) }
            addEdgeRouting(model: model, label: "Маршрут связей")
            addSection("КОМПОНОВКА")
            let engine = model.diagram?.diagram.layoutMode == "manual"
                ? "neato (ручной)"
                : (model.diagram?.diagram.layoutEngine ?? "dot")
            addReadOnly("Движок", value: engine)
            addPopup("Режим", value: model.diagram?.diagram.layoutMode ?? "auto", choices: [
                ("auto", "Автоматический"), ("manual", "Ручной"),
            ]) { value in model.updateLayoutMode(value) }
        case .node(let id):
            title.stringValue = "Компонент"
            if let node = model.nodes.first(where: { $0.id == id }) {
                addSection("ОБЩЕЕ")
                addText("Название", value: node.label) { value in model.editNode(id) { $0.label = value } }
                addText("Тип", value: node.kind) { value in model.editNode(id) { $0.kind = value } }
                addReadOnly("ID", value: node.id)
                addPopup("Контейнер", value: node.containerId ?? "", choices: [("", "Без контейнера")] + model.containers.map { ($0.id, $0.label) }) { value in
                    model.editNode(id) { $0.containerId = value.isEmpty ? nil : value }
                }
                addPopup("Форма", value: node.shape, choices: [
                    ("box", "Карточка"), ("ellipse", "Эллипс"), ("cylinder", "Цилиндр"),
                    ("diamond", "Ромб"), ("hexagon", "Шестиугольник"), ("cloud", "Облако"),
                ]) { value in model.editNode(id) { $0.shape = value } }
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
                addPopup("Источник", value: item.source, choices: nodes) { value in model.editEdge(id) { $0.source = value } }
                addPopup("Цель", value: item.target, choices: nodes) { value in model.editEdge(id) { $0.target = value } }
                addPopup("Направление", value: item.direction, choices: [
                    ("forward", "Односторонняя"), ("both", "Двусторонняя"), ("none", "Без стрелок"),
                ]) { value in model.editEdge(id) { $0.direction = value } }
                addPopup("Стиль линии", value: item.style.lineStyle, choices: [
                    ("solid", "Сплошная"), ("dashed", "Пунктирная"), ("dotted", "Точечная"), ("bold", "Жирная"),
                ]) { value in model.editEdge(id) { $0.style.lineStyle = value } }
                addEdgeRouting(model: model, label: "Маршрут всех связей")
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
        deleteButton?.isEnabled = !isEditingLocked && title.stringValue != "Проект"
    }

    private func build() {
        heading.font = .systemFont(ofSize: 8, weight: .bold)
        heading.textColor = .secondaryLabelColor
        heading.stringValue = "СВОЙСТВА"
        title.font = .systemFont(ofSize: 14, weight: .bold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        scrollView.identifier = NSUserInterfaceItemIdentifier("inspector-properties-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        let delete = makeButton("Удалить", symbol: "trash") { [weak self] _ in self?.onDelete?() }
        delete.isBordered = false
        delete.contentTintColor = .systemRed
        deleteButton = delete
        let titleRow = NSStackView(views: [title, NSView(), delete])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
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
        let headerHeight: CGFloat = 42
        let topPadding: CGFloat = 14
        let scrollTopGap: CGFloat = 7
        header.frame = NSRect(x: 16, y: max(0, bounds.height - topPadding - headerHeight), width: max(0, bounds.width - 32), height: headerHeight)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topPadding - headerHeight - scrollTopGap))
        let width = scrollView.contentView.bounds.width
        let height = documentHeight(for: stack)
        stack.frame = NSRect(x: 0, y: 0, width: width, height: max(height, scrollView.contentView.bounds.height))
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
        addFullWidth(label)
    }

    private func addEdgeRouting(model: AppModel, label: String) {
        addPopup(label, value: model.diagram?.diagram.edgeRouting ?? "angled", choices: [
            ("straight", "Прямые"), ("angled", "Косые ломаные"), ("orthogonal", "Прямоугольные"),
        ]) { value in model.updateEdgeRouting(value) }
    }

    private func addText(_ label: String, value: String, changed: @escaping (String) -> Void) {
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        field.font = .systemFont(ofSize: 11)
        field.cell?.sendsActionOnEndEditing = true
        addField(label, control: field) { sender in changed((sender as? NSTextField)?.stringValue ?? "") }
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

    private func addPopup(_ label: String, value: String, choices: [(String, String)], changed: @escaping (String) -> Void) {
        let popup = NSPopUpButton()
        popup.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        for (key, title) in choices {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = key
        }
        if let selected = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) { popup.select(selected) }
        popup.font = .systemFont(ofSize: 10)
        addField(label, control: popup) { sender in
            guard let selected = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            changed(selected)
        }
    }

    private func addColor(_ label: String, value: String, changed: @escaping (String) -> Void) {
        let well = NSColorWell()
        well.identifier = NSUserInterfaceItemIdentifier("inspector-field-\(label)")
        well.color = NSColor(hex: value)
        addField(label, control: well) { sender in changed((sender as? NSColorWell)?.color.hexRGB ?? value) }
    }

    private func addField(_ label: String, control: NSControl, action: ((NSControl) -> Void)?) {
        let title = makeLabel(label, size: 9, weight: .medium, color: .secondaryLabelColor)
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
