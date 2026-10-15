import AppKit

/// Measures real painted gaps, independently of the dash-array implementation.
@MainActor
enum NativeBorderRegressionTests {
    private struct Fixture: Decodable { var style: String; var width: Double; var pattern: [Double] }
    private struct Failure: Error { var message: String }
    private static var checks = 0
    private static var observations: [[String: Any]] = []
    private static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw Failure(message: message) }
    }

    static func run(_ starter: DiagramProject, backend: BackendService) async throws -> Int {
        checks = 0; observations = []
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root.appendingPathComponent("dist/quality/borders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("native/Tests/GraphiSchemaTests/Fixtures/border_patterns.json")))
            var style = starter.nodes[0].style
            for fixture in fixtures {
                style.penwidth = fixture.width; style.lineStyle = fixture.style
                let actual = style.borderDashPattern.map(Double.init)
                try expect(actual.count == fixture.pattern.count && zip(actual, fixture.pattern).allSatisfy { abs($0-$1)<1e-10 },
                           "Border fixture mismatch: \(fixture.style)/\(fixture.width): \(actual)")
            }
            style.lineStyle = nil
            try expect(style.borderDashPattern.isEmpty, "Legacy styles without line_style must remain solid")
            let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
            canvas.isGridVisible = false; canvas.isReadOnly = true
            let model = AppModel(backend: backend, blankCanvas: true); await model.bootstrap()
            let before = try await model.fetchStorageInfo()
            for lineStyle in ["dashed", "dotted", "solid"] {
                for width in [1.5, 4.0, 10.0] {
                    var project = starter
                    var node = starter.nodes[0]
                    node.id = "border"; node.icon = nil; node.shape = "box"; node.containerId = nil
                    node.x = 0; node.y = 0; node.width = 10; node.height = 1; node.label = "X"
                    node.style.fillMode = "custom"; node.style.strokeMode = "custom"; node.style.textMode = "custom"
                    node.style.fill = "#FFFFFF"; node.style.stroke = "#FF0000"; node.style.text = "#FFFFFF"
                    node.style.penwidth = width; node.style.lineStyle = lineStyle
                    project.nodes = [node]; project.edges = []; project.containers = []
                    project.diagram.layoutMode = "manual"; project.presentation.theme = "light"; project.presentation.background = "#FFFFFF"
                    project.project = model.diagram!.project
                    let layout = DiagramLayout(engine: "test", edgeRouting: "straight", width: 12, height: 4, minX: -6, minY: -2,
                                               nodes: [LayoutNode(id: node.id, x: 0, y: 0, width: 10, height: 1)], edges: [])
                    for zoom in [CGFloat(72), 120] {
                        canvas.update(diagram: project, layout: layout, selection: .project)
                        canvas.fitToContent(minimumScale: zoom, maximumScale: zoom)
                        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw Failure(message: "No canvas bitmap") }
                        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                        try observe(bitmap, pointsPerPixel: canvas.bounds.width/CGFloat(bitmap.pixelsWide),
                                    style: lineStyle, width: width, label: "canvas-\(Int(zoom))", folder: folder)
                    }
                    // Use the real PNG endpoint on an unregistered draft; the user's DB is never opened.
                    model.diagram = project
                    guard let baseURL = backend.baseURL else { throw Failure(message: "No preview endpoint") }
                    var request = URLRequest(url: baseURL.appending(path: "api/projects/preview"))
                    request.httpMethod = "POST"; request.httpBody = model.exportData()
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let (previewData, response) = try await URLSession.shared.data(for: request)
                    try expect((response as? HTTPURLResponse)?.statusCode == 200, "Border preview must succeed")
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let pngLayout = try decoder.decode(ProjectPreviewResponse.self, from: previewData).layout
                    for zoom in [1.0, 2.0, 4.0] {
                        let png = try await model.exportPNG(scale: zoom, background: "#FFFFFF")
                        guard let bitmap = NSBitmapImageRep(data: png) else { throw Failure(message: "Invalid exported PNG") }
                        let widthPoints = pngLayout.width*72+56
                        try observe(bitmap, pointsPerPixel: CGFloat(widthPoints)/CGFloat(bitmap.pixelsWide),
                                    style: lineStyle, width: width, label: "png-\(Int(zoom))x", folder: folder)
                    }
                    let pdf = DiagramPDFExportView(project: project, layout: layout, pageSize: NSSize(width: 1200, height: 420), includeLegend: false)
                    pdf.layoutSubtreeIfNeeded()
                    let data = pdf.dataWithPDF(inside: pdf.bounds)
                    guard let rep = NSPDFImageRep(data: data),
                          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 420,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(message: "Cannot rasterize exported PDF") }
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    rep.draw(in: pdf.bounds)
                    NSGraphicsContext.restoreGraphicsState()
                    try observe(bitmap, pointsPerPixel: 1/pdf.diagramScale, style: lineStyle, width: width, label: "pdf", folder: folder)
                    if width == 10 { try data.write(to: folder.appendingPathComponent("\(lineStyle)-10pt.pdf")) }
                }
            }
            let after = try await model.fetchStorageInfo()
            try expect(model.isTransientProject && before.projectCount == after.projectCount && before.versionCount == after.versionCount,
                       "Border export observations must not register projects or versions")
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("measurements.json"))
            print("Border observations passed: \(checks) checks; shared widths 0.5–10 pt, real canvas at 2 zooms, PNG at 1/2/4x and rasterized PDF; visible gaps and periods scale with line width.")
            return checks
        } catch let failure as Failure { throw NSError(domain: "BorderRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message]) }
    }

    private static func observe(_ bitmap: NSBitmapImageRep, pointsPerPixel: CGFloat, style: String, width: Double,
                                label: String, folder: URL) throws {
        let bytes = bitmap.bitmapData
        let directRGB = bitmap.bitsPerSample == 8 && !bitmap.isPlanar && (3...4).contains(bitmap.samplesPerPixel)
            && bitmap.bitsPerPixel == bitmap.samplesPerPixel*8
            && [NSColorSpaceName.deviceRGB, .calibratedRGB].contains(bitmap.colorSpaceName)
        let redOffset = bitmap.hasAlpha && bitmap.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        func red(_ x: Int, _ y: Int) -> Bool {
            if directRGB, let bytes {
                let offset = y*bitmap.bytesPerRow+x*bitmap.samplesPerPixel+redOffset
                let r = Int(bytes[offset]), g = Int(bytes[offset+1]), b = Int(bytes[offset+2])
                return r > 165 && r-g > 102 && r-b > 102
            }
            return autoreleasepool {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.65 && color.redComponent-color.greenComponent > 0.4 && color.redComponent-color.blueComponent > 0.4
            }
        }
        // Find the horizontal boundary by painted ink, without sharing the renderer's path geometry.
        var row = 0, count = 0
        for y in 0..<bitmap.pixelsHigh {
            let ink = stride(from: 0, to: bitmap.pixelsWide, by: 4).reduce(0) { $0 + (red($1, y) ? 1 : 0) }
            if ink > count { row = y; count = ink }
        }
        let mask = (0..<bitmap.pixelsWide).map { red($0, row) }
        guard let first = mask.firstIndex(of: true), let last = mask.lastIndex(of: true) else { throw Failure(message: "No painted border: \(label)/\(style)/\(width)") }
        let inset = Int(ceil(max(12, width*2)/Double(pointsPerPixel)))
        let start = first+inset, end = last-inset
        try expect(start < end, "Border observation must contain a usable straight section")
        var runs: [(ink: Bool, start: Int, end: Int)] = []
        var runStart = start
        for x in (start+1)...end where mask[x] != mask[x-1] {
            runs.append((mask[x-1], runStart, x)); runStart = x
        }
        runs.append((mask[end], runStart, end+1))
        let full = Array(runs.dropFirst().dropLast())
        let name = "\(label) \(style) \(width) pt"
        if style == "solid" {
            try expect(!mask[start...end].contains(false), "Solid border contains a gap: \(name)")
        } else {
            let gaps = full.filter { !$0.ink }.map { Double($0.end-$0.start)*Double(pointsPerPixel) }
            let ink = full.filter(\.ink)
            let periods = zip(ink, ink.dropFirst()).map { Double($1.start-$0.start)*Double(pointsPerPixel) }
            func median(_ values: [Double]) -> Double { values.sorted()[values.count/2] }
            try expect(gaps.count >= 2 && periods.count >= 2, "Thick border merged or has too few visible gaps: \(name)")
            let gap = median(gaps), period = median(periods)
            let expectedGap = width*(style == "dashed" ? 5/3 : 1), expectedPeriod = width*(style == "dashed" ? 20/3 : 3)
            let tolerance = max(1.3, Double(pointsPerPixel)*1.6)
            try expect(abs(gap-expectedGap) < tolerance, "Painted gap mismatch: \(name): \(gap), expected \(expectedGap)")
            try expect(abs(period-expectedPeriod) < tolerance, "Painted period mismatch: \(name): \(period), expected \(expectedPeriod)")
            observations.append(["medium": label, "style": style, "widthPt": width, "visibleGapPt": gap,
                                 "periodPt": period, "expectedGapPt": expectedGap, "expectedPeriodPt": expectedPeriod])
        }
        if width == 10 { try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(label)-\(style)-10pt.png")) }
    }
}
