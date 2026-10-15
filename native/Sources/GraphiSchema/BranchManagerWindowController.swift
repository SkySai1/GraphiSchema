import AppKit

@MainActor
final class BranchManagerWindowController: NSWindowController, NSWindowDelegate, ProjectThemedWindow {
    var projectModel: AppModel { model }
    private let model: AppModel
    private let onOpen: (ProjectWorkspace, Bool) -> Void
    private let graph = CommitGraphView()
    private let graphScroll = NSScrollView()
    private let preview = VersionPreviewView()
    private let branches = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private let splitController = NSSplitViewController()
    private var tree: CommitTree?
    private var selectedCommit: ProjectVersion?
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private var actions: [NSButton] = []

    init(model: AppModel, onOpen: @escaping (ProjectWorkspace, Bool) -> Void) {
        self.model = model; self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Ветки и коммиты"; window.minSize = NSSize(width: 880, height: 580)
        super.init(window: window)
        window.delegate = self
        build(); AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reloadAndShow() {
        showNearCursor(nil)
        reload()
    }
    private func reload() {
        loadTask?.cancel()
        previewTask?.cancel(); previewID = UUID()
        tree = nil; selectedCommit = nil; branches.removeAllItems(); graph.clear()
        actions.forEach { $0.isEnabled = false }
        preview.showPlaceholder("Выберите коммит", detail: "Загрузка истории текущего проекта…", isLoading: true)
        window?.title = "Ветки и коммиты — \(model.diagram?.project.title ?? "") [\(model.diagram?.project.id ?? "")]"
        let workspace = model.workspace
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await model.fetchCommitTree()
                guard !Task.isCancelled, model.workspace == workspace else { return }
                tree = result
                branches.removeAllItems()
                branches.addItems(withTitles: result.branches.map { "\($0.name) · №\($0.headVersionNumber ?? $0.headVersionId)" })
                if let index = result.branches.firstIndex(where: { $0.id == self.model.branchID }) { branches.selectItem(at: index) }
                graph.update(result)
                sizeGraph()
                actions.forEach { $0.isEnabled = !result.commits.isEmpty && !result.branches.isEmpty }
                status.stringValue = model.isTransientProject
                    ? "Пустой холст: проект, ветки и история появятся после первого изменения."
                    : "Проект: \(model.diagram?.project.title ?? result.projectId) · ветка: \(model.branchName). Выбор коммита открывает просмотр."
                let selected = result.commits.first { $0.id == self.selectedCommit?.id } ?? result.commits.first { $0.id == self.model.headVersionID } ?? result.commits.first
                if let selected { graph.select(selected.id); selectCommit(selected) }
            } catch { if !Task.isCancelled { status.stringValue = error.localizedDescription } }
        }
    }
    private var selectedBranch: BranchSummary? {
        guard let tree, tree.branches.indices.contains(branches.indexOfSelectedItem) else { return nil }
        return tree.branches[branches.indexOfSelectedItem]
    }
    private func selectCommit(_ version: ProjectVersion) {
        selectedCommit = version
        previewTask?.cancel(); previewID = UUID()
        preview.showPlaceholder("Коммит №\(version.displayNumber)", detail: "Загрузка диаграммы…", isLoading: true)
        let generation = previewID
        let workspace = model.workspace
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                let result = try await model.fetchVersionPreview(version.id)
                guard !Task.isCancelled, previewID == generation, model.workspace == workspace else { return }
                preview.inverseTrackpad = model.inverseTrackpad
                preview.show(result, version: version)
            } catch {
                guard !Task.isCancelled, previewID == generation else { return }
                preview.showPlaceholder("Не удалось открыть коммит", detail: error.localizedDescription, canRetry: true)
            }
        }
    }
    private func createBranch() {
        guard let version = selectedCommit, tree?.projectId == model.projectID else { return }
        let alert = NSAlert()
        alert.messageText = "Новая ветка от коммита №\(version.displayNumber)"
        alert.informativeText = "Сохранится общее прошлое до выбранного коммита. Дальнейшие изменения новой ветки будут независимыми."
        let field = NSTextField(string: "Новая ветка")
        let workspace = model.workspace
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.identifier = NSUserInterfaceItemIdentifier("branch-name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Создать и открыть")
        alert.addButton(withTitle: "Открыть в новом окне")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn, self.model.workspace == workspace else { return }
            Task { [self] in
                do {
                    let target = try await self.model.createBranch(name: field.stringValue, fromVersionID: version.id)
                    self.reload()
                    self.onOpen(target, response == .alertSecondButtonReturn)
                } catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    private func restoreCommit() {
        guard let version = selectedCommit, tree?.projectId == model.projectID else { return }
        let alert = NSAlert()
        alert.messageText = "Восстановить коммит №\(version.displayNumber) в ветке \(model.branchName)?"
        alert.informativeText = "В текущей ветке появится новый снимок. Существующие коммиты и другие ветки сохранятся."
        alert.addButton(withTitle: "Восстановить"); alert.addButton(withTitle: "Отмена")
        let workspace = model.workspace
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, self.model.workspace == workspace else { return }
            Task { [self] in
                do { try await self.model.restoreVersion(version.id); self.selectedCommit = nil; self.reload() }
                catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    private func build() {
        guard let content = window?.contentView else { return }
        branches.identifier = NSUserInterfaceItemIdentifier("branch-manager-branches")
        branches.target = self; branches.action = #selector(branchChanged)
        let open = ActionButton("Переключиться") { [weak self] in if let self, let branch = selectedBranch { onOpen(branch.workspace, false) } }
        let newWindow = ActionButton("В новом окне", symbol: "macwindow.on.rectangle") { [weak self] in if let self, let branch = selectedBranch { onOpen(branch.workspace, true) } }
        let create = ActionButton("Ветка от коммита", symbol: "arrow.triangle.branch") { [weak self] in self?.createBranch() }
        create.identifier = NSUserInterfaceItemIdentifier("branch-manager-create")
        let restore = ActionButton("Восстановить коммит") { [weak self] in self?.restoreCommit() }
        restore.identifier = NSUserInterfaceItemIdentifier("branch-manager-restore")
        let refresh = ActionButton("Обновить", symbol: "arrow.clockwise") { [weak self] in self?.reload() }
        actions = [open, newWindow, create, restore]; actions.forEach { $0.isEnabled = false }
        let top = NSStackView(views: [branches, open, newWindow, refresh]); top.orientation = .horizontal; top.spacing = 8
        let bottom = NSStackView(views: [create, restore, NSView()]); bottom.orientation = .horizontal; bottom.spacing = 8
        graph.identifier = NSUserInterfaceItemIdentifier("commit-tree")
        graph.onSelect = { [weak self] version in self?.selectCommit(version) }
        graphScroll.documentView = graph; graphScroll.hasVerticalScroller = true; graphScroll.hasHorizontalScroller = true
        let graphController = NSViewController(); graphController.view = graphScroll
        let previewController = NSViewController(); previewController.view = preview
        let graphItem = NSSplitViewItem(viewController: graphController); graphItem.minimumThickness = 150; graphItem.preferredThicknessFraction = 0.44
        let previewItem = NSSplitViewItem(viewController: previewController); previewItem.minimumThickness = 210
        splitController.splitView.isVertical = false
        splitController.addSplitViewItem(graphItem); splitController.addSplitViewItem(previewItem)
        let split = splitController.view
        preview.onRetry = { [weak self] in if let self, let selectedCommit { selectCommit(selectedCommit) } }
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        [top, split, bottom, status].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), top.heightAnchor.constraint(equalToConstant: 30),
            split.leadingAnchor.constraint(equalTo: top.leadingAnchor), split.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10), split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8), bottom.heightAnchor.constraint(equalToConstant: 30),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor), status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }
    @objc private func branchChanged() {
        if let branch = selectedBranch, let version = tree?.commits.first(where: { $0.id == branch.headVersionId }) {
            graph.select(version.id); graph.scrollToCommit(version.id); selectCommit(version)
        }
    }
    private func sizeGraph() {
        window?.contentView?.layoutSubtreeIfNeeded()
        graph.frame.size = NSSize(width: max(graph.preferredSize.width, graphScroll.contentView.bounds.width), height: graph.preferredSize.height)
    }
    func windowDidResize(_ notification: Notification) { sizeGraph() }
    func windowWillClose(_ notification: Notification) { loadTask?.cancel(); previewTask?.cancel(); previewID = UUID() }
}

