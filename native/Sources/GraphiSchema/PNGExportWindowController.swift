import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private enum PNGExportError: LocalizedError {
    case invalidImage, size, dpi, notReady
    var errorDescription: String? {
        switch self {
        case .invalidImage: "Не удалось подготовить PNG."
        case .notReady: "Дождитесь обновления предпросмотра PNG."
        case .dpi: "DPI должен быть целым числом от 72 до 600."
        case .size: "Размер PNG: 64–16384 px на сторону, не более 64 мегапикселей. Нажмите «Подогнать размер», чтобы вписать изображение в эти пределы."
        }
    }
}

enum PNGExportSizing {
    static let maximumSide = 16384
    static let maximumPixels = 67_108_864
    static func fit(width: Double,height: Double) -> (width: Int,height: Int)? {
        guard width.isFinite,height.isFinite,width>0,height>0 else { return nil }
        let scale = min(1,Double(maximumSide)/width,Double(maximumSide)/height,sqrt(Double(maximumPixels))/sqrt(width)/sqrt(height))
        return (max(64,Int((width*scale).rounded(.down))),max(64,Int((height*scale).rounded(.down))))
    }
    static func samples(width: Int,height: Int,highQuality: Bool) -> Int {
        highQuality && width<=maximumSide/2 && height<=maximumSide/2 && width*height<=maximumPixels/4 ? 2 : 1
    }
}

private enum PNGEncoding {
    static func encode(_ data: Data,width: Int,height: Int,dpi: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),let original = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw PNGExportError.invalidImage }
        let image: CGImage
        if original.width == width,original.height == height {
            // Large 1× exports need no second full-size bitmap just to set DPI.
            image = original
        } else {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PNGExportError.invalidImage }
            context.clear(CGRect(x: 0,y: 0,width: width,height: height)); context.interpolationQuality = .high
            context.draw(original,in: CGRect(x: 0,y: 0,width: width,height: height))
            guard let resized = context.makeImage() else { throw PNGExportError.invalidImage }
            image = resized
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil) else { throw PNGExportError.invalidImage }
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyDPIWidth:dpi,kCGImagePropertyDPIHeight:dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PNGExportError.invalidImage }
        return output as Data
    }
}

