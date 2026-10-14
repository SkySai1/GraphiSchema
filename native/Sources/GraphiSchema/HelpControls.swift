import AppKit

@MainActor
final class HelpIconButton: NSButton {
    init(_ explanation: String, identifier: String? = nil) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Справка")
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = explanation
        setAccessibilityLabel("Справка: \(explanation)")
        if let identifier { self.identifier = NSUserInterfaceItemIdentifier(identifier) }
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class HelpFieldLabel: NSStackView {
    init(_ title: String, explanation: String, identifier: String? = nil, fontSize: CGFloat = 9) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let help = HelpIconButton(explanation, identifier: identifier)
        super.init(frame: .zero)
        addArrangedSubview(label)
        addArrangedSubview(help)
        orientation = .horizontal
        alignment = .centerY
        spacing = 3
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
