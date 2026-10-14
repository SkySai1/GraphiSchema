import AppKit

enum DiagramColorParameter: String, CaseIterable {
    case fill, stroke, text

    var title: String {
        switch self {
        case .fill: "Фон"
        case .stroke: "Граница"
        case .text: "Текст"
        }
    }

    var shortcut: String {
        switch self {
        case .fill: "f"
        case .stroke: "b"
        case .text: "t"
        }
    }
}

struct DiagramColorSelection {
    var projectID: String
    var selection: DiagramSelection
    var caption: String
    var color: String?
    var isMixed = false
    var isEditable = false
}

@MainActor
final class ColorEditorWindowController: NSWindowController {
    let parameter: DiagramColorParameter
    private let model: AppModel
    private let targetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hexField = NSTextField(string: "")
    private let preview = ColorPreviewView()
    private let saturationView = SaturationBrightnessView()
    private let hueSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var channelSliders: [NSSlider] = []
    private var channelFields: [NSTextField] = []
    private var editableControls: [NSControl] = []
    private var boundSelection: DiagramSelection?
    private var boundProjectID: String?
    private var currentColor = NSColor.white
    private var hue: CGFloat = 0
    private var isUpdating = false

    init(parameter: DiagramColorParameter, model: AppModel) {
        self.parameter = parameter
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 540),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isFloatingPanel = true
        panel.title = "Цвет · \(parameter.title)"
        panel.identifier = NSUserInterfaceItemIdentifier("color-window-\(parameter.rawValue)")
        super.init(window: panel)
        build()
        AppTheme.configure(panel)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh() {
        let state = model.colorSelection(for: parameter)
        let selectionChanged = boundSelection != state.selection || boundProjectID != state.projectID
        isUpdating = true
        defer { isUpdating = false }
        if selectionChanged { window?.makeFirstResponder(nil) }
        boundSelection = state.selection
        boundProjectID = state.projectID
        window?.title = "Цвет · \(parameter.title) — \(state.caption)"
        targetLabel.stringValue = state.caption
        targetLabel.toolTip = state.caption
        statusLabel.stringValue = state.color == nil ? "Параметр не применяется к выбранному объекту."
            : !state.isEditable ? "Редактирование временно недоступно."
            : state.isMixed ? "Разные цвета. Изменение применится ко всем выбранным фигурам."
            : "Изменения применяются сразу к текущему выделению."
        for control in editableControls { control.isEnabled = state.isEditable }
        saturationView.isEditable = state.isEditable
        if let value = state.color {
            let color = NSColor(hex: value)
            if selectionChanged || color.hexRGBA != currentColor.hexRGBA {
                currentColor = color
                syncControls(updateHue: true)
            }
        } else if selectionChanged {
            currentColor = .clear
            syncControls(updateHue: true)
            hexField.stringValue = "—"
        }
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.widthAnchor.constraint(equalToConstant: 328).isActive = true
        root.addArrangedSubview(targetLabel)
        root.addArrangedSubview(HelpFieldLabel("Насыщенность и яркость", explanation: "По горизонтали меняется насыщенность, по вертикали — яркость. Цвет применяется к текущему выделению; прозрачность сохраняется.", identifier: "color-\(parameter.rawValue)-palette-help"))
        saturationView.widthAnchor.constraint(equalToConstant: 328).isActive = true
        saturationView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        saturationView.onChange = { [weak self] saturation, brightness in
            guard let self else { return }
            self.commit(NSColor(hue: self.hue, saturation: saturation, brightness: brightness,
                                alpha: self.currentColor.alphaComponent), updateHue: false)
        }
        root.addArrangedSubview(saturationView)
        hueSlider.target = self
        hueSlider.action = #selector(hueChanged(_:))
        hueSlider.isContinuous = true
        hueSlider.widthAnchor.constraint(equalToConstant: 328).isActive = true
        root.addArrangedSubview(HelpFieldLabel("Оттенок", explanation: "Выбирает основной цвет палитры. Насыщенность, яркость и прозрачность сохраняются.", identifier: "color-\(parameter.rawValue)-hue-help"))
        root.addArrangedSubview(hueSlider)
        editableControls.append(hueSlider)

        let swatches = NSStackView()
        swatches.orientation = .horizontal
        swatches.spacing = 6
        for value in ["#FFFFFF", "#000000", "#7C3AED", "#2563EB", "#16A34A", "#F59E0B", "#EF4444", "#64748B"] {
            let button = NSButton(title: "", target: self, action: #selector(presetChosen(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(value)
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(hex: value).cgColor
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.layer?.borderWidth = 1
            button.layer?.cornerRadius = 4
            button.toolTip = "Выбрать \(value), сохранив прозрачность"
            button.widthAnchor.constraint(equalToConstant: 35).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            swatches.addArrangedSubview(button)
            editableControls.append(button)
        }
        root.addArrangedSubview(swatches)

        for (index, label) in ["Красный", "Зелёный", "Синий", "Непрозрачность, %"].enumerated() {
            let maximum = index == 3 ? 100.0 : 255.0
            let slider = NSSlider(value: maximum, minValue: 0, maxValue: maximum, target: self, action: #selector(channelChanged(_:)))
            slider.tag = index
            slider.isContinuous = true
            let field = NSTextField(string: "")
            field.tag = index
            field.target = self
            field.action = #selector(channelFieldChanged(_:))
            field.alignment = .right
            field.identifier = NSUserInterfaceItemIdentifier("color-\(parameter.rawValue)-channel-\(index)")
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let help = index == 3 ? "0% — полностью прозрачно, 100% — непрозрачно. Alpha-канал сохраняется в JSON, DOT и экспорте."
                : "Значение канала RGB от 0 до 255. Обновляет цвет текущего объекта сразу."
            let heading = HelpFieldLabel(label, explanation: help, identifier: "color-\(parameter.rawValue)-channel-help-\(index)")
            let row = NSStackView(views: [heading, slider, field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            heading.widthAnchor.constraint(equalToConstant: 102).isActive = true
            root.addArrangedSubview(row)
            channelSliders.append(slider)
            channelFields.append(field)
            editableControls += [slider, field]
        }
        hexField.target = self
        hexField.action = #selector(hexChanged(_:))
        hexField.identifier = NSUserInterfaceItemIdentifier("color-\(parameter.rawValue)-hex")
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hexField.widthAnchor.constraint(equalToConstant: 205).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 42).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let hexLabel = HelpFieldLabel("HEX", explanation: "#RRGGBB задаёт непрозрачный цвет; #RRGGBBAA содержит прозрачность в последних двух символах. Нажмите Enter для применения.", identifier: "color-\(parameter.rawValue)-hex-help")
        let hexRow = NSStackView(views: [hexLabel, hexField, preview])
        hexRow.orientation = .horizontal
        hexRow.spacing = 12
        hexRow.alignment = .centerY
        root.addArrangedSubview(hexRow)
        editableControls.append(hexField)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.widthAnchor.constraint(equalToConstant: 328).isActive = true
        root.addArrangedSubview(statusLabel)
        window?.contentView = NSView()
        guard let content = window?.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 360, height: max(510, root.fittingSize.height)))
    }

    private func syncControls(updateHue: Bool) {
        let color = currentColor.usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&h, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if updateHue { hue = h }
        saturationView.hue = hue
        saturationView.saturation = saturation
        saturationView.brightness = brightness
        saturationView.needsDisplay = true
        hueSlider.doubleValue = Double(hue)
        let values = [color.redComponent * 255, color.greenComponent * 255, color.blueComponent * 255, alpha * 100]
        for index in values.indices {
            channelSliders[index].doubleValue = Double(values[index])
            channelFields[index].stringValue = String(format: index == 3 ? "%.1f" : "%.0f", Double(values[index]))
        }
        hexField.stringValue = color.hexRGBA
        preview.color = color
    }

    private func commit(_ color: NSColor, updateHue: Bool = true) {
        guard !isUpdating, model.colorSelection(for: parameter).isEditable else { return }
        currentColor = color.usingColorSpace(.sRGB) ?? color
        syncControls(updateHue: updateHue)
        model.setSelectionColor(parameter, value: currentColor.hexRGBA)
    }

    @objc private func hueChanged(_ sender: NSSlider) {
        hue = CGFloat(sender.doubleValue)
        commit(NSColor(hue: hue, saturation: saturationView.saturation, brightness: saturationView.brightness,
                       alpha: currentColor.alphaComponent), updateHue: false)
    }

    @objc private func channelChanged(_ sender: NSSlider) {
        let values = channelSliders.map(\.doubleValue)
        commit(NSColor(srgbRed: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: values[3] / 100))
    }

    @objc private func channelFieldChanged(_ sender: NSTextField) {
        guard !isUpdating, let value = Double(sender.stringValue.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, (0...channelSliders[sender.tag].maxValue).contains(value) else {
            statusLabel.stringValue = "Введите значение в допустимом диапазоне."
            return
        }
        channelSliders[sender.tag].doubleValue = value
        channelChanged(channelSliders[sender.tag])
    }

    @objc private func hexChanged(_ sender: NSTextField) {
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !isUpdating, value.range(of: "^#[0-9A-F]{6}([0-9A-F]{2})?$", options: .regularExpression) != nil else {
            statusLabel.stringValue = "Формат: #RRGGBB или #RRGGBBAA."
            return
        }
        commit(NSColor(hex: value))
    }

    @objc private func presetChosen(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        commit(NSColor(hex: value).withAlphaComponent(currentColor.alphaComponent))
    }
}

@MainActor
private final class SaturationBrightnessView: NSView {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 1
    var isEditable = true { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: .white, ending: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))?.draw(in: bounds, angle: 0)
        NSGradient(starting: .black, ending: .black.withAlphaComponent(0))?.draw(in: bounds, angle: 90)
        let center = NSPoint(x: min(bounds.maxX - 5, max(5, saturation * bounds.width)),
                             y: min(bounds.maxY - 5, max(5, brightness * bounds.height)))
        let marker = NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        NSColor.black.setStroke(); marker.lineWidth = 3; marker.stroke()
        NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()
        if !isEditable { NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill(); bounds.fill() }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(self)
        change(with: event)
    }
    override func mouseDragged(with event: NSEvent) { change(with: event) }
    private func change(with event: NSEvent) {
        guard isEditable else { return }
        let point = convert(event.locationInWindow, from: nil)
        onChange?(min(1, max(0, point.x / max(1, bounds.width))), min(1, max(0, point.y / max(1, bounds.height))))
    }
}

@MainActor
private final class ColorPreviewView: NSView {
    var color = NSColor.white { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        for y in stride(from: CGFloat(0), to: bounds.height, by: 6) {
            for x in stride(from: CGFloat(0), to: bounds.width, by: 6) {
                ((Int(x / 6) + Int(y / 6)).isMultiple(of: 2) ? NSColor.white : NSColor.lightGray).setFill()
                NSRect(x: x, y: y, width: 6, height: 6).fill()
            }
        }
        color.setFill(); bounds.fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
