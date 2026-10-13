import AppKit
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController {
    private let model: AppModel
    private let rootView = NSView()
    private let sidebar = SidebarView()
    private let workspace = WorkspaceView()
    private let inspector = InspectorView()
    private let titleField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "Подключение…")
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var ollamaWindowController: OllamaAssistantWindowController?
    private var retainedActions: [ControlAction] = []

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GraphiSchema"
        window.minSize = NSSize(width: 1120, height: 700)
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
        workspace.refresh(model: model)
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
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(workspace)
        split.addArrangedSubview(inspector)
        sidebar.widthAnchor.constraint(equalToConstant: 205).isActive = true
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 175).isActive = true
        inspector.widthAnchor.constraint(equalToConstant: 300).isActive = true
        inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

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
        split.setPosition(205, ofDividerAt: 0)
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

        let importButton = makeButton("Импорт", symbol: "square.and.arrow.down") { [weak self] _ in self?.importJSON() }
        let exportButton = makeButton("Экспорт", symbol: "square.and.arrow.up") { [weak self] _ in self?.exportJSON() }
        let pngButton = makeButton("PNG", symbol: "photo") { [weak self] _ in self?.exportPNG() }
        let historyButton = makeButton("История", symbol: "clock.arrow.circlepath") { [weak self] _ in self?.showHistory() }
        let ollamaButton = makeButton("Ollama", symbol: "sparkles") { [weak self] _ in self?.showOllamaAssistant() }
        undoButton = makeButton("Отменить", symbol: "arrow.uturn.backward") { [weak self] _ in self?.performHistoryCommand(redo: false) }
        redoButton = makeButton("Повторить", symbol: "arrow.uturn.forward") { [weak self] _ in self?.performHistoryCommand(redo: true) }
        undoButton?.keyEquivalent = "z"
        undoButton?.keyEquivalentModifierMask = .command
        redoButton?.keyEquivalent = "z"
        redoButton?.keyEquivalentModifierMask = [.command, .shift]
        let saveButton = makeButton("Сохранить", symbol: "checkmark.circle.fill", prominent: true) { [weak self] _ in self?.saveProject() }

        let stack = NSStackView(views: [brand, titleStack, status, importButton, exportButton, pngButton, historyButton, ollamaButton, undoButton!, redoButton!, saveButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func connectModel() {
        sidebar.onAddNode = { [weak self] in self?.model.addNode(); self?.refreshAll() }
        sidebar.onAddContainer = { [weak self] in self?.model.addContainer(); self?.refreshAll() }
        sidebar.onAddEdge = { [weak self] in self?.model.addEdge(); self?.refreshAll() }
        sidebar.onSelect = { [weak self] selection in
            self?.model.selection = selection
            self?.refreshInspector()
            self?.refreshSidebar()
        }
        workspace.onSelectElement = { [weak self] selection in
            guard let self else { return }
            self.model.selection = selection
            self.refreshInspector()
            self.refreshSidebar()
            self.workspace.refresh(model: self.model)
        }
        workspace.onMoveNode = { [weak self] id, x, y in
            self?.model.moveNode(id, x: x, y: y)
        }
        workspace.onMoveContainer = { [weak self] id, x, y in
            self?.model.moveContainer(id, deltaX: x, deltaY: y)
        }
        workspace.onResizeContainer = { [weak self] id, padding in
            self?.model.editContainer(id) { $0.padding = padding }
        }
        workspace.onSelectTab = { [weak self] tab in self?.selectTab(tab) }
        workspace.onApplyJSON = { [weak self] in self?.applyJSON() }
        workspace.onJSONChange = { [weak self] value in self?.model.jsonDraft = value }
        workspace.onDOTChange = { [weak self] value in self?.model.updateDOTDraft(value) }
        workspace.onPreviewDOT = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do { try await self.model.previewDOTDraft() }
                catch { self.showAlert(error.localizedDescription) }
            }
        }
        workspace.onApplyDOT = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do { try await self.model.applyCurrentProposal(); self.refreshAll() }
                catch { self.showAlert(error.localizedDescription) }
            }
        }
        workspace.onCancelDOT = { [weak self] in self?.model.cancelCurrentProposal() }
        inspector.onDelete = { [weak self] in self?.model.deleteSelection(); self?.refreshAll() }
        model.onModelChange = { [weak self] in self?.refreshSidebar(); self?.refreshHeader(); self?.workspace.refreshCounts(model: self?.model) }
        model.onPreviewChange = { [weak self] in
            guard let self else { return }
            self.workspace.refresh(model: self.model)
            self.refreshSidebar()
            self.refreshHeader()
        }
        model.onAlert = { [weak self] message in self?.showAlert(message) }
        sidebar.update(model: model)
        workspace.refresh(model: model)
        inspector.update(model: model)
        refreshHeader()
    }

    private func refreshSidebar() { sidebar.update(model: model) }
    private func refreshInspector() { inspector.update(model: model) }

    private func refreshHeader() {
        titleField.stringValue = model.diagram?.project.title ?? ""
        statusLabel.stringValue = model.status
        statusLabel.toolTip = model.backend.status
        undoButton?.isEnabled = model.history.canUndo
        redoButton?.isEnabled = model.history.canRedo
    }

    private func selectTab(_ tab: WorkspaceTab) {
        Task { @MainActor in
            await model.selectTab(tab)
            workspace.refresh(model: model)
            refreshHeader()
        }
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
            if model.workspaceTab == .json {
                do { try await model.applyJSONDraft() }
                catch { showAlert(error.localizedDescription); return }
            } else {
                await model.saveNow()
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
            if model.workspaceTab == .json {
                do { try await model.applyJSONDraft() }
                catch { showAlert(error.localizedDescription); return }
            } else {
                await model.saveNow()
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
        Task { @MainActor in
            do {
                if model.workspaceTab == .json {
                    try await model.applyJSONDraft()
                } else {
                    await model.saveNow()
                }
                let versions = try await model.fetchVersions()
                guard !versions.isEmpty else {
                    showAlert("Для этого проекта пока нет сохранённых версий.")
                    return
                }
                let picker = NSPopUpButton(frame: .zero, pullsDown: false)
                for version in versions {
                    let date = String(version.createdAt.replacingOccurrences(of: "T", with: " ").prefix(16))
                    picker.addItem(withTitle: "\(date) · \(version.title) · \(version.revision.prefix(7))")
                }
                picker.selectItem(at: 0)
                let options = NSStackView(views: [makeLabel("Снимок", size: 11, weight: .medium, color: .labelColor), picker])
                options.orientation = .horizontal
                options.alignment = .centerY
                options.spacing = 10
                options.widthAnchor.constraint(equalToConstant: 520).isActive = true

                let alert = NSAlert()
                alert.messageText = "История проекта"
                alert.informativeText = "Сравните выбранную версию с текущей или восстановите её."
                alert.accessoryView = options
                alert.addButton(withTitle: "Сравнить")
                alert.addButton(withTitle: "Восстановить")
                alert.addButton(withTitle: "Закрыть")
                alert.beginSheetModal(for: window!) { response in
                    let selectedIndex = picker.indexOfSelectedItem
                    guard versions.indices.contains(selectedIndex) else { return }
                    let version = versions[selectedIndex]
                    if response == .alertFirstButtonReturn {
                        Task { @MainActor in
                            do { self.showVersionDiff(try await self.model.fetchVersionDiff(version.id)) }
                            catch { self.showAlert(error.localizedDescription) }
                        }
                    } else if response == .alertSecondButtonReturn {
                        Task { @MainActor in
                            do {
                                try await self.model.restoreVersion(version.id)
                                self.refreshAll()
                            } catch { self.showAlert(error.localizedDescription) }
                        }
                    }
                }
            } catch { showAlert(error.localizedDescription) }
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
private final class SidebarView: NSView {
    var onAddNode: (() -> Void)?
    var onAddContainer: (() -> Void)?
    var onAddEdge: (() -> Void)?
    var onSelect: ((DiagramSelection) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var actions: [ControlAction] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 12, right: 12)
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        actions.removeAll()
        stack.removeAllArrangedSubviews()
        addArranged(section("ИНСТРУМЕНТЫ"))
        addArranged(actionButton("Компонент", symbol: "plus.square", key: "n") { [weak self] in self?.onAddNode?() })
        addArranged(actionButton("Контейнер", symbol: "rectangle.3.group") { [weak self] in self?.onAddContainer?() })
        addArranged(actionButton("Связь", symbol: "arrow.up.right", key: "e") { [weak self] in self?.onAddEdge?() })
        addArranged(separator())
        addArranged(section("КОНТЕЙНЕРЫ · \(model.containers.count)"))
        if model.containers.isEmpty { addArranged(hint("Нет контейнеров")) }
        for container in model.containers {
            addArranged(elementButton(container.label, symbol: "rectangle.dashed", color: NSColor(hex: container.style.stroke), selected: model.selection == .container(container.id)) { [weak self] in self?.onSelect?(.container(container.id)) })
        }
        addArranged(separator())
        addArranged(section("КОМПОНЕНТЫ · \(model.nodes.count)"))
        if model.nodes.isEmpty { addArranged(hint("Нет компонентов")) }
        for node in model.nodes {
            addArranged(elementButton(node.label, symbol: "square", color: NSColor(hex: node.style.stroke), selected: model.selection == .node(node.id)) { [weak self] in self?.onSelect?(.node(node.id)) })
        }
        addArranged(separator())
        addArranged(section("СВЯЗИ · \(model.edges.count)"))
        if model.edges.isEmpty { addArranged(hint("Нет связей")) }
        for edge in model.edges {
            let source = model.nodes.first(where: { $0.id == edge.source })?.label ?? edge.source
            let target = model.nodes.first(where: { $0.id == edge.target })?.label ?? edge.target
            let title = edge.label.isEmpty ? "\(source) → \(target)" : edge.label
            addArranged(elementButton(title, symbol: "arrow.right", color: NSColor(hex: edge.style.color), selected: model.selection == .edge(edge.id)) { [weak self] in self?.onSelect?(.edge(edge.id)) })
        }
        addArranged(separator())
        let local = makeLabel("●  Данные и backend остаются локально", size: 9, weight: .medium, color: NSColor(hex: "#3F8064"))
        local.lineBreakMode = .byWordWrapping
        addArranged(local)
    }

    private func addArranged(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
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
private final class WorkspaceView: NSView, NSTextViewDelegate {
    var onSelectTab: ((WorkspaceTab) -> Void)?
    var onApplyJSON: (() -> Void)?
    var onJSONChange: ((String) -> Void)?
    var onDOTChange: ((String) -> Void)?
    var onPreviewDOT: (() -> Void)?
    var onApplyDOT: (() -> Void)?
    var onCancelDOT: (() -> Void)?
    var onSelectElement: ((DiagramSelection) -> Void)?
    var onMoveNode: ((String, Double, Double) -> Void)?
    var onMoveContainer: ((String, Double, Double) -> Void)?
    var onResizeContainer: ((String, Double) -> Void)?

    private let header = NSStackView()
    private let content = NSView()
    private let canvasSplit = NSSplitView()
    private let canvasView = DiagramCanvasView()
    private let codeScroll = NSScrollView()
    private let codeTextView = NSTextView()
    private let footer = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let layoutLabel = NSTextField(labelWithString: "")
    private var previewDOTButton = NSButton(title: "Проверить DOT", target: nil, action: nil)
    private var applyDOTButton = NSButton(title: "Применить", target: nil, action: nil)
    private var cancelDOTButton = NSButton(title: "Отмена", target: nil, action: nil)
    private var actions: [ControlAction] = []
    private var lastCode = ""
    private var activeCodeTab: WorkspaceTab = .canvas
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
        canvasView.isReadOnly = proposal != nil
        canvasView.update(
            diagram: proposal?.diagram ?? model.diagram,
            layout: proposal?.layout ?? model.layout,
            selection: proposal == nil ? model.selection : .project
        )
        codeTextView.isEditable = model.workspaceTab == .json || model.workspaceTab == .dot
        activeCodeTab = model.workspaceTab
        let hasPreview = proposal != nil
        countLabel.isHidden = model.workspaceTab == .dot || hasPreview
        layoutLabel.isHidden = model.workspaceTab == .dot || hasPreview
        previewDOTButton.isHidden = model.workspaceTab != .dot
        applyDOTButton.isHidden = !hasPreview || model.workspaceTab == .json
        cancelDOTButton.isHidden = !hasPreview || model.workspaceTab == .json
        applyDOTButton.isEnabled = hasPreview
        cancelDOTButton.isEnabled = hasPreview
        canvasSplit.isHidden = false
        switch model.workspaceTab {
        case .canvas:
            canvasView.isHidden = false
            codeScroll.isHidden = true
            if let proposal {
                presentProposal(proposal, model: model, split: false)
            } else {
                showingProposal = false
            }
        case .json:
            canvasView.isHidden = true
            codeScroll.isHidden = false
            showingProposal = false
            setCode(model.jsonDraft)
        case .dot:
            canvasView.isHidden = !hasPreview
            codeScroll.isHidden = false
            setCode(model.dotSource)
            if let proposal {
                presentProposal(proposal, model: model, split: true)
            } else {
                showingProposal = false
            }
        }
    }

    private func presentProposal(_ proposal: DiagramProposal, model: AppModel, split: Bool) {
        layoutSubtreeIfNeeded()
        if !showingProposal {
            if split {
                canvasSplit.setPosition(bounds.width * 0.5, ofDividerAt: 0)
                layoutSubtreeIfNeeded()
            }
            canvasView.fitToContent()
        }
        let source = model.dotPreview == nil ? "Предложение Ollama" : "Предпросмотр DOT"
        footer.stringValue = "\(source) · \(proposal.changes.entries.count) изменений · примените или отмените"
        footer.toolTip = proposal.changes.entries.joined(separator: "\n")
        showingProposal = true
    }

    func refreshCounts(model: AppModel?) {
        guard let model else { return }
        countLabel.stringValue = "\(model.nodes.count) объектов · \(model.edges.count) связей"
        updateCanvasStatus(model)
    }

    private func updateCanvasStatus(_ model: AppModel) {
        footer.stringValue = "Ревизия \(model.revision.isEmpty ? "—" : model.revision) · двигайте узлы/зоны; маркер зоны — отступ · ⌥ панорама · ⌘-колесо/щипок масштаб"
        footer.toolTip = "Перетаскивайте компоненты и зоны мышью. Потяните маркер выбранной зоны, чтобы изменить её отступ. Удерживайте Option для панорамирования. Масштабируйте кнопками, жестом щипка или Command + прокрутка."
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
        let canvas = tabButton(.canvas)
        let json = tabButton(.json)
        let dot = tabButton(.dot)
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
        previewDOTButton = makeButton("Проверить DOT", symbol: "checkmark.magnifyingglass") { [weak self] _ in self?.onPreviewDOT?() }
        applyDOTButton = makeButton("Применить", symbol: "checkmark.circle.fill") { [weak self] _ in self?.onApplyDOT?() }
        cancelDOTButton = makeButton("Отмена", symbol: "xmark") { [weak self] _ in self?.onCancelDOT?() }
        [previewDOTButton, applyDOTButton, cancelDOTButton].forEach { $0.controlSize = .small; $0.isHidden = true }
        canvasView.onSelect = { [weak self] selection in self?.onSelectElement?(selection) }
        canvasView.onMoveNode = { [weak self] id, x, y in self?.onMoveNode?(id, x, y) }
        canvasView.onMoveContainer = { [weak self] id, x, y in self?.onMoveContainer?(id, x, y) }
        canvasView.onResizeContainer = { [weak self] id, padding in self?.onResizeContainer?(id, padding) }
        let spacer = NSView()
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        layoutLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        layoutLabel.textColor = .controlAccentColor
        header.addArrangedSubview(canvas)
        header.addArrangedSubview(json)
        header.addArrangedSubview(dot)
        header.addArrangedSubview(previewDOTButton)
        header.addArrangedSubview(applyDOTButton)
        header.addArrangedSubview(cancelDOTButton)
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
        canvasSplit.isVertical = true
        canvasSplit.dividerStyle = .thin
        canvasSplit.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false

        codeTextView.isRichText = false
        codeTextView.isAutomaticQuoteSubstitutionEnabled = false
        codeTextView.isAutomaticDashSubstitutionEnabled = false
        codeTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        codeTextView.textColor = NSColor(hex: "#D6DEEC")
        codeTextView.backgroundColor = NSColor(hex: "#111827")
        codeTextView.insertionPointColor = .white
        codeTextView.delegate = self
        codeScroll.documentView = codeTextView
        codeScroll.hasVerticalScroller = true
        codeScroll.hasHorizontalScroller = true
        codeScroll.drawsBackground = true
        codeScroll.backgroundColor = NSColor(hex: "#111827")
        codeScroll.translatesAutoresizingMaskIntoConstraints = false

        canvasSplit.addArrangedSubview(codeScroll)
        canvasSplit.addArrangedSubview(canvasView)
        content.addSubview(canvasSplit)
        NSLayoutConstraint.activate([
            canvasSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor), canvasSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvasSplit.topAnchor.constraint(equalTo: content.topAnchor), canvasSplit.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 48),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor), separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: separator.bottomAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func tabButton(_ tab: WorkspaceTab) -> NSButton {
        let button = NSButton(title: tab.rawValue, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let action = ControlAction { [weak self] _ in self?.onSelectTab?(tab) }
        button.target = action
        button.action = #selector(ControlAction.invoke(_:))
        actions.append(action)
        return button
    }

    private func setCode(_ value: String) {
        guard lastCode != value else { return }
        lastCode = value
        codeTextView.string = value
    }

    func textDidChange(_ notification: Notification) {
        lastCode = codeTextView.string
        if activeCodeTab == .json { onJSONChange?(codeTextView.string) }
        if activeCodeTab == .dot { onDOTChange?(codeTextView.string) }
    }
}

@MainActor
private final class InspectorView: NSView {
    var onDelete: (() -> Void)?

    private let heading = NSTextField(labelWithString: "СВОЙСТВА")
    private let title = NSTextField(labelWithString: "Проект")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var actions: [ControlAction] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        actions.removeAll()
        stack.removeAllArrangedSubviews()
        let delete = makeButton("Удалить", symbol: "trash") { [weak self] _ in self?.onDelete?() }
        delete.isBordered = false
        delete.contentTintColor = .systemRed
        delete.isEnabled = model.selection != .project
        let top = NSStackView(views: [title, NSView(), delete])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 4
        addFullWidth(top)
        addFullWidth(separator())

        switch model.selection {
        case .project:
            title.stringValue = "Проект"
            addSection("СВЕДЕНИЯ")
            addText("Название проекта", value: model.diagram?.project.title ?? "") { value in model.updateTitle(value) }
            addPopup("Направление", value: model.diagram?.diagram.direction ?? "LR", choices: [
                ("LR", "Слева направо"), ("TB", "Сверху вниз"), ("RL", "Справа налево"), ("BT", "Снизу вверх"),
            ]) { value in model.updateDirection(value) }
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
                addColor("Цвет", value: item.style.color) { color in model.editEdge(id) { $0.style.color = color } }
                addReadOnly("ID", value: item.id)
            }
        }
    }

    private func build() {
        heading.font = .systemFont(ofSize: 8, weight: .bold)
        heading.textColor = .secondaryLabelColor
        heading.stringValue = "СВОЙСТВА"
        title.font = .systemFont(ofSize: 14, weight: .bold)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [heading, title])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14), header.heightAnchor.constraint(equalToConstant: 42),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    private func addSection(_ text: String) {
        let label = makeLabel(text, size: 8, weight: .bold, color: .secondaryLabelColor)
        addFullWidth(label)
    }

    private func addText(_ label: String, value: String, changed: @escaping (String) -> Void) {
        let field = NSTextField(string: value)
        field.font = .systemFont(ofSize: 11)
        field.cell?.sendsActionOnEndEditing = true
        addField(label, control: field) { sender in changed((sender as? NSTextField)?.stringValue ?? "") }
    }

    private func addReadOnly(_ label: String, value: String) {
        let field = NSTextField(string: value)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = .secondaryLabelColor
        addField(label, control: field, action: nil)
    }

    private func addPopup(_ label: String, value: String, choices: [(String, String)], changed: @escaping (String) -> Void) {
        let popup = NSPopUpButton()
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
        for item in arrangedSubviews {
            removeArrangedSubview(item)
            item.removeFromSuperview()
        }
    }
}
