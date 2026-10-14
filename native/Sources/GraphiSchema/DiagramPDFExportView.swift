import AppKit

@MainActor
final class DiagramPDFExportView: NSView {
    private let canvas = DiagramCanvasView(frame: .zero)
    private let project: DiagramProject
    private let includeLegend: Bool
    private let legendWidth: CGFloat
    private var didFitCanvas = false

    init(project: DiagramProject, layout: DiagramLayout, pageSize: NSSize, includeLegend: Bool) {
        self.project = project
        self.includeLegend = includeLegend
        legendWidth = includeLegend ? min(190, pageSize.width * 0.24) : 0
        super.init(frame: NSRect(origin: .zero, size: pageSize))
        wantsLayer = true
        canvas.isReadOnly = true
        canvas.isGridVisible = false
        canvas.exportBackground = "#FFFFFF"
        canvas.update(diagram: project, layout: layout, selection: .project)
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let margin: CGFloat = 30
        let headerHeight: CGFloat = 44
        let contentWidth = bounds.width - margin * 2 - legendWidth - (includeLegend ? 18 : 0)
        canvas.frame = NSRect(x: margin, y: margin, width: max(100, contentWidth),
                              height: max(100, bounds.height - margin * 2 - headerHeight))
        if !didFitCanvas {
            canvas.fitToContent(minimumScale: 0.5)
            didFitCanvas = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let title = project.project.title.isEmpty ? "Архитектурная схема" : project.project.title
        (title as NSString).draw(at: NSPoint(x: 30, y: bounds.maxY - 34),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                  .foregroundColor: NSColor(hex: "#172238")])
        if includeLegend { drawLegend() }
    }

    private func drawLegend() {
        let left = bounds.maxX - legendWidth - 26
        let top = bounds.maxY - 58
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: left - 10, y: 24))
        divider.line(to: NSPoint(x: left - 10, y: bounds.maxY - 50))
        NSColor(hex: "#D8DEE8").setStroke()
        divider.stroke()
        ("Условные обозначения" as NSString).draw(at: NSPoint(x: left, y: top),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor(hex: "#172238")])

        let nodeKinds = Dictionary(grouping: project.nodes, by: \.kind).sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let edgeKinds = Dictionary(grouping: project.edges, by: { "\($0.style.lineStyle)|\($0.style.color)|\($0.direction)" })
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let plannedRows = min(nodeKinds.count, 12) + (nodeKinds.count > 12 ? 1 : 0)
            + (edgeKinds.isEmpty ? 0 : 1 + min(edgeKinds.count, 10) + (edgeKinds.count > 10 ? 1 : 0))
        let rowHeight = max(15, min(25, (bounds.height - 125) / CGFloat(max(1, plannedRows))))
        var y = top - 22
        for (kind, nodes) in nodeKinds.prefix(12) {
            guard let sample = nodes.first else { continue }
            let swatch = NSBezierPath(roundedRect: NSRect(x: left, y: y, width: 16, height: 12), xRadius: 2, yRadius: 2)
            NSColor(hex: sample.style.fill).setFill(); swatch.fill()
            NSColor(hex: sample.style.stroke).setStroke(); swatch.lineWidth = 1; swatch.stroke()
            drawLegendText(kind, x: left + 22, y: y + 1)
            y -= rowHeight
        }
        if nodeKinds.count > 12 {
            drawLegendText("+ ещё \(nodeKinds.count - 12) типов", x: left + 2, y: y + 1, secondary: true)
            y -= rowHeight
        }
        if !edgeKinds.isEmpty {
            y -= 4
            ("Связи" as NSString).draw(at: NSPoint(x: left, y: y),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor(hex: "#475569")])
            y -= rowHeight * 0.9
            for (_, edges) in edgeKinds.prefix(10) {
                guard let sample = edges.first else { continue }
                let path = NSBezierPath()
                path.move(to: NSPoint(x: left, y: y + 5)); path.line(to: NSPoint(x: left + 17, y: y + 5))
                path.lineWidth = max(1, min(3, CGFloat(sample.style.penwidth)))
                if sample.style.lineStyle == "dashed" {
                    let dash: [CGFloat] = [4, 2]; path.setLineDash(dash, count: dash.count, phase: 0)
                } else if sample.style.lineStyle == "dotted" {
                    let dash: [CGFloat] = [1, 2]; path.setLineDash(dash, count: dash.count, phase: 0)
                }
                NSColor(hex: sample.style.color).setStroke(); path.stroke()
                let title = "\(sample.label.isEmpty ? sample.style.lineStyle : sample.label) · \(sample.direction == "forward" ? "→" : sample.direction == "both" ? "↔" : "—")"
                drawLegendText(title, x: left + 22, y: y)
                y -= rowHeight
            }
            if edgeKinds.count > 10 { drawLegendText("+ ещё \(edgeKinds.count - 10) связей", x: left + 2, y: y + 1, secondary: true) }
        }
    }

    private func drawLegendText(_ text: String, x: CGFloat, y: CGFloat, secondary: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor(hex: "#263247"),
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: NSRect(x: x, y: y, width: legendWidth - 52, height: 14), withAttributes: attributes)
    }
}
