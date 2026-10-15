import AppKit
import PDFKit

enum DiagramPDFError: LocalizedError {
    case rendering
    case pageTooSmall
    var errorDescription: String? {
        switch self {
        case .rendering: "Не удалось сформировать векторный PDF. Попробуйте уменьшить размер схемы или подписи."
        case .pageTooSmall: "Поля оставляют слишком мало места для схемы. Уменьшите поля или увеличьте размер листа."
        }
    }
}

struct DiagramPDFRenderResult {
    let data: Data
    let pageSize: NSSize
    let pageCount: Int
    let diagramScale: CGFloat
    let minimumFontSize: CGFloat
    let movedNodes: Int
    let movedLabels: Int
    let remainingOverlaps: Int
}

enum PDFLegendRow {
    case node(DiagramNode, Int)
    case edge(DiagramEdge, Int)
}

@MainActor
enum DiagramPDFRenderer {
    static func render(project: DiagramProject, layout: DiagramLayout, settings: DiagramPDFSettings) throws -> DiagramPDFRenderResult {
        let scene = DiagramPDFScene.prepare(project: project, layout: layout, settings: settings)
        let canvas = makeCanvas(scene)
        guard let sourceDocument = PDFDocument(data: canvas.pdfSceneData()),
              let scenePage = sourceDocument.page(at: 0) else { throw DiagramPDFError.rendering }
        let pageSize = settings.pageSize(scene: scenePage.bounds(for: .mediaBox).size)
        guard pageSize.width-settings.margin*2 >= 160,
              pageSize.height-settings.margin*2-settings.headerHeight-settings.footerHeight >= 140 else { throw DiagramPDFError.pageTooSmall }
        let rows = settings.includeLegend ? legendRows(scene.project) : []
        let side = !rows.isEmpty && !settings.legendOnSeparatePage
        let capacity = max(1, Int((pageSize.height-settings.margin*2-settings.headerHeight-settings.footerHeight-28)/30))
        var batches: [[PDFLegendRow]] = []
        if !rows.isEmpty {
            for start in stride(from: 0, to: rows.count, by: capacity) { batches.append(Array(rows[start..<min(rows.count,start+capacity)])) }
        }
        let firstRows = side ? (batches.first ?? []) : []
        let later = side ? Array(batches.dropFirst()) : batches
        let count = 1+later.count
        let document = PDFDocument()
        var scale: CGFloat = 1
        for index in 0..<count {
            let view = DiagramPDFExportView(scene: index == 0 ? scenePage : nil, project: scene.project,
                settings: settings, pageSize: pageSize, rows: index == 0 ? firstRows : later[index-1],
                sidebar: index == 0 && side, pageIndex: index+1, pageCount: count,sourceDocument: sourceDocument)
            if index == 0 { scale = view.diagramScale }
            guard let page = PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0) else { throw DiagramPDFError.rendering }
            document.insert(page, at: index)
        }
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: project.project.title,
                                       PDFDocumentAttribute.creatorAttribute: "GraphiSchema"]
        guard let data = document.dataRepresentation() else { throw DiagramPDFError.rendering }
        var sizes = scene.project.nodes.map { CGFloat($0.style.effectiveFontSize) }
        sizes += scene.project.edges.filter { !$0.label.isEmpty }.map { CGFloat($0.style.effectiveFontSize) }
        if !scene.project.containers.isEmpty { sizes.append(CGFloat(settings.containerFontSize)) }
        return DiagramPDFRenderResult(data: data, pageSize: pageSize, pageCount: count, diagramScale: scale,
            minimumFontSize: (sizes.min() ?? 10)*scale, movedNodes: scene.movedNodes,
            movedLabels: scene.movedLabels, remainingOverlaps: scene.remainingOverlaps)
    }

    static func makeCanvas(_ scene: DiagramPDFScene) -> DiagramCanvasView {
        let canvas = DiagramCanvasView(frame: .zero)
        canvas.isReadOnly = true; canvas.isGridVisible = false; canvas.exportBackground = "#FFFFFF"
        canvas.appearance = NSAppearance(named: .aqua); canvas.pdfStyle = scene.style
        canvas.update(diagram: scene.project, layout: scene.layout, selection: .project)
        return canvas
    }

    static func legendRows(_ project: DiagramProject) -> [PDFLegendRow] {
        let nodes = Dictionary(grouping: project.nodes) { node in
            "\(node.kind)|\(node.icon ?? node.shape)|\(node.style.resolved(.fill,theme: "light"))|\(node.style.resolved(.stroke,theme: "light"))"
        }.sorted { $0.key < $1.key }
        let edges = Dictionary(grouping: project.edges) { edge in
            "\(edge.label)|\(edge.style.lineStyle)|\(edge.style.resolved(.stroke,theme: "light"))|\(edge.direction)|\(edge.style.arrowhead)|\(edge.style.arrowtail)"
        }.sorted { $0.key < $1.key }
        let nodeRows: [PDFLegendRow] = nodes.compactMap { group in group.value.first.map { .node($0,group.value.count) } }
        return nodeRows + edges.compactMap { group in group.value.first.map { .edge($0,group.value.count) } }
    }
}

