import AppKit

/// Edits canonical labels immediately; keeps the container heading at its fixed size.
@MainActor
final class ElementTextEditorWindowController: NSWindowController, NSTextViewDelegate, ProjectThemedWindow {
    var projectModel: AppModel { model }
    let selection: DiagramSelection
    private let model: AppModel
    private let projectID: String?
    private let text = NSTextView()
    private var updating = false
    private var lastApplied: String?
    init(model: AppModel, selection: DiagramSelection) {
        self.model = model; self.selection = selection; projectID = model.projectID
        let window = InspectorPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 178), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.title = selection.edgeIDs.isEmpty ? "Текст контейнера" : "Текст связи"
        window.identifier = NSUserInterfaceItemIdentifier("element-text-window")
        super.init(window: window)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.addArrangedSubview(HelpFieldLabel("Подпись", explanation: "Текст обновляется сразу на холсте и в коде. Cmd+Z отменяет изменение. Название контейнера имеет постоянный размер 11 pt; пустая подпись допустима и для контейнера, и для связи.", identifier: "element-text-help"))
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 356).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        text.frame = NSRect(x: 0, y: 0, width: 356, height: 88); text.isRichText = false; text.allowsUndo = true
        text.identifier = NSUserInterfaceItemIdentifier("element-text-value")
        text.font = .systemFont(ofSize: 12); text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.delegate = self
        scroll.documentView = text; root.addArrangedSubview(scroll)
        root.addArrangedSubview(ActionButton("Готово") { [weak self] in self?.close() })
        window.contentView = root; refresh(); AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refresh() {
        guard projectID == model.projectID else { close(); return }
        let value: String?
        switch selection {
        case .container(let id): value = model.containers.first { $0.id == id }?.label
        case .edge(let id): value = model.edges.first { $0.id == id }?.label
        default: value = nil
        }
        guard let value else { close(); return }
        updating = true
        text.isEditable = !model.isEditingLocked
        if value != lastApplied { text.string = value }; lastApplied = value
        updating = false
    }
    func textDidChange(_ notification: Notification) {
        guard !updating, !model.isEditingLocked, projectID == model.projectID else { return }
        let value = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        switch selection {
        case .container(let id): if value.unicodeScalars.count <= 120 { lastApplied = value; model.editContainer(id) { $0.label = value } }
        case .edge(let id): if value.unicodeScalars.count <= 160 { lastApplied = value; model.editEdge(id) { $0.label = value } }
        default: break
        }
    }
}
