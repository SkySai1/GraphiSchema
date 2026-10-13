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
    private let taskView = NSTextView()
    private let resultView = NSTextView()
    private let modeControl = NSSegmentedControl(labels: ["Создать", "Изменить", "Проверить"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Endpoint: локальный Ollama")
    private var runButton: NSButton?
    private var buttonActions: [AssistantButtonAction] = []

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GraphiSchema · Ollama"
        window.minSize = NSSize(width: 700, height: 680)
        window.center()
        super.init(window: window)
        buildInterface()
        loadPreferences()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false

        let endpointRow = NSStackView()
        endpointRow.orientation = .horizontal
        endpointRow.alignment = .centerY
        endpointRow.spacing = 8
        endpointField.placeholderString = "http://127.0.0.1:11434"
        endpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true
        endpointField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        endpointRow.addArrangedSubview(fieldLabel("Endpoint", width: 70))
        endpointRow.addArrangedSubview(endpointField)
        endpointRow.addArrangedSubview(button("Модели / связь", symbol: "arrow.clockwise") { [weak self] in self?.loadModels() })
        root.addArrangedSubview(endpointRow)

        modelField.isEditable = true
        modelField.placeholderString = "Выберите установленную модель"
        modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let modelRow = NSStackView(views: [fieldLabel("Модель", width: 70), modelField])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 8
        root.addArrangedSubview(modelRow)

        let settingsRow = NSStackView()
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 8
        addSetting("Температура", field: temperatureField, width: 70, to: settingsRow)
        addSetting("Контекст", field: contextField, width: 90, to: settingsRow)
        addSetting("Тайм-аут, с", field: timeoutField, width: 60, to: settingsRow)
        root.addArrangedSubview(settingsRow)

        root.addArrangedSubview(section("СИСТЕМНЫЙ ПРОМПТ"))
        root.addArrangedSubview(textScroll(systemPromptView, height: 95))
        root.addArrangedSubview(section("РЕЖИМ И ЗАДАНИЕ"))
        modeControl.selectedSegment = 0
        root.addArrangedSubview(modeControl)
        root.addArrangedSubview(textScroll(taskView, height: 120))

        let runRow = NSStackView()
        runRow.orientation = .horizontal
        runRow.alignment = .centerY
        runRow.spacing = 10
        runButton = button("Выполнить", symbol: "sparkles", prominent: true) { [weak self] in self?.runSelectedMode() }
        runRow.addArrangedSubview(runButton!)
        runRow.addArrangedSubview(statusLabel)
        root.addArrangedSubview(runRow)

        root.addArrangedSubview(section("ОТВЕТ / ОТЧЁТ"))
        root.addArrangedSubview(textScroll(resultView, height: 190, editable: false))
        let footnote = NSTextField(labelWithString: "Предложение появится на холсте главного окна; применяйте или отменяйте его там. Проверка только формирует отчёт и не изменяет проект.")
        footnote.font = .systemFont(ofSize: 10)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(footnote)

        window?.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 16),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window!.contentView!.bottomAnchor, constant: -16),
            endpointRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            settingsRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 370),
            runRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            footnote.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
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

    private func loadModels() {
        guard let preferences = readPreferences(requireModel: false) else { return }
        model.updateOllamaPreferences(preferences)
        statusLabel.stringValue = "Подключение…"
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
                statusLabel.stringValue = "Ollama доступна · моделей: \(models.count)"
            } catch {
                statusLabel.stringValue = "Нет подключения"
                resultView.string = error.localizedDescription
            }
        }
    }

    private func runSelectedMode() {
        guard let preferences = readPreferences() else { return }
        let prompt = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            resultView.string = "Введите задание для выбранного режима."
            return
        }
        model.updateOllamaPreferences(preferences)
        resultView.string = ""
        statusLabel.stringValue = "Запрос к локальной модели…"
        runButton?.isEnabled = false
        let mode = modeControl.selectedSegment
        Task { @MainActor in
            defer { runButton?.isEnabled = true }
            do {
                if mode == 2 {
                    let response = try await model.reviewWithOllama(prompt)
                    resultView.string = response.report.text
                    statusLabel.stringValue = "Read-only проверка завершена"
                } else {
                    let proposal = try await model.generateWithOllama(prompt, editing: mode == 1)
                    let changes = proposal.changes.entries
                    resultView.string = changes.isEmpty
                        ? "Предложение не содержит отличий от текущего проекта."
                        : "Предложенные изменения:\n" + changes.joined(separator: "\n")
                    statusLabel.stringValue = "Предложение показано на холсте"
                }
            } catch {
                resultView.string = error.localizedDescription
                statusLabel.stringValue = "Ошибка запроса"
            }
        }
    }

    private func readPreferences(requireModel: Bool = true) -> OllamaPreferences? {
        guard let temperature = Double(temperatureField.stringValue), (0...2).contains(temperature),
              let context = Int(contextField.stringValue), (512...131072).contains(context),
              let timeout = Double(timeoutField.stringValue), (1...300).contains(timeout)
        else {
            resultView.string = "Проверьте параметры: температура 0–2, контекст 512–131072, тайм-аут 1–300 секунд."
            statusLabel.stringValue = "Некорректные настройки"
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
            resultView.string = requireModel ? "Укажите endpoint и выберите установленную модель." : "Укажите endpoint Ollama."
            statusLabel.stringValue = requireModel ? "Нужны endpoint и модель" : "Нужен endpoint"
            return nil
        }
        return preferences
    }

    private func addSetting(_ title: String, field: NSTextField, width: CGFloat, to stack: NSStackView) {
        field.stringValue = ""
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(fieldLabel(title, width: nil))
        stack.addArrangedSubview(field)
    }

    private func textScroll(_ textView: NSTextView, height: CGFloat, editable: Bool = true) -> NSScrollView {
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 12)
        textView.isEditable = editable
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        return scroll
    }

    private func fieldLabel(_ text: String, width: CGFloat?) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        if let width { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return label
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .secondaryLabelColor
        return label
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
        buttonActions.append(proxy)
        return button
    }
}

@MainActor
private final class AssistantButtonAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: NSControl) { handler() }
}
