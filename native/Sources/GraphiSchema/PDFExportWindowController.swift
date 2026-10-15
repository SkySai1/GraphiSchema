import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
private final class PDFOptionsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PDFExportWindowController: NSWindowController, NSWindowDelegate, ProjectThemedWindow {
    var projectModel: AppModel { model }
    private let model: AppModel
    private let onSaved: (URL) -> Void
    private let preview = PDFView()
    private let status = NSTextField(wrappingLabelWithString: "Подготовка снимка диаграммы…")
    private let navigation = NSTextField(labelWithString: "")
    private let exportButton = NSButton(title: "Сохранить PDF…", target: nil, action: nil)
    private var settings = DiagramPDFSettings()
    private var snapshot: ProjectPreviewResponse?
    private var result: DiagramPDFRenderResult?
    private var snapshotTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var loadingSnapshot = false
    private var autoFit = true
    private var bindings: [() -> Void] = []
    private var actions: [ControlAction] = []
    private var invalidNumbers: Set<ObjectIdentifier> = []
    private var stack = NSStackView()

    init(model: AppModel, onSaved: @escaping (URL) -> Void) {
        self.model = model; self.onSaved = onSaved
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1240,height: 830),
                              styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "Экспорт PDF — \(model.diagram?.project.title ?? "GraphiSchema")"
        window.identifier = NSUserInterfaceItemIdentifier("pdf-export-window")
        window.minSize = NSSize(width: 980,height: 640); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        build(); AppTheme.configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func reloadSnapshot(relayout: Bool = false) {
        snapshotTask?.cancel(); renderTask?.cancel()
        loadingSnapshot = true; snapshot = nil; result = nil; exportButton.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = relayout ? "Автокомпоновка экспортной копии…" : "Получение актуальной геометрии…"
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await model.pdfExportSnapshot(relayout: relayout)
                guard !Task.isCancelled else { return }
                self.snapshot = snapshot; settings.branchName = model.branchName; loadingSnapshot = false
                window?.title = "Экспорт PDF — \(snapshot.diagram.project.title)"
                scheduleRender()
            } catch {
                guard !Task.isCancelled else { return }
                loadingSnapshot = false; showError(error)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        snapshotTask?.cancel(); renderTask?.cancel()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalToConstant: 326).isActive = true
        addTab("Страница",to: tabs) {
            self.addSection("БУМАГА И КОМПОЗИЦИЯ")
            self.addPopup("Формат",id: "pdf-page-format",choices: DiagramPDFSettings.formats,key: \.format,
                          help: "A5–A2, Letter или свой размер в миллиметрах. «По размеру схемы» создаёт лист по габаритам сцены при масштабе около 1:1; предел стороны — 200 дюймов.")
            self.addCheckbox("Альбомная ориентация",key: \.landscape,help: "Меняет местами стороны стандартного листа. Для собственного размера задайте ширину и высоту ниже.")
            self.addNumber("Свой лист: ширина, мм",key: \.customWidthMM,range: 100...2000,help: "Ширина листа при формате «Свой размер». Другие форматы используют стандартные размеры.")
            self.addNumber("Свой лист: высота, мм",key: \.customHeightMM,range: 100...2000,help: "Высота листа при формате «Свой размер».")
            self.addNumber("Поля, мм",key: \.marginMM,range: 3...40,help: "Свободная полоса по краям бумаги. Не обрезает фигуры: схема заново вписывается в оставшуюся область.")
            self.addNumber("Заполнение области, %",key: \.occupancy,range: 0.4...1,multiplier: 100,help: "Общий размер диаграммы в доступной области. Все фигуры, подписи, линии и наконечники масштабируются пропорционально. 100% занимает всю область без обрезки.")
            self.addCheckbox("Заголовок проекта",key: \.includeTitle,help: "Резервирует отдельную строку над диаграммой; заголовок не накладывается на схему.")
            self.addCheckbox("Номера страниц",key: \.pageNumbers,help: "Показывает номер страницы независимо от водяного знака приложения.")
            self.addCheckbox("Имя ветки",key: \.includeBranch,help: "Добавляет имя текущей ветки под заголовком проекта, в отдельной строке.")
            self.addCheckbox("Watermark GraphiSchema",key: \.watermark,help: "Показывает название приложения в нижней полосе. Отключается независимо от нумерации страниц.")
            self.addSection("УСЛОВНЫЕ ОБОЗНАЧЕНИЯ")
            self.addCheckbox("Добавить условные обозначения",id: "pdf-include-legend",key: \.includeLegend,
                             help: "Формирует легенду из фигур и стилей связей экспортной копии. Длинная легенда продолжается на следующих страницах без потери строк.")
            self.addCheckbox("Легенда на отдельной странице",key: \.legendOnSeparatePage,
                             help: "Освобождает всю первую страницу под схему. При выключении для легенды резервируется колонка справа; её продолжение печатается отдельно.")
        }
        addTab("Стиль",to: tabs) {
            self.addCheckbox("Показывать рамки групп",key: \.showGroups,help: "Рисует тонкую пунктирную рамку вокруг каждой постоянной группы. Группы не превращаются в контейнеры.")
            self.addSection("ТОЛЩИНА И НАКОНЕЧНИКИ")
            self.addNumber("Границы фигур, %",key: \.nodeStroke,range: 0.25...3,multiplier: 100,help: "Умножает толщину внешних и внутренних линий фигур только в PDF. Интервалы штрихов и точек изменяются вместе с толщиной.")
            self.addNumber("Границы контейнеров, %",key: \.containerStroke,range: 0.25...3,multiplier: 100,help: "Множитель толщины рамок контейнеров в экспортной копии.")
            self.addNumber("Линии связей, %",key: \.edgeStroke,range: 0.25...3,multiplier: 100,help: "Множитель толщины связей. Общий масштаб страницы затем применяется одинаково ко всем частям схемы.")
            self.addNumber("Наконечники, %",key: \.arrowSize,range: 0.5...2.5,multiplier: 100,help: "Регулирует размер наконечников относительно линии, сохраняя стык с её хвостом. На очень коротком сегменте размер ограничивается доступным местом.")
            self.addSection("ПОДПИСИ")
            self.addNumber("Текст фигур, %",key: \.nodeText,range: 0.5...2.5,multiplier: 100,help: "Изменяет базовый размер подписей фигур. Автоподгонка размеров и раздвижение объектов помогают разместить увеличенный текст без обрезки.")
            self.addNumber("Текст связей, %",key: \.edgeText,range: 0.5...2.5,multiplier: 100,help: "Изменяет размер подписей связей. Итоговый минимальный размер после вписывания в лист показан под предпросмотром.")
            self.addNumber("Заголовки контейнеров, pt",key: \.containerFontSize,range: 6...24,help: "Базовый размер заголовков контейнеров в экспортной сцене. Для них резервируется отдельная полоса, которая увеличивается вместе со шрифтом.")
            self.addPopup("Фон подписей связей",id: "pdf-label-background",choices: [("opaque","Белая плашка"),("transparent","Прозрачный"),("project","Как в проекте")],key: \.labelBackground,
                          help: "Белая плашка отделяет текст от проходящей за ним линии. Прозрачный фон сохраняет видимость подложки; режим проекта использует индивидуальные настройки связей.")
            self.addCheckbox("Повышать контраст текста",key: \.contrastText,help: "Подбирает светлый или тёмный текст при недостаточном контрасте с экспортным фоном. Явные цвета с достаточным контрастом сохраняются. PDF всегда светлый.")
        }
        addTab("Размещение",to: tabs) {
            self.addSection("ЧИТАЕМОСТЬ")
            self.addCheckbox("Сохранять группы",key: \.preserveGroups,help: "При увеличении интервалов и устранении наложений перемещает группу целиком, сохраняя взаимное положение её объектов. При выключении объекты экспортной копии можно раздвигать независимо.")
            self.addCheckbox("Раздвигать пересекающиеся объекты",key: \.avoidOverlaps,help: "Устраняет пересечения соседних фигур и групп в экспортной копии. Контейнеры перемещаются вместе с содержимым; вложенность сохраняется. Неразрешённые пересечения отмечаются под предпросмотром.")
            self.addNumber("Интервалы между центрами, %",key: \.spacing,range: 1...2.5,multiplier: 100,help: "Раздвигает центры объектов, сохраняя размеры фигур. Рамки контейнеров и маршруты пересчитываются в экспортной копии.")
            self.addNumber("Минимальный промежуток, pt",key: \.gap,range: 0...72,help: "Желаемый промежуток между соседними фигурами и контейнерами до общего масштабирования страницы. Используется при включённом раздвижении.")
            self.addCheckbox("Подгонять фигуры под текст",key: \.fitNodeLabels,help: "При нехватке места увеличивает обе стороны фигуры одним коэффициентом. Пропорции фигур и иконок сохраняются.")
            self.addCheckbox("Переносить длинные подписи фигур",key: \.wrapNodeLabels,help: "Включает перенос слов в экспортной копии. Ручные переводы строк и выравнивание сохраняются.")
            self.addCheckbox("Размещать подписи связей свободно",key: \.placeEdgeLabels,help: "Ищет место для подписи вдоль маршрута и рядом с ним, избегая фигур, заголовков контейнеров и других подписей. Для удалённых подписей добавляет тонкую выноску.")
            self.addSection("ЭКСПОРТНАЯ КОПИЯ")
            self.stack.addArrangedSubview(ActionButton("Обновить из текущей схемы",symbol: "arrow.clockwise") { [weak self] in self?.reloadSnapshot() })
            self.stack.addArrangedSubview(ActionButton("Автокомпоновка копии",symbol: "rectangle.3.group") { [weak self] in self?.reloadSnapshot(relayout: true) })
            let note = NSTextField(wrappingLabelWithString: "Автокомпоновка использует выбранный движок Graphviz и сбрасывает ручные маршруты только в экспортной копии. Обновление возвращает расположение исходной схемы. Настройки PDF не создают версии проекта.")
            note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
            self.stack.addArrangedSubview(note)
        }

