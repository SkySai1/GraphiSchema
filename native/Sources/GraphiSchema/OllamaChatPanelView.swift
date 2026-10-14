import AppKit
import ObjectiveC

@MainActor
final class OllamaChatPanelView: NSView, NSTextViewDelegate {
    var onSend: ((String, Int) -> Void)?
    var onConfigure: (() -> Void)?
    var onApplyProposal: (() -> Void)?
    var onCancelProposal: (() -> Void)?
    var onPromptExpansionChanged: ((Bool) -> Void)?

    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let promptTextView = ChatPromptTextView()
    private let promptScroll = NSScrollView()
    private let promptPlaceholder = NSTextField(labelWithString: "Опишите задачу для диаграммы…")
    private let expandPromptButton = NSButton(title: "Развернуть", target: nil, action: nil)
    private let modeControl = NSSegmentedControl(labels: ["Создать", "Изменить", "Проверить"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Локальный ассистент")
    private let sendButton: NSButton
    private let applyButton: NSButton
    private let cancelButton: NSButton
    private var actions: [ChatButtonAction] = []
    private var modelIsLocked = false
    private var isBusy = false
    private var promptExpanded = false
    private var promptHeightConstraint: NSLayoutConstraint?
    private var promptRowHeightConstraint: NSLayoutConstraint?

    init() {
        sendButton = Self.button("Отправить", symbol: "paperplane.fill")
        applyButton = Self.button("Применить · сохранить версию", symbol: "checkmark.circle.fill")
        cancelButton = Self.button("Отмена", symbol: "xmark")
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(model: AppModel) {
        modelIsLocked = model.isEditingLocked
        statusLabel.stringValue = model.ollamaProposal == nil ? model.status : "Есть предложение · JSON показан справа"
        applyButton.isHidden = model.ollamaProposal == nil
        cancelButton.isHidden = model.ollamaProposal == nil
        updateInputState()
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        if busy { statusLabel.stringValue = "Локальная модель готовит ответ…" }
        updateInputState()
    }

    func appendMessage(role: String, text: String) {
        guard !text.isEmpty else { return }
        if !transcript.string.isEmpty { transcript.textStorage?.append(NSAttributedString(string: "\n\n")) }
        let isUser = role == "Вы"
        let title = NSAttributedString(string: "\(role)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: isUser ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
        ])
        let body = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
        transcript.textStorage?.append(title)
        transcript.textStorage?.append(body)
        transcript.scrollToEndOfDocument(nil)
    }

    private func build() {
        identifier = NSUserInterfaceItemIdentifier("ollama-chat-panel")
        wantsLayer = true
        layer?.name = "theme-surface-panel"
        layer?.backgroundColor = AppTheme.surface("panel").cgColor
        layer?.cornerRadius = 8

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.textContainerInset = NSSize(width: 7, height: 6)
        transcript.font = .systemFont(ofSize: 11)
        transcript.backgroundColor = NSColor.textBackgroundColor
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder

        modeControl.selectedSegment = 1
        modeControl.segmentStyle = .rounded
        modeControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        promptTextView.isRichText = false
        promptTextView.identifier = NSUserInterfaceItemIdentifier("ollama-prompt-editor")
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.font = .systemFont(ofSize: 11)
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.textContainerInset = NSSize(width: 6, height: 5)
        promptTextView.onSubmit = { [weak self] in self?.sendPrompt() }
        promptTextView.delegate = self
        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.drawsBackground = true
        promptScroll.backgroundColor = NSColor.textBackgroundColor
        promptPlaceholder.font = .systemFont(ofSize: 11)
        promptPlaceholder.textColor = .placeholderTextColor
        promptPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        bind(sendButton) { [weak self] in self?.sendPrompt() }
        bind(applyButton) { [weak self] in self?.onApplyProposal?() }
        bind(cancelButton) { [weak self] in self?.onCancelProposal?() }
        expandPromptButton.title = "Развернуть"
        expandPromptButton.identifier = NSUserInterfaceItemIdentifier("ollama-prompt-expand")
        expandPromptButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Развернуть поле запроса")
        expandPromptButton.imagePosition = .imageLeading
        expandPromptButton.controlSize = .small
        expandPromptButton.font = .systemFont(ofSize: 9)
        expandPromptButton.target = self
        expandPromptButton.action = #selector(togglePromptExpansion)
        let settings = Self.button("Настройки", symbol: "gearshape")
        settings.toolTip = "Endpoint, модель, системный промпт и параметры Ollama"
        bind(settings) { [weak self] in self?.onConfigure?() }

        let heading = NSTextField(labelWithString: "ЧАТ · OLLAMA")
        heading.font = .systemFont(ofSize: 9, weight: .bold)
        heading.textColor = .secondaryLabelColor
        let headingRow = NSStackView(views: [heading, statusLabel, NSView(), applyButton, cancelButton, settings])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = 6
        let promptRow = NSStackView(views: [modeControl, promptScroll, expandPromptButton, sendButton])
        promptRow.orientation = .horizontal
        promptRow.alignment = .centerY
        promptRow.spacing = 7
        promptScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        promptScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [headingRow, transcriptScroll, promptRow].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        promptScroll.addSubview(promptPlaceholder)
        NSLayoutConstraint.activate([
            promptPlaceholder.leadingAnchor.constraint(equalTo: promptScroll.leadingAnchor, constant: 8),
            promptPlaceholder.centerYAnchor.constraint(equalTo: promptScroll.centerYAnchor),
        ])
        NSLayoutConstraint.activate([
            headingRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            headingRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            headingRow.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            headingRow.heightAnchor.constraint(equalToConstant: 25),
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            transcriptScroll.topAnchor.constraint(equalTo: headingRow.bottomAnchor, constant: 3),
            transcriptScroll.bottomAnchor.constraint(equalTo: promptRow.topAnchor, constant: -5),
            promptRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            promptRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            promptRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        promptHeightConstraint = promptScroll.heightAnchor.constraint(equalToConstant: 30)
        promptRowHeightConstraint = promptRow.heightAnchor.constraint(equalToConstant: 30)
        promptHeightConstraint?.isActive = true
        promptRowHeightConstraint?.isActive = true
        appendMessage(role: "Ассистент", text: "Введите задачу. Изменения появятся в JSON справа; перед записью в историю их можно проверить и применить.")
    }

    @objc private func sendPrompt() {
        let value = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        promptTextView.string = ""
        promptPlaceholder.isHidden = false
        appendMessage(role: "Вы", text: value)
        onSend?(value, modeControl.selectedSegment)
    }

    @objc private func togglePromptExpansion() {
        promptExpanded.toggle()
        let height: CGFloat = promptExpanded ? 86 : 30
        promptHeightConstraint?.constant = height
        promptRowHeightConstraint?.constant = height
        expandPromptButton.title = promptExpanded ? "Свернуть" : "Развернуть"
        expandPromptButton.toolTip = promptExpanded ? "Свернуть поле запроса" : "Развернуть поле для длинного запроса"
        onPromptExpansionChanged?(promptExpanded)
    }

    private func updateInputState() {
        let enabled = !isBusy && !modelIsLocked
        sendButton.isEnabled = enabled
        promptTextView.isEditable = enabled
        modeControl.isEnabled = enabled
    }

    private func bind(_ button: NSButton, action: @escaping () -> Void) {
        let proxy = ChatButtonAction(action)
        button.target = proxy
        button.action = #selector(ChatButtonAction.invoke(_:))
        objc_setAssociatedObject(button, Unmanaged.passUnretained(proxy).toOpaque(), proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        actions.append(proxy)
    }

    private static func button(_ title: String, symbol: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 10, weight: .medium)
        return button
    }

    func textDidChange(_ notification: Notification) {
        promptPlaceholder.isHidden = !promptTextView.string.isEmpty
    }
}

@MainActor
private final class ChatPromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onSubmit?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ChatButtonAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: NSControl) { handler() }
}
