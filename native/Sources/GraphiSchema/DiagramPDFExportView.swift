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

indirect enum PDFLegendRow {
    case node(DiagramNode, Int)
    case edge(DiagramEdge, Int)
    case custom(PDFLegendRow, String)

    var symbol: PDFLegendRow { if case .custom(let row,_) = self { return row.symbol }; return self }
    var customDescription: String? { if case .custom(_,let value) = self { return value }; return nil }
    func height(width: CGFloat) -> CGFloat {
        guard let value = customDescription else { return 30 }
        let bounds = (value as NSString).boundingRect(with: NSSize(width: max(30,width-42),height: .greatestFiniteMagnitude),options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: [.font:NSFont.systemFont(ofSize: 9)])
        return max(30,ceil(bounds.height)+12)
    }
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
        let available = pageSize.height-settings.margin*2-settings.headerHeight-settings.footerHeight-28
        let legendWidth = side ? min(190,(pageSize.width-settings.margin*2)*0.3) : pageSize.width-settings.margin*2
        var batches: [[PDFLegendRow]] = [], batch: [PDFLegendRow] = [], used: CGFloat = 0
        // Split long manual descriptions across pages; never clip or omit rows.
        let preparedRows = rows.flatMap { row -> [PDFLegendRow] in
            guard row.height(width: legendWidth)>available,let value = row.customDescription else { return [row] }
            var fragments: [PDFLegendRow] = [], text = ""
            for character in value {
                let candidate = text+String(character)
                if PDFLegendRow.custom(row.symbol,candidate).height(width: legendWidth)>available && !text.isEmpty {
                    fragments.append(.custom(row.symbol,text)); text = String(character)
                } else { text = candidate }
            }
            if !text.isEmpty { fragments.append(.custom(row.symbol,text)) }
            return fragments
        }
        for row in preparedRows {
            let height = row.height(width: legendWidth)
            if !batch.isEmpty && used+height>available { batches.append(batch); batch = []; used = 0 }
            batch.append(row); used += height
        }
        if !batch.isEmpty { batches.append(batch) }
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
        canvas.appearance = NSAppearance(named: .aqua); canvas.pdfStyle = scene.style; canvas.showsGroupFrames = scene.style.showGroups
        canvas.update(diagram: scene.project, layout: scene.layout, selection: .project)
        return canvas
    }

    static func legendRows(_ project: DiagramProject) -> [PDFLegendRow] {
        if project.presentation.effectiveLegendMode == "manual" {
            return project.presentation.effectiveLegendEntries.compactMap { entry in
                if entry.kind == "edge_type",let definition = project.effectiveEdgeTypes.first(where: { $0.id == entry.edgeTypeId }) {
                    var edge = DiagramEdge(id: definition.id,source: "legend_source",target: "legend_target",label: definition.name,direction: definition.direction,style: definition.style)
                    edge.routing = definition.routing
                    return .custom(.edge(edge,1),entry.description ?? definition.description)
                }
                let node = project.nodes.first { $0.id == entry.nodeId } ?? DiagramNode(id: entry.id,label: "",description: "",kind: "",shape: entry.shape,containerId: nil,style: NodeStyle(fillMode: "theme",strokeMode: "theme",textMode: "theme",fill: "#FFFFFF",stroke: "#172238",text: "#172238",penwidth: 1.5),x: nil,y: nil,width: nil,height: nil,icon: entry.icon)
                let title = entry.description ?? (entry.nodeId == nil ? PaletteLibrary.allObjects.first { $0.iconPath == entry.icon && $0.shape == entry.shape }?.title ?? "" : node.label)
                return .custom(.node(node,1),title)
            }
        }
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
        if settings.includeBranch {
            text("Ветка: \(settings.branchName)",in: NSRect(x: settings.margin,y: bounds.height-settings.margin-(settings.includeTitle ? 43 : 18),width: contentRect.width,height: 15),size: 10,color: "#64748B")
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
        if settings.watermark {
            text("GraphiSchema",in: NSRect(x: settings.margin,y: settings.margin,width: 120,height: 12),size: 8,color: "#64748B")
        }
        if settings.pageNumbers {
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
            let rowHeight = row.height(width: rect.width)
            let symbol = NSRect(x: rect.minX+2,y: y+2,width: 28,height: 22)
            let title: String, detail: String
            switch row.symbol {
            case .node(let node,let count):
                LegendSymbols.draw(node,in: symbol,theme: "light")
                title = node.kind.isEmpty ? "Компонент" : node.kind
                detail = "\(node.icon.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? node.shape) · \(count) шт."
            case .edge(let edge,let count):
                LegendSymbols.draw(edge,in: symbol,theme: "light")
                title = edge.label.isEmpty ? "Связь" : edge.label.components(separatedBy: .newlines).joined(separator: " ")
                detail = "\(["solid":"Сплошная","dashed":"Пунктир","dotted":"Точки","bold":"Жирная"][edge.style.lineStyle] ?? edge.style.lineStyle) · \(count) шт."
            case .custom: title = ""; detail = "" // symbol recursively unwraps custom descriptions.
            }
            if let description = row.customDescription {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
                (description as NSString).draw(in: NSRect(x: rect.minX+38,y: y+30-rowHeight,width: rect.width-40,height: rowHeight-8),withAttributes: [.font:NSFont.systemFont(ofSize: 9),.foregroundColor:NSColor(hex: "#172238"),.paragraphStyle:paragraph])
            } else {
            text(title,in: NSRect(x: rect.minX+38,y: y+12,width: rect.width-40,height: 13),size: 9,weight: .medium)
            text(detail,in: NSRect(x: rect.minX+38,y: y,width: rect.width-40,height: 12),size: 8,color: "#64748B")
            }
            y -= rowHeight
        }
    }

    private func text(_ value: String,in rect: NSRect,size: CGFloat,weight: NSFont.Weight = .regular,
                      color: String = "#172238",alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        (value.components(separatedBy: .newlines).joined(separator: " ") as NSString).draw(in: rect,
            withAttributes: [.font:NSFont.systemFont(ofSize: size,weight: weight),.foregroundColor:NSColor(hex: color),.paragraphStyle:paragraph])
    }
}