        let preset = NSPopUpButton()
        preset.addItems(withTitles: ["Сбалансированный","Крупнее и свободнее","Компактный","Без коррекции размещения"])
        let presetAction = ControlAction { [weak self] sender in
            guard let self, let control = sender as? NSPopUpButton else { return }
            settings = DiagramPDFSettings(); settings.branchName = model.branchName
            switch control.indexOfSelectedItem {
            case 1: settings.format = "a3"; settings.nodeText = 1.15; settings.edgeText = 1.15; settings.gap = 18; settings.legendOnSeparatePage = true
            case 2: settings.nodeText = 0.85; settings.edgeText = 0.85; settings.gap = 6; settings.nodeStroke = 0.8; settings.edgeStroke = 0.8
            case 3: settings.avoidOverlaps = false; settings.fitNodeLabels = false; settings.wrapNodeLabels = false; settings.placeEdgeLabels = false; settings.contrastText = false; settings.labelBackground = "project"
            default: break
            }
            invalidNumbers.removeAll(); bindings.forEach { $0() }; scheduleRender()
        }
        preset.target = presetAction; preset.action = #selector(ControlAction.invoke(_:)); actions.append(presetAction)
        let presetLabel = HelpFieldLabel("Пресет",explanation: "Загружает согласованный набор параметров. Любое поле затем можно настроить отдельно; исходная схема остаётся без изменений.",identifier: "pdf-preset-help")
        let presetRow = NSStackView(views: [presetLabel,preset]); presetRow.spacing = 8
        let controls = NSStackView(views: [presetRow,tabs]); controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 10
        controls.widthAnchor.constraint(equalToConstant: 326).isActive = true
        presetRow.widthAnchor.constraint(equalTo: tabs.widthAnchor).isActive = true