@MainActor
final class PNGExportWindowController: NSWindowController, ProjectThemedWindow, NSWindowDelegate, NSTextFieldDelegate {
    let projectModel: AppModel
    private let onSaved: (URL) -> Void
    private let preview = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "Подготовка снимка…")
    private let width = NSTextField(string: "2048"), height = NSTextField(string: "1536"), dpi = NSTextField(string: "144")
    private let quality = NSPopUpButton(), background = NSPopUpButton(), presets = NSPopUpButton()
    private let proportional = NSButton(checkboxWithTitle: "Сохранять пропорции",target: nil,action: nil)
    private let legend = NSButton(checkboxWithTitle: "Условные обозначения",target: nil,action: nil)
    private let groups = NSButton(checkboxWithTitle: "Рамки групп",target: nil,action: nil)
    private let save = NSButton(title: "Сохранить PNG…",target: nil,action: nil)
    private var actions: [ControlAction] = []
    private var optionControls: [NSControl] = []
    private var snapshot: DiagramProject?
    private struct PreparedPNG {
        var project: DiagramProject
        var background: String
        var legend: Bool
        var groups: Bool
        var width: Int
        var height: Int
        var dpi: Int
        var samples: Int
    }
    private var prepared: PreparedPNG?
    private var snapshotTask: Task<Void,Never>?
    private var previewTask: Task<Void,Never>?
    private var saveTask: Task<Void,Never>?
    private var generation = UUID()
    private var ratio = 4.0/3
    private var loading = false
    private var saving = false
    private struct SVGOptions: Equatable { var background: String; var theme: String; var legend: Bool; var groups: Bool }
    private var svgOptions: SVGOptions?

    init(model: AppModel,onSaved: @escaping (URL) -> Void) {
        projectModel = model; self.onSaved = onSaved
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1050,height: 730),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "Экспорт PNG"; window.minSize = NSSize(width: 830,height: 620); window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("png-export-window")
        super.init(window: window); window.delegate = self; build(); AppTheme.configure(window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func reloadSnapshot() {
        guard !saving else { return }
        snapshotTask?.cancel(); previewTask?.cancel(); generation = UUID()
        snapshot = nil; prepared = nil; preview.image = nil; save.isEnabled = false; loading = true
        status.textColor = .secondaryLabelColor; status.stringValue = "Подготовка снимка…"
        let requestedGeneration = generation
        snapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await projectModel.pdfExportSnapshot()
                guard !Task.isCancelled,generation == requestedGeneration else { return }
                self.snapshot = snapshot.diagram; svgOptions = nil; loading = false
                window?.title = "Экспорт PNG — \(snapshot.diagram.project.title)"; scheduleRender()
            } catch {
                guard !Task.isCancelled,generation == requestedGeneration else { return }
                loading = false; showError(error)
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        generation = UUID(); snapshotTask?.cancel(); previewTask?.cancel(); saveTask?.cancel()
        prepared = nil; save.isEnabled = false
    }

    private func bind(_ control: NSControl,_ callback: @escaping () -> Void) {
        let action = ControlAction { _ in callback() }; actions.append(action); control.target = action; control.action = #selector(ControlAction.invoke(_:))
    }
    private func build() {
        guard let content = window?.contentView else { return }
        for (name,control) in [("width",width as NSControl),("height",height),("dpi",dpi),("quality",quality),("background",background),("proportional",proportional),("legend",legend),("groups",groups),("save",save),("status",status)] {
            control.identifier = NSUserInterfaceItemIdentifier("png-export-\(name)")
        }
        let options = NSStackView(); options.orientation = .vertical; options.alignment = .leading; options.spacing = 10
        options.translatesAutoresizingMaskIntoConstraints = false
        func row(_ title: String,_ view: NSView,_ help: String) {
            options.addArrangedSubview(HelpFieldLabel(title,explanation: help,identifier: "png-\(title)")); options.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: options.widthAnchor).isActive = true
        }
        presets.addItems(withTitles: ["Ширина 1024 px","Ширина 1920 px","Ширина 2560 px","Ширина 3840 px","Ширина 7680 px"])
        row("Быстрый размер",presets,"Устанавливает ширину изображения. При сохранении пропорций высота рассчитывается автоматически с учётом легенды.")
        row("Ширина, px",width,"Фактическая ширина PNG в пикселях: 64–16384. Общая площадь ограничена 64 мегапикселями. При сохранении пропорций слишком большой размер автоматически уменьшается.")
        row("Высота, px",height,"Фактическая высота PNG: 64–16384. При отключении пропорций схема вписывается в заданный прямоугольник с полями, без растяжения. «Подогнать размер» уменьшает обе стороны до допустимых пределов.")
        proportional.state = .on
        row("Пропорции",proportional,"Связывает ширину и высоту. При добавлении легенды пропорции пересчитываются для всего изображения.")
        quality.addItems(withTitles: ["Стандартное · 1×","Высокое · адаптивное 2×"]); quality.selectItem(at: 1)
        row("Качество",quality,"PNG сохраняется без потерь. Высокое качество рисует в удвоенном разрешении и уменьшает до заданного размера. Для большого файла автоматически применяется 1×, сохраняя выбранное разрешение и ограничивая расход памяти.")
        background.addItems(withTitles: ["Тема проекта","Белый","Прозрачный","Тёмный"])
        row("Фон",background,"Фон изображения. Белый и тёмный варианты также переключают автоматические цвета для контраста; прозрачный сохраняет цвета темы проекта.")
        row("DPI",dpi,"Плотность печати 72–600 DPI записывается в метаданные PNG. Количество пикселей задаётся отдельно шириной и высотой.")
        legend.state = .on
        row("Легенда",legend,"Добавляет автоматическую или ручную легенду проекта. Сохраняются все строки; размер изображения учитывает таблицу.")
        row("Группировка",groups,"Показывает тонкие рамки постоянных групп. Взаимное положение объектов сохраняется при любом разрешении PNG.")
        let refresh = ActionButton("Обновить из схемы",symbol: "arrow.clockwise") { [weak self] in self?.reloadSnapshot() }
        let fit = ActionButton("Подогнать размер",symbol: "arrow.down.right.and.arrow.up.left") { [weak self] in self?.fitDimensions(); self?.scheduleRender() }
        fit.identifier = NSUserInterfaceItemIdentifier("png-export-fit")
        refresh.identifier = NSUserInterfaceItemIdentifier("png-export-refresh")
        optionControls = [width,height,dpi,presets,quality,background,proportional,legend,groups,fit,refresh]
        options.addArrangedSubview(fit)
        options.addArrangedSubview(refresh)
        [width,height,dpi].forEach { $0.delegate = self }
        bind(presets) { [weak self] in guard let self else { return }; let widths = [1024,1920,2560,3840,7680]; setValue(width,widths[presets.indexOfSelectedItem]); adjustHeight(); scheduleRender() }
        for control in [quality,background,proportional,legend,groups] as [NSControl] { bind(control) { [weak self] in if let self { if control === self.proportional { self.adjustHeight() }; self.scheduleRender() } } }
        preview.imageScaling = .scaleProportionallyUpOrDown; preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.identifier = NSUserInterfaceItemIdentifier("png-export-preview")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        save.isEnabled = false; save.bezelStyle = .rounded; bind(save) { [weak self] in self?.savePNG() }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = PNGOptionsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document; document.addSubview(options)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),options.leadingAnchor.constraint(equalTo: document.leadingAnchor,constant: 8),options.trailingAnchor.constraint(equalTo: document.trailingAnchor,constant: -12),options.topAnchor.constraint(equalTo: document.topAnchor,constant: 8),options.bottomAnchor.constraint(equalTo: document.bottomAnchor,constant: -12)])
        [scroll,preview,status,save].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 12),scroll.topAnchor.constraint(equalTo: content.topAnchor,constant: 12),scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -12),scroll.widthAnchor.constraint(equalToConstant: 275),
            preview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor,constant: 16),preview.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -16),preview.topAnchor.constraint(equalTo: scroll.topAnchor),preview.bottomAnchor.constraint(equalTo: status.topAnchor,constant: -10),
            status.leadingAnchor.constraint(equalTo: preview.leadingAnchor),status.trailingAnchor.constraint(equalTo: preview.trailingAnchor),status.bottomAnchor.constraint(equalTo: save.topAnchor,constant: -10),status.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            save.trailingAnchor.constraint(equalTo: preview.trailingAnchor),save.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -16)
        ])
    }
    func controlTextDidChange(_ notification: Notification) {
        if proportional.state == .on {
            if notification.object as? NSTextField === width { adjustHeight() }
            else if notification.object as? NSTextField === height,let h = Int(input(height)),h>=64 {
                applyFittedSize(width: Double(h)*ratio,height: Double(h))
            }
        }
        scheduleRender()
    }
    private func input(_ field: NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }
    private func setValue(_ field: NSTextField,_ value: Int) {
        let text = String(value)
        field.stringValue = text
        // AppKit keeps live input in a separate field editor. Updating the cell
        // alone can leave the old, invalid size active until focus changes.
        if let editor = field.currentEditor(),editor.string != text { editor.string = text }
    }
    private func adjustHeight() {
        if proportional.state == .on,let w = Int(input(width)),w>=64 { applyFittedSize(width: Double(w),height: Double(w)/ratio) }
    }
    private func applyFittedSize(width w: Double,height h: Double) {
        guard let fitted = PNGExportSizing.fit(width: w,height: h) else { return }
        if Int(input(width)) != fitted.width { setValue(width,fitted.width) }
        if Int(input(height)) != fitted.height { setValue(height,fitted.height) }
    }
    private func fitDimensions() {
        guard let w = Double(input(width)),let h = Double(input(height)) else { return }
        applyFittedSize(width: w,height: h)
    }
    private func scheduleRender() {
        guard !loading,!saving,let snapshot else { return }
        previewTask?.cancel(); generation = UUID(); prepared = nil; save.isEnabled = false; preview.image = nil
        let requestedGeneration = generation
        status.textColor = .secondaryLabelColor; status.stringValue = "Обновление предпросмотра…"
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                var project = snapshot
                let index = background.indexOfSelectedItem
                let bg: String
                switch index { case 1: project.presentation.theme = "light"; bg = "#FFFFFF"
                case 2: bg = "transparent"
                case 3: project.presentation.theme = "dark"; bg = "#21172F"
                default: bg = project.presentation.canvasBackground }
                let options = SVGOptions(background: bg,theme: project.presentation.theme,legend: legend.state == .on,groups: groups.state == .on)
                if svgOptions != options {
                    let svg = try await projectModel.exportSVG(project: project,includeLegend: options.legend,showGroups: options.groups)
                    guard !Task.isCancelled,generation == requestedGeneration else { return }
                    let parser = SVGSizeParser(); let xml = XMLParser(data: svg); xml.delegate = parser
                    guard xml.parse(),let size = parser.size,size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else { throw PNGExportError.invalidImage }
                    let measuredRatio = size.width/size.height
                    guard measuredRatio.isFinite,measuredRatio>0 else { throw PNGExportError.invalidImage }
                    ratio = measuredRatio; svgOptions = options; adjustHeight()
                }
                let samples = quality.indexOfSelectedItem == 1 ? 2 : 1
                let configuration = Result { () throws -> PreparedPNG in
                    guard let w = Int(self.input(self.width)),let h = Int(self.input(self.height)),(64...PNGExportSizing.maximumSide).contains(w),(64...PNGExportSizing.maximumSide).contains(h),w*h<=PNGExportSizing.maximumPixels else { throw PNGExportError.size }
                    guard let resolution = Int(self.input(self.dpi)),(72...600).contains(resolution) else { throw PNGExportError.dpi }
                    return PreparedPNG(project: project,background: bg,legend: options.legend,groups: options.groups,width: w,height: h,dpi: resolution,samples: PNGExportSizing.samples(width: w,height: h,highQuality: samples == 2))
                }
                // Preview stays responsive even while a number is incomplete or the
                // requested full-resolution image exceeds the memory limit.
                let valid = try? configuration.get()
                let w = valid.map { Double($0.width) } ?? 1200
                let h = valid.map { Double($0.height) } ?? 1200/ratio
                let fit = min(1,1200/w,900/h)
                let previewWidth = max(64,Int((w*fit).rounded())),previewHeight = max(64,Int((h*fit).rounded()))
                let data = try await projectModel.exportPNG(project: project,width: previewWidth*samples,height: previewHeight*samples,background: bg,includeLegend: options.legend,showGroups: options.groups)
                guard !Task.isCancelled,generation == requestedGeneration else { return }
                let encoded = try await Task.detached(priority: .userInitiated) { try PNGEncoding.encode(data,width: previewWidth,height: previewHeight,dpi: 144) }.value
                guard !Task.isCancelled,generation == requestedGeneration else { return }
                guard let image = NSImage(data: encoded),image.isValid else { throw PNGExportError.invalidImage }
                preview.image = image
                switch configuration {
                case .success(let settings):
                    prepared = settings; save.isEnabled = true
                    status.stringValue = "\(settings.width) × \(settings.height) px · \(settings.dpi) DPI\nПредпросмотр обновлён. Полный PNG с этими параметрами создаётся при сохранении."
                    if samples == 2,settings.samples == 1 { status.stringValue += " Сглаживание 1× для ограничения памяти; разрешение сохранено." }
                case .failure(let error): showError(error)
                }
            } catch {
                guard !Task.isCancelled,generation == requestedGeneration else { return }
                showError(error)
            }
        }
    }
    private func showError(_ error: Error) {
        status.textColor = .systemRed; status.stringValue = error.localizedDescription
    }
    /// Uses the same immutable project and options as the visible preview.
    func preparedPNGData() async throws -> Data {
        guard let prepared else { throw PNGExportError.notReady }
        return try await encodePNG(prepared)
    }
    private func encodePNG(_ settings: PreparedPNG) async throws -> Data {
        let data = try await projectModel.exportPNG(project: settings.project,width: settings.width*settings.samples,height: settings.height*settings.samples,background: settings.background,includeLegend: settings.legend,showGroups: settings.groups)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try PNGEncoding.encode(data,width: settings.width,height: settings.height,dpi: settings.dpi)
        }.value
    }
    private func savePNG() {
        guard let prepared,!saving,let window else { return }
        saving = true; save.isEnabled = false; optionControls.forEach { $0.isEnabled = false }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "graphischema-diagram.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK,let url = panel.url else { finishSaving(); return }
            status.textColor = .secondaryLabelColor; status.stringValue = "Сохранение PNG в полном разрешении…"
            saveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { finishSaving() }
                do {
                    let data = try await encodePNG(prepared)
                    try Task.checkCancellation()
                    try data.write(to: url,options: .atomic); onSaved(url)
                    status.stringValue = "PNG сохранён · \(prepared.width) × \(prepared.height) px · \(ByteCountFormatter.string(fromByteCount: Int64(data.count),countStyle: .file))"
                } catch { if !Task.isCancelled { showError(error) } }
            }
        }
    }
    private func finishSaving() {
        saving = false; optionControls.forEach { $0.isEnabled = true }; save.isEnabled = prepared != nil
    }
}

private final class SVGSizeParser: NSObject, XMLParserDelegate {
    var size: NSSize?
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI: String?,qualifiedName qName: String?,attributes: [String:String]) {
        guard elementName == "svg",size == nil,let viewBox = attributes["viewBox"] else { return }
        let values = viewBox.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        if values.count == 4 { size = NSSize(width: values[2],height: values[3]) }
    }
}

private final class PNGOptionsDocumentView: NSView { override var isFlipped: Bool { true } }
