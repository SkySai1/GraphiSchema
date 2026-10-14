import AppKit
import ObjectiveC

@MainActor
final class OllamaAssistantWindowController: NSWindowController {
    private let model: AppModel
    private let endpointField = NSTextField(string: "")
    private let modelField = NSComboBox()
    private let temperatureField = NSTextField(string: "0.2")
    private let contextField = NSTextField(string: "8192")
    private let timeoutField = NSTextField(string: "120")
    private let systemPromptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Настройки применяются только к локальному endpoint.")
    private var actions: [AssistantButtonAction] = []
    private var variablesWindow: PromptVariablesWindowController?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GraphiSchema · Ollama"
        window.minSize = NSSize(width: 560, height: 500)
        window.center()
        super.init(window: window)
        buildInterface()
        loadPreferences()
        AppTheme.configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface() {
        let root = NSView()
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 11
        form.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = root
        root.addSubview(form)

        let heading = NSTextField(labelWithString: "ПОДКЛЮЧЕНИЕ И ПАРАМЕТРЫ МОДЕЛИ")
        heading.font = .systemFont(ofSize: 10, weight: .bold)
        heading.textColor = .secondaryLabelColor

        endpointField.placeholderString = "http://127.0.0.1:11434"
        endpointField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        endpointField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let checkButton = button("Проверить", symbol: "arrow.clockwise") { [weak self] in self?.checkConnection() }
        let endpointRow = row(helpLabel("Endpoint", width: 74, explanation: "Адрес локального Ollama API, например http://127.0.0.1:11434. Кнопка проверки запрашивает доступные модели."), endpointField, checkButton)

        modelField.isEditable = true
        modelField.placeholderString = "Выберите установленную модель"
        modelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modelRow = row(helpLabel("Модель", width: 66, explanation: "Локальная модель Ollama, которая будет обрабатывать запросы и проверять диаграмму."), modelField)

        temperatureField.placeholderString = "0.2"
        contextField.placeholderString = "8192"
        timeoutField.placeholderString = "120"
        [temperatureField, contextField, timeoutField].forEach { $0.alignment = .left }
        let settingsRow = NSStackView(views: [
            helpLabel("Температура", width: 76, explanation: "Управляет вариативностью ответа: низкие значения дают более стабильные изменения, высокие — больше разнообразия."), temperatureField,
            helpLabel("Контекст", width: 54, explanation: "Максимальное число токенов контекста, передаваемого модели. Большой контекст расходует больше памяти."), contextField,
            helpLabel("Тайм-аут, с", width: 70, explanation: "Максимальное время ожидания ответа Ollama для одного запроса."), timeoutField,
        ])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 7
        for field in [temperatureField, contextField, timeoutField] {
            field.widthAnchor.constraint(equalToConstant: field === contextField ? 72 : 58).isActive = true
        }

        let promptHeading = HelpFieldLabel("СИСТЕМНЫЙ ПРОМПТ · JINJA: {{ graphviz_attributes }}", explanation: "Инструкции Ollama для создания, изменения и проверки диаграмм. Переменные шаблона подставляются перед каждым запросом.", identifier: "ollama-help-system-prompt", fontSize: 9)
        systemPromptView.isRichText = false
        systemPromptView.identifier = NSUserInterfaceItemIdentifier("ollama-system-prompt")
        systemPromptView.isAutomaticQuoteSubstitutionEnabled = false
        systemPromptView.isAutomaticDashSubstitutionEnabled = false
        systemPromptView.font = .systemFont(ofSize: 11)
        systemPromptView.textContainerInset = NSSize(width: 9, height: 8)
        systemPromptView.isVerticallyResizable = true
        systemPromptView.isHorizontallyResizable = false
        systemPromptView.autoresizingMask = [.width]
        systemPromptView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView()
        promptScroll.documentView = systemPromptView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.heightAnchor.constraint(equalToConstant: 285).isActive = true

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        let saveButton = button("Сохранить настройки", symbol: "checkmark.circle.fill", prominent: true) { [weak self] in self?.savePreferences() }
        let actionsRow = NSStackView(views: [saveButton, statusLabel])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 12

        let variables = button("Переменные…", symbol: "curlybraces") { [weak self] in self?.showVariables() }
        variables.identifier = NSUserInterfaceItemIdentifier("ollama-prompt-variables")
        variables.toolTip = "Открыть переменные и справочник Graphviz, доступные системному промпту."
        let promptRow = NSStackView(views: [promptHeading, NSView(), variables])
        promptRow.orientation = .horizontal; promptRow.spacing = 8
        [heading, endpointRow, modelRow, settingsRow, promptRow, promptScroll, actionsRow].forEach { form.addArrangedSubview($0) }
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
            endpointRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            settingsRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            promptScroll.widthAnchor.constraint(equalTo: form.widthAnchor),
            promptRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            actionsRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    func showVariables() {
        if let existing = variablesWindow { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = PromptVariablesWindowController(model: model) { [weak self] in self?.systemPromptView.string ?? "" }
        variablesWindow = controller; controller.showWindow(nil)
    }

    private func loadPreferences() {
        let preferences = model.ollamaPreferences
        endpointField.stringValue = preferences.endpoint
        modelField.stringValue = preferences.model
        temperatureField.stringValue = String(preferences.temperature)
        contextField.stringValue = String(preferences.numCtx)
        timeoutField.stringValue = String(preferences.timeout)
        systemPromptView.string = preferences.systemPrompt
    }

    private func checkConnection() {
        guard let preferences = readPreferences(requireModel: false) else { return }
        model.updateOllamaPreferences(preferences)
        statusLabel.stringValue = "Проверка подключения…"
        Task { @MainActor in
            do {
                let models = try await model.fetchOllamaModels()
                modelField.removeAllItems()
                modelField.addItems(withObjectValues: models.map(\.name))
                if !preferences.model.isEmpty {
                    modelField.stringValue = preferences.model
                } else if let first = models.first {
                    modelField.stringValue = first.name
                }
                statusLabel.stringValue = "Ollama доступна · моделей: \(models.count). Сохраните выбранную модель."
            } catch {
                statusLabel.stringValue = "Нет подключения: \(error.localizedDescription)"
            }
        }
    }

    private func savePreferences() {
        guard let preferences = readPreferences() else { return }
        model.updateOllamaPreferences(preferences)
        statusLabel.stringValue = "Настройки сохранены локально."
    }

    private func readPreferences(requireModel: Bool = true) -> OllamaPreferences? {
        guard let temperature = Double(temperatureField.stringValue), (0...2).contains(temperature),
              let context = Int(contextField.stringValue), (512...131072).contains(context),
              let timeout = Double(timeoutField.stringValue), (1...300).contains(timeout) else {
            statusLabel.stringValue = "Проверьте параметры: температура 0–2, контекст 512–131072, тайм-аут 1–300 секунд."
            return nil
        }
        var preferences = model.ollamaPreferences
        preferences.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.systemPrompt = systemPromptView.string
        preferences.temperature = temperature
        preferences.numCtx = context
        preferences.timeout = timeout
        guard !preferences.endpoint.isEmpty, !requireModel || !preferences.model.isEmpty else {
            statusLabel.stringValue = requireModel ? "Укажите endpoint и выберите модель." : "Укажите endpoint Ollama."
            return nil
        }
        return preferences
    }

    private func row(_ views: NSView...) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal
        result.alignment = .centerY
        result.spacing = 8
        return result
    }

    private func helpLabel(_ value: String, width: CGFloat, explanation: String) -> NSView {
        let result = HelpFieldLabel(value, explanation: explanation, identifier: "ollama-help-\(value)", fontSize: 11)
        result.widthAnchor.constraint(equalToConstant: width + 21).isActive = true
        return result
    }

    private func button(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.controlSize = .regular
        button.bezelStyle = .rounded
        if prominent { button.keyEquivalent = "\r" }
        let proxy = AssistantButtonAction(action)
        button.target = proxy
        button.action = #selector(AssistantButtonAction.invoke(_:))
        objc_setAssociatedObject(button, Unmanaged.passUnretained(proxy).toOpaque(), proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        actions.append(proxy)
        return button
    }
}

@MainActor
private final class AssistantButtonAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: NSControl) { handler() }
}