        preview.identifier = NSUserInterfaceItemIdentifier("pdf-preview")
        preview.autoScales = true; preview.displayMode = .singlePageContinuous; preview.displayDirection = .vertical
        preview.backgroundColor = NSColor(hex: "#626570")
        let fit = ActionButton("Вписать",symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.fitPreview() }
        let actual = ActionButton("100%") { [weak self] in self?.autoFit = false; self?.preview.autoScales = false; self?.preview.scaleFactor = 1 }
        let minus = ActionButton("−") { [weak self] in self?.autoFit = false; self?.preview.autoScales = false; self?.preview.zoomOut(nil) }
        let plus = ActionButton("+") { [weak self] in self?.autoFit = false; self?.preview.autoScales = false; self?.preview.zoomIn(nil) }
        let previous = ActionButton("‹") { [weak self] in self?.preview.goToPreviousPage(nil) }
        let next = ActionButton("›") { [weak self] in self?.preview.goToNextPage(nil) }
        navigation.font = .monospacedSystemFont(ofSize: 10,weight: .regular)
        let tools = NSStackView(views: [fit,actual,minus,plus,NSView(),previous,navigation,next]); tools.spacing = 7; tools.alignment = .centerY
        let paper = NSView()
        [tools,preview].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; paper.addSubview($0) }
        NSLayoutConstraint.activate([
            tools.topAnchor.constraint(equalTo: paper.topAnchor), tools.leadingAnchor.constraint(equalTo: paper.leadingAnchor),tools.trailingAnchor.constraint(equalTo: paper.trailingAnchor),tools.heightAnchor.constraint(equalToConstant: 30),
            preview.topAnchor.constraint(equalTo: tools.bottomAnchor,constant: 8),preview.leadingAnchor.constraint(equalTo: paper.leadingAnchor),preview.trailingAnchor.constraint(equalTo: paper.trailingAnchor),preview.bottomAnchor.constraint(equalTo: paper.bottomAnchor),
        ])
        status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 4
        exportButton.target = self; exportButton.action = #selector(savePDF); exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"; exportButton.isEnabled = false
        exportButton.identifier = NSUserInterfaceItemIdentifier("pdf-export-save")
        let close = ActionButton("Закрыть") { [weak self] in self?.close() }; close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [close,exportButton]); buttons.spacing = 8
        [controls,paper,status,buttons].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 14),controls.topAnchor.constraint(equalTo: content.topAnchor,constant: 14),controls.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -12),
            paper.leadingAnchor.constraint(equalTo: controls.trailingAnchor,constant: 14),paper.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -14),paper.topAnchor.constraint(equalTo: content.topAnchor,constant: 14),paper.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -12),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 18),status.trailingAnchor.constraint(equalTo: buttons.leadingAnchor,constant: -14),status.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -16),status.heightAnchor.constraint(equalToConstant: 62),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -16),buttons.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(self,selector: #selector(updateNavigation),name: .PDFViewScaleChanged,object: preview)
        NotificationCenter.default.addObserver(self,selector: #selector(updateNavigation),name: .PDFViewPageChanged,object: preview)
        bindings.forEach { $0() }
    }

    private func addTab(_ title: String,to tabs: NSTabView,build: () -> Void) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = PDFOptionsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,constant: 12),stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor,constant: 14),stack.bottomAnchor.constraint(equalTo: document.bottomAnchor,constant: -14),
        ])
        build()
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = scroll; tabs.addTabViewItem(item)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
    }

    private func addSection(_ title: String) {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 10,weight: .bold); label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
    }

    private func addPopup(_ title: String,id: String,choices: [(String,String)],key: WritableKeyPath<DiagramPDFSettings,String>,help: String) {
        let popup = NSPopUpButton(); popup.identifier = NSUserInterfaceItemIdentifier(id)
        for (value,title) in choices { popup.addItem(withTitle: title); popup.lastItem?.representedObject = value }
        let action = ControlAction { [weak self] sender in
            guard let self, let value = (sender as? NSPopUpButton)?.selectedItem?.representedObject as? String else { return }
            settings[keyPath: key] = value; scheduleRender()
        }
        popup.target = action; popup.action = #selector(ControlAction.invoke(_:)); actions.append(action)
        bindings.append { [weak self,weak popup] in
            guard let self,let popup,let item = popup.itemArray.first(where: { ($0.representedObject as? String) == self.settings[keyPath: key] }) else { return }
            popup.select(item)
        }
        let row = NSStackView(views: [HelpFieldLabel(title,explanation: help,identifier: "\(id)-help"),popup])
        row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
        popup.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true; stack.addArrangedSubview(row)
    }

    private func addCheckbox(_ title: String,id: String? = nil,key: WritableKeyPath<DiagramPDFSettings,Bool>,help: String) {
        let button = NSButton(checkboxWithTitle: title,target: nil,action: nil); button.font = .systemFont(ofSize: 11)
        button.identifier = NSUserInterfaceItemIdentifier(id ?? "pdf-\(key)"); button.toolTip = help
        button.setContentCompressionResistancePriority(.defaultLow,for: .horizontal)
        let action = ControlAction { [weak self] sender in
            guard let self,let button = sender as? NSButton else { return }
            settings[keyPath: key] = button.state == .on; scheduleRender()
        }
        button.target = action; button.action = #selector(ControlAction.invoke(_:)); actions.append(action)
        bindings.append { [weak self,weak button] in guard let self else { return }; button?.state = settings[keyPath: key] ? .on : .off }
        let row = NSStackView(views: [button,HelpIconButton(help)]); row.alignment = .centerY; row.spacing = 3
        stack.addArrangedSubview(row)
    }

    private func addNumber(_ title: String,key: WritableKeyPath<DiagramPDFSettings,Double>,range: ClosedRange<Double>,multiplier: Double = 1,help: String) {
        let explanation = help+String(format: " Допустимые значения: %.0f–%.0f.",range.lowerBound*multiplier,range.upperBound*multiplier)
        let slider = NSSlider(value: settings[keyPath: key],minValue: range.lowerBound,maxValue: range.upperBound,target: nil,action: nil)
        slider.isContinuous = true
        let field = NSTextField(); field.alignment = .right; field.font = .monospacedSystemFont(ofSize: 11,weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 57).isActive = true
        field.identifier = NSUserInterfaceItemIdentifier("pdf-field-\(title)"); field.toolTip = explanation
        let apply: (Double) -> Void = { [weak self] value in
            guard let self,value.isFinite,range.contains(value),settings[keyPath: key] != value else { return }
            settings[keyPath: key] = value; scheduleRender()
        }
        let sliderAction = ControlAction { [weak self] sender in
            guard let control = sender as? NSSlider else { return }
            let value = (control.doubleValue*multiplier).rounded()/multiplier
            field.stringValue = String(format: "%.0f",value*multiplier); self?.setValidity(field,valid: true); apply(value)
        }
        slider.target = sliderAction; slider.action = #selector(ControlAction.invoke(_:)); actions.append(sliderAction)
        let fieldAction = ControlAction { [weak self] sender in
            guard let control = sender as? NSTextField else { return }
            guard let value = Double(control.stringValue.replacingOccurrences(of: ",",with: ".")),value.isFinite else {
                self?.setValidity(control,valid: false); return
            }
            let normalized = value/multiplier
            self?.setValidity(control,valid: range.contains(normalized))
            if range.contains(normalized) { slider.doubleValue = normalized; apply(normalized) }
        }
        fieldAction.onTextChange = { [weak fieldAction] field in fieldAction?.invoke(field) }
        field.delegate = fieldAction; field.target = fieldAction; field.action = #selector(ControlAction.invoke(_:)); actions.append(fieldAction)
        bindings.append { [weak self,weak field,weak slider] in guard let self else { return }; field?.textColor = .labelColor; field?.stringValue = String(format: "%.0f",settings[keyPath: key]*multiplier); slider?.doubleValue = settings[keyPath: key] }
        let controls = NSStackView(views: [slider,field]); controls.spacing = 6
        let row = NSStackView(views: [HelpFieldLabel(title,explanation: explanation),controls]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 4
        controls.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true; stack.addArrangedSubview(row)
    }

    private func setValidity(_ field: NSTextField,valid: Bool) {
        if valid { invalidNumbers.remove(ObjectIdentifier(field)) } else { invalidNumbers.insert(ObjectIdentifier(field)) }
        field.textColor = valid ? .labelColor : .systemRed
        exportButton.isEnabled = invalidNumbers.isEmpty && result != nil && !loadingSnapshot
    }

    private func scheduleRender() {
        guard let snapshot,!loadingSnapshot else { return }
        renderTask?.cancel(); result = nil; exportButton.isEnabled = false
        status.textColor = .secondaryLabelColor; status.stringValue = "Обновление предпросмотра…"
        let requested = settings
        renderTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self,!Task.isCancelled else { return }
            do {
                let result = try DiagramPDFRenderer.render(project: snapshot.diagram,layout: snapshot.layout,settings: requested)
                guard !Task.isCancelled,settings == requested,let document = PDFDocument(data: result.data) else { return }
                let zoom = preview.scaleFactor
                let pageIndex = preview.currentPage.flatMap { self.preview.document?.index(for: $0) } ?? 0
                self.result = result; preview.document = document
                if let page = document.page(at: min(pageIndex,document.pageCount-1)) { preview.go(to: page) }
                if autoFit { fitPreview() } else { preview.autoScales = false; preview.scaleFactor = zoom }
                exportButton.isEnabled = invalidNumbers.isEmpty; renderTask = nil
                var lines = [String(format: "%.0f × %.0f мм · %d стр. · масштаб схемы %.0f%% · мин. текст схемы %.1f pt",result.pageSize.width*25.4/72,result.pageSize.height*25.4/72,result.pageCount,result.diagramScale*100,result.minimumFontSize)]
                lines.append("Раздвинуто объектов: \(result.movedNodes) · размещено подписей: \(result.movedLabels). Экспортная копия; проект не изменён.")
                if result.remainingOverlaps > 0 { lines.append("Остались пересечения: \(result.remainingOverlaps). Увеличьте интервалы или перекомпонуйте копию.") }
                if result.minimumFontSize < 5.5 { lines.append("Текст мелкий для печати: выберите больший лист, легенду отдельно или формат по размеру схемы.") }
                status.stringValue = lines.joined(separator: "\n")
                status.textColor = result.remainingOverlaps > 0 || result.minimumFontSize < 5.5 ? .systemOrange : .secondaryLabelColor
                updateNavigation()
            } catch { showError(error) }
        }
    }

    private func showError(_ error: Error) {
        result = nil; exportButton.isEnabled = false; status.textColor = .systemRed
        status.stringValue = error.localizedDescription
    }
    private func fitPreview() { autoFit = true; preview.autoScales = true; preview.scaleFactor = preview.scaleFactorForSizeToFit; updateNavigation() }
    @objc private func updateNavigation() {
        let page = preview.currentPage.flatMap { preview.document?.index(for: $0) }.map { $0+1 } ?? 0
        navigation.stringValue = "\(page) / \(preview.document?.pageCount ?? 0) · \(Int(preview.scaleFactor*100))%"
    }
    @objc private func savePDF() {
        guard let result,let window,invalidNumbers.isEmpty else { return }
        let data = result.data
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        let title = snapshot?.diagram.project.title ?? "graphischema-diagram"
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/",with: "-").replacingOccurrences(of: ":",with: "-" )).pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,let url = panel.url,let self else { return }
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try data.write(to: url,options: .atomic); onSaved(url)
                status.stringValue = "Сохранён PDF из предпросмотра: \(url.lastPathComponent)"; status.textColor = .secondaryLabelColor
            } catch { showError(error) }
        }
    }
}
