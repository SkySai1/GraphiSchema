import AppKit

@MainActor
final class VersionPreviewView: NSView {
    var onRetry: (() -> Void)?
    var inverseTrackpad: Bool {
        get { canvas.inverseTrackpad }
        set { canvas.inverseTrackpad = newValue }
    }

    private let canvas = DiagramCanvasView()
    private let titleLabel = NSTextField(labelWithString: "Предпросмотр версии")
    private let detailLabel = NSTextField(labelWithString: "")
    private let placeholderTitle = NSTextField(labelWithString: "Выберите версию")
    private let placeholderDetail = NSTextField(wrappingLabelWithString: "Её диаграмма появится здесь.")
    private let progress = NSProgressIndicator()
    private let placeholder = NSStackView()
    private let retryButton = NSButton(title: "Повторить загрузку", target: nil, action: nil)
    private var navigationButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildInterface()
        showPlaceholder("Выберите версию", detail: "Её диаграмма появится здесь. Текущий проект останется без изменений.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ preview: VersionPreview, version: ProjectVersion) {
        titleLabel.stringValue = "Версия №\(version.id) — \(version.title)"
        titleLabel.toolTip = titleLabel.stringValue
        let project = preview.diagram
        detailLabel.stringValue = "Объектов: \(project.nodes.count) · Контейнеров: \(project.containers.count) · Связей: \(project.edges.count)\n\(preview.layout.engine) · \(project.diagram.direction) · Только просмотр"
        placeholder.isHidden = true
        progress.stopAnimation(nil)
        canvas.isHidden = false
        canvas.appearance = NSAppearance(named: project.presentation.theme == "dark" ? .darkAqua : .aqua)
        layoutSubtreeIfNeeded()
        // An immutable snapshot must not inherit pending geometry from another version.
        canvas.update(diagram: nil, layout: nil, selection: .project)
        canvas.update(diagram: project, layout: preview.layout, selection: .project)
        canvas.fitToContent()
        navigationButtons.forEach { $0.isEnabled = true }
    }

    func showPlaceholder(_ title: String, detail: String, isLoading: Bool = false, canRetry: Bool = false) {
        canvas.update(diagram: nil, layout: nil, selection: .project)
        canvas.isHidden = true
        titleLabel.stringValue = "Предпросмотр версии"
        titleLabel.toolTip = nil
        detailLabel.stringValue = "Текущий проект изменится только после восстановления."
        placeholderTitle.stringValue = title
        placeholderDetail.stringValue = detail
        placeholder.isHidden = false
        retryButton.isHidden = !canRetry
        progress.isHidden = !isLoading
        if isLoading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        navigationButtons.forEach { $0.isEnabled = false }
    }

    private func buildInterface() {
        identifier = NSUserInterfaceItemIdentifier("version-history-preview-pane")
        titleLabel.identifier = NSUserInterfaceItemIdentifier("version-history-preview-title")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.identifier = NSUserInterfaceItemIdentifier("version-history-preview-details")
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let zoomOut = navigationButton("", symbol: "minus.magnifyingglass", action: #selector(zoomOutPreview))
        let zoomIn = navigationButton("", symbol: "plus.magnifyingglass", action: #selector(zoomInPreview))
        let fit = navigationButton("Вписать", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(fitPreview))
        zoomOut.toolTip = "Уменьшить предпросмотр"
        zoomIn.toolTip = "Увеличить предпросмотр"
        fit.toolTip = "Показать всю диаграмму выбранной версии"
        navigationButtons = [zoomOut, zoomIn, fit]
        let tools = NSStackView(views: navigationButtons)
        tools.orientation = .horizontal
        tools.spacing = 6
        tools.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = NSStackView(views: [titleLabel, NSView(), tools])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        let body = NSView()
        body.wantsLayer = true
        body.layer?.name = "theme-surface-control"
        body.layer?.backgroundColor = AppTheme.surface("control").cgColor
        canvas.identifier = NSUserInterfaceItemIdentifier("version-history-preview")
        canvas.isReadOnly = true
        canvas.isGridVisible = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(canvas)

        placeholderTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        placeholderTitle.alignment = .center
        placeholderTitle.lineBreakMode = .byTruncatingTail
        placeholderTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholderDetail.font = .systemFont(ofSize: 11)
        placeholderDetail.textColor = .secondaryLabelColor
        placeholderDetail.alignment = .center
        placeholderDetail.maximumNumberOfLines = 6
        progress.style = .spinning
        progress.controlSize = .small
        retryButton.identifier = NSUserInterfaceItemIdentifier("version-history-preview-retry")
        retryButton.target = self
        retryButton.action = #selector(retryPreview)
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.bezelStyle = .rounded
        [progress, placeholderTitle, placeholderDetail, retryButton].forEach(placeholder.addArrangedSubview)
        placeholder.identifier = NSUserInterfaceItemIdentifier("version-history-preview-placeholder")
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 10
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(placeholder)

        [heading, detailLabel, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            heading.heightAnchor.constraint(equalToConstant: 28),
            detailLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            detailLabel.heightAnchor.constraint(equalToConstant: 32),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: body.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -40),
            placeholderTitle.widthAnchor.constraint(lessThanOrEqualTo: placeholder.widthAnchor),
            placeholderDetail.widthAnchor.constraint(equalTo: placeholder.widthAnchor),
        ])
    }

    private func navigationButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    @objc private func retryPreview() { onRetry?() }
    @objc private func zoomOutPreview() { canvas.zoom(by: 0.8) }
    @objc private func zoomInPreview() { canvas.zoom(by: 1.25) }
    @objc private func fitPreview() { canvas.fitToContent() }
}

@MainActor
final class VersionHistoryCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let metadata = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        metadata.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        metadata.textColor = .secondaryLabelColor
        metadata.maximumNumberOfLines = 2
        metadata.lineBreakMode = .byTruncatingTail
        textField = title
        [title, metadata].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            metadata.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            metadata.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ version: ProjectVersion) {
        title.stringValue = "№\(version.id) — \(version.title)"
        let date = version.createdAt.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
        metadata.stringValue = "\(date)\n\(version.revision.prefix(12))"
        toolTip = "\(title.stringValue)\n\(date)\n\(version.revision)"
    }
}