@MainActor
final class CommitGraphView: NSView {
    var onSelect: ((ProjectVersion) -> Void)?
    private(set) var commits: [ProjectVersion] = []
    private var branches: [BranchSummary] = []
    private var rows: [Int: Int] = [:]
    private var lanes: [String: Int] = [:]
    private var selectedID: Int?
    private let rowHeight: CGFloat = 52
    private let headerHeight: CGFloat = 44
    private let laneWidth: CGFloat = 30
    override var isFlipped: Bool { true }
    var preferredSize: NSSize { NSSize(width: max(780, CGFloat(branches.count)*laneWidth+650), height: max(200, headerHeight+CGFloat(commits.count)*rowHeight)) }

    func clear() {
        commits = []; branches = []; rows = [:]; lanes = [:]; selectedID = nil; needsDisplay = true
    }

    func update(_ tree: CommitTree) {
        branches = tree.branches
        commits = tree.commits.sorted { $0.id > $1.id }
        rows = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($0.element.id, $0.offset) })
        lanes = Dictionary(uniqueKeysWithValues: branches.enumerated().map { ($0.element.id, $0.offset) })
        needsDisplay = true
    }
    func select(_ id: Int) { selectedID = id; needsDisplay = true }
    func scrollToCommit(_ id: Int) { if let row = rows[id] { scrollToVisible(frameForRow(row)) } }
    func frameForRow(_ row: Int) -> NSRect { NSRect(x: 0, y: headerHeight+CGFloat(row)*rowHeight, width: bounds.width, height: rowHeight) }
    private func point(_ version: ProjectVersion) -> NSPoint {
        NSPoint(x: 22+CGFloat(lanes[version.branchId ?? ""] ?? 0)*laneWidth,
                y: headerHeight+CGFloat(rows[version.id] ?? 0)*rowHeight+rowHeight/2)
    }
    private func color(_ version: ProjectVersion) -> NSColor {
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed, .systemTeal]
        return palette[(lanes[version.branchId ?? ""] ?? 0)%palette.count]
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        let textX = CGFloat(max(1, branches.count))*laneWidth+36
        ("История веток · новые коммиты сверху" as NSString).draw(at: NSPoint(x: 14, y: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        for version in commits {
            guard let parentID = version.parentId, let parent = byID[parentID] else { continue }
            let a = point(version), b = point(parent)
            guard NSRect(x: min(a.x,b.x)-4, y: min(a.y,b.y)-4, width: abs(a.x-b.x)+8, height: abs(a.y-b.y)+8).intersects(dirtyRect) else { continue }
            let path = NSBezierPath(); path.move(to: a)
            path.curve(to: b, controlPoint1: NSPoint(x: a.x, y: (a.y+b.y)/2), controlPoint2: NSPoint(x: b.x, y: (a.y+b.y)/2))
            path.lineWidth = 2; color(version).setStroke(); path.stroke()
        }
        for (row, version) in commits.enumerated() where frameForRow(row).intersects(dirtyRect) {
            let frame = frameForRow(row), center = point(version)
            if version.id == selectedID { NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); frame.fill() }
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x-5, y: center.y-5, width: 10, height: 10))
            color(version).setFill(); dot.fill(); NSColor.windowBackgroundColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
            let heads = branches.filter { $0.headVersionId == version.id }.map(\.name).joined(separator: ", ")
            let label = "№\(version.displayNumber) · \(version.message ?? version.title)"+(heads.isEmpty ? "" : "  [\(heads)]")
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (label as NSString).draw(in: NSRect(x: textX, y: frame.minY+7, width: max(1,bounds.width-textX-16), height: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            let branch = branches.first { $0.id == version.branchId }?.name ?? "main"
            let detail = "\(version.createdAt.replacingOccurrences(of: "T", with: " ")) · \(version.revision.prefix(12)) · \(branch)"
            (detail as NSString).draw(in: NSRect(x: textX, y: frame.minY+27, width: max(1,bounds.width-textX-16), height: 16),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        }
    }
    override func mouseDown(with event: NSEvent) {
        let position = convert(event.locationInWindow, from: nil)
        let row = Int(floor((position.y-headerHeight)/rowHeight))
        guard commits.indices.contains(row) else { return }
        select(commits[row].id); onSelect?(commits[row])
    }
}