/// A paper page, used by the document builder and the legacy single-page API.
@MainActor
final class DiagramPDFExportView: NSView {
    private let scene: PDFPage?
    private let project: DiagramProject
    private let settings: DiagramPDFSettings
    private let rows: [PDFLegendRow]
    private let sidebar: Bool
    private let pageIndex: Int
    private let pageCount: Int
    private let sourceDocument: PDFDocument?

    init(scene: PDFPage?, project: DiagramProject, settings: DiagramPDFSettings, pageSize: NSSize,
         rows: [PDFLegendRow], sidebar: Bool, pageIndex: Int, pageCount: Int,sourceDocument: PDFDocument? = nil) {
        self.scene = scene; self.project = project; self.settings = settings; self.rows = rows
        self.sidebar = sidebar; self.pageIndex = pageIndex; self.pageCount = pageCount
        self.sourceDocument = sourceDocument
        super.init(frame: NSRect(origin: .zero,size: pageSize))
        appearance = NSAppearance(named: .aqua)
    }

    convenience init(project: DiagramProject, layout: DiagramLayout, pageSize: NSSize, includeLegend: Bool) {
        var settings = DiagramPDFSettings()
        settings.includeLegend = includeLegend
        let prepared = DiagramPDFScene.prepare(project: project,layout: layout,settings: settings)
        let canvas = DiagramPDFRenderer.makeCanvas(prepared)
        let document = PDFDocument(data: canvas.pdfSceneData())
        let page = document?.page(at: 0)
        self.init(scene: page,project: prepared.project,settings: settings,pageSize: pageSize,
                  rows: includeLegend ? DiagramPDFRenderer.legendRows(prepared.project) : [],sidebar: includeLegend,pageIndex: 1,pageCount: 1,sourceDocument: document)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var contentRect: NSRect {
        NSRect(x: settings.margin,y: settings.margin+settings.footerHeight,
               width: max(32,bounds.width-settings.margin*2),
               height: max(32,bounds.height-settings.margin*2-settings.headerHeight-settings.footerHeight))
    }
    private var diagramRect: NSRect {
        var area = contentRect
        if sidebar { area.size.width -= min(190,area.width*0.3)+14 }
        return area
    }
    var diagramScale: CGFloat {
        guard let scene else { return 1 }
        let size = scene.bounds(for: .mediaBox).size
        return min(diagramRect.width/max(1,size.width),diagramRect.height/max(1,size.height))*settings.occupancy
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        if settings.includeTitle {
            let title = project.project.title.isEmpty ? "Архитектурная схема" : project.project.title
            text(scene == nil ? "\(title) — условные обозначения" : title,
                 in: NSRect(x: settings.margin,y: bounds.height-settings.margin-25,width: contentRect.width,height: 25),size: 17,weight: .semibold)
        }
        if let scene, let context = NSGraphicsContext.current?.cgContext {
            let box = scene.bounds(for: .mediaBox), scale = diagramScale
            let area = diagramRect
            context.saveGState()
            context.translateBy(x: area.midX-box.width*scale/2,y: area.midY-box.height*scale/2)
            context.scaleBy(x: scale,y: scale)
            context.translateBy(x: -box.minX,y: -box.minY)
            scene.draw(with: .mediaBox,to: context)
            context.restoreGState()
        }
        if !rows.isEmpty {
            let width = sidebar ? min(190,contentRect.width*0.3) : contentRect.width
            let rect = NSRect(x: sidebar ? contentRect.maxX-width : contentRect.minX,y: contentRect.minY,
                              width: width,height: contentRect.height)
            drawLegend(in: rect)
        }
        if settings.pageNumbers {
            text("GraphiSchema",in: NSRect(x: settings.margin,y: settings.margin,width: 120,height: 12),size: 8,color: "#64748B")
            text("\(pageIndex) / \(pageCount)",in: NSRect(x: bounds.width-settings.margin-70,y: settings.margin,width: 70,height: 12),size: 8,color: "#64748B",alignment: .right)
        }
    }

    private func drawLegend(in rect: NSRect) {
        if sidebar {
            let path = NSBezierPath(); path.move(to: NSPoint(x: rect.minX-7,y: rect.minY)); path.line(to: NSPoint(x: rect.minX-7,y: rect.maxY))
            NSColor(hex: "#D8DEE8").setStroke(); path.lineWidth = 0.5; path.stroke()
        }
        text("Условные обозначения",in: NSRect(x: rect.minX,y: rect.maxY-17,width: rect.width,height: 16),size: 10,weight: .bold)
        var y = rect.maxY-48
        for row in rows {
            let symbol = NSRect(x: rect.minX+2,y: y+2,width: 28,height: 22)
            let title: String, detail: String
            switch row {
            case .node(let node,let count):
                let aspect = (node.width ?? 1)/(node.height ?? 1)
                let width = min(symbol.width,symbol.height*aspect), height = min(symbol.height,symbol.width/aspect)
                let frame = NSRect(x: symbol.midX-width/2,y: symbol.midY-height/2,width: width,height: height)
                let fill = NSBezierPath()
                for contour in CanvasGeometry.fillPaths(node) {
                    let points = contour.map { NSPoint(x: frame.minX+$0.x*frame.width,y: frame.minY+$0.y*frame.height) }
                    if let first = points.first { fill.move(to: first); for p in points.dropFirst() { fill.line(to: p) }; fill.close() }
                }
                NSColor(hex: node.style.resolved(.fill,theme: "light")).setFill(); fill.fill()
                NSColor(hex: node.style.resolved(.stroke,theme: "light")).setStroke()
                for contour in CanvasGeometry.paths(node) {
                    let line = NSBezierPath(); line.lineWidth = 0.8; line.lineJoinStyle = .round
                    let points = contour.map { NSPoint(x: frame.minX+$0.x*frame.width,y: frame.minY+$0.y*frame.height) }
                    if let first = points.first { line.move(to: first); for p in points.dropFirst() { line.line(to: p) }; line.stroke() }
                }
                title = node.kind.isEmpty ? "Компонент" : node.kind
                detail = "\(node.icon.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? node.shape) · \(count) шт."
            case .edge(let edge,let count):
                let points = [NSPoint(x: symbol.minX,y: symbol.midY),NSPoint(x: symbol.maxX,y: symbol.midY)]
                let geometry = ArrowGeometry.make(points,head: edge.direction == "none" ? "none" : edge.style.arrowhead,
                                                   tail: edge.direction == "both" ? edge.style.arrowtail : "none",lineWidth: 1)
                let path = NSBezierPath(); path.lineWidth = 1; path.lineCapStyle = .round
                if edge.style.lineStyle == "dashed" { path.setLineDash([4,3],count: 2,phase: 0) }
                if edge.style.lineStyle == "dotted" { path.setLineDash([1,3],count: 2,phase: 0) }
                NSColor(hex: edge.style.resolved(.stroke,theme: "light")).setStroke()
                if let first = geometry.shaft.first { path.move(to: first); for p in geometry.shaft.dropFirst() { path.line(to: p) }; path.stroke() }
                for marker in [geometry.head,geometry.tail].compactMap({ $0 }) {
                    let polygon = NSBezierPath(); let points = marker.polygon
                    if let first = points.first { polygon.move(to: first); for p in points.dropFirst() { polygon.line(to: p) }; polygon.close() }
                    NSColor(hex: edge.style.resolved(.stroke,theme: "light")).setFill(); polygon.fill()
                }
                title = edge.label.isEmpty ? "Связь" : edge.label.components(separatedBy: .newlines).joined(separator: " ")
                detail = "\(["solid":"Сплошная","dashed":"Пунктир","dotted":"Точки","bold":"Жирная"][edge.style.lineStyle] ?? edge.style.lineStyle) · \(count) шт."
            }
            text(title,in: NSRect(x: rect.minX+38,y: y+12,width: rect.width-40,height: 13),size: 9,weight: .medium)
            text(detail,in: NSRect(x: rect.minX+38,y: y,width: rect.width-40,height: 12),size: 8,color: "#64748B")
            y -= 30
        }
    }

    private func text(_ value: String,in rect: NSRect,size: CGFloat,weight: NSFont.Weight = .regular,
                      color: String = "#172238",alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        (value.components(separatedBy: .newlines).joined(separator: " ") as NSString).draw(in: rect,
            withAttributes: [.font:NSFont.systemFont(ofSize: size,weight: weight),.foregroundColor:NSColor(hex: color),.paragraphStyle:paragraph])
    }
}
