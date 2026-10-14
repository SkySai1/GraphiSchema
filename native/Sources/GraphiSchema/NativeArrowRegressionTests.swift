import AppKit
import Darwin

@MainActor
final class NativeArrowRegressionTests {
    private var failures = 0
    private var failureMessages: [String] = []

    static func run() {
        let tests = NativeArrowRegressionTests()
        do {
            try tests.testKnownCoordinatesOfShaftTipAndRear()
            tests.testAllMarkerShapesDirectionsWidthsAndShortSegments()
            try tests.testRawMultiSegmentBezierRetainsItsMiddleJoint()
            try tests.testRealGraphvizLayoutsHaveIdenticalNativeAndSVGJoinsAtThreeZooms()
            try tests.testRasterizedNativeLeadsHaveNoGapForSolidDashedAndDottedLines()
            try tests.testHitTestingFollowsTheAdjustedShaft()
            try tests.testUpdatesPreserveRoutesForStylesAndInvalidateChangedContours()
        } catch { tests.failure("\(error)") }
        if let folder = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_ARROW_ARTIFACT_DIR"] {
            try? tests.failureMessages.joined(separator: "\n").write(toFile: folder+"/failures.log", atomically: true, encoding: .utf8)
        }
        guard tests.failures == 0 else {
            FileHandle.standardError.write(Data("Native arrow regression tests failed: \(tests.failures) checks.\n".utf8))
            exit(1)
        }
        print("Native arrow regression tests passed: exact coordinates, 1,792 marker joins, raw and normalized curves, SVG parity and actual rasterized leads.")
    }
    private struct Known: Decodable {
        var name: String; var points: [[Double]]; var head: String; var tail: String
        var lineWidth: Double; var expectedStart: [Double]; var expectedEnd: [Double]; var expectedTip: [Double]?
    }
    private struct Fixture: Decodable {
        var name: String; var project: DiagramProject; var layout: DiagramLayout
        var svgMeasurements: [Measurement]
    }
    private struct Measurement: Decodable {
        var endpoint: String; var shaftX: Double; var shaftY: Double; var tipX: Double; var tipY: Double
    }

    private func decode<T: Decodable>(_ type: T.Type, file: String) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("native/Tests/GraphiSchemaTests/Fixtures/\(file).json")
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func fixtures() throws -> [Fixture] {
        if let path = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_ARROW_FIXTURES"] {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return try decode([Fixture].self, file: "backend_arrow_layouts")
    }

    private func point(_ value: [Double]) -> NSPoint { NSPoint(x: value[0], y: value[1]) }
    private func equal(_ actual: NSPoint, _ expected: NSPoint, _ message: String, accuracy: CGFloat = 1e-7,
                       file: StaticString = #filePath, line: UInt = #line) {
        assertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        assertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    }

    func testKnownCoordinatesOfShaftTipAndRear() throws {
        for value in try decode([Known].self, file: "arrow_geometry") {
            let drawing = ArrowGeometry.make(value.points.map(point), head: value.head, tail: value.tail, lineWidth: value.lineWidth)
            equal(try unwrap(drawing.shaft.first), point(value.expectedStart), value.name)
            equal(try unwrap(drawing.shaft.last), point(value.expectedEnd), value.name)
            if let expected = value.expectedTip { equal(try unwrap(drawing.head).tip, point(expected), value.name) }
            else { assertNil(drawing.head, value.name) }
        }
    }

    private func rear(_ marker: ArrowMarkerGeometry) -> NSPoint {
        let polygon = marker.polygon
        func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint { NSPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2) }
        switch marker.kind {
        case "normal", "box": return midpoint(polygon[1], polygon[2])
        case "diamond": return polygon[2]
        case "tee": return midpoint(polygon[0], polygon[1])
        case "vee", "crow": return midpoint(polygon[0], polygon[2])
        case "dot": return marker.point(6)
        default: return marker.base
        }
    }

    private func assertJoin(_ shaft: [NSPoint], _ marker: ArrowMarkerGeometry, _ message: String) {
        assertAtLeast(shaft.count, 2, message)
        guard shaft.count >= 2 else { return }
        let rear = rear(marker), end = shaft.last!, previous = shaft[shaft.count-2]
        equal(end, rear, "\(message): shaft endpoint must be the centre of the actual rear edge")
        let dx = end.x-previous.x, dy = end.y-previous.y, length = hypot(dx, dy)
        assertGreater(length, 0, message)
        assertEqual((dx*marker.unit.y-dy*marker.unit.x)/max(length, 1e-12), 0, accuracy: 1e-7, message)
        assertGreater(dx*marker.unit.x+dy*marker.unit.y, 0, "\(message): shaft must approach from behind")
        assertGreater(marker.scale, 0, message)
        assertTrue(marker.scale.isFinite, message)
    }

    func testAllMarkerShapesDirectionsWidthsAndShortSegments() {
        let routes: [[NSPoint]] = [
            [.init(x: 0, y: 0), .init(x: 100, y: 0)],
            [.init(x: 0, y: 0), .init(x: 98, y: 0), .init(x: 98, y: 2), .init(x: 100, y: 2)],
            [.init(x: 0, y: 0), .init(x: 0, y: 3), .init(x: 2, y: 3)],
            CanvasGeometry.sampleCubic(.zero, .init(x: 2, y: 80), .init(x: 98, y: -80), .init(x: 100, y: 0)),
        ]
        for direction in 0..<8 {
            let angle = CGFloat(direction) * .pi / 4
            for (index, input) in routes.enumerated() {
                let rotated = input.map { NSPoint(x: $0.x*cos(angle)-$0.y*sin(angle), y: $0.x*sin(angle)+$0.y*cos(angle)) }
                for width in [CGFloat(1), 2, 5, 10] {
                    for kind in ["normal", "diamond", "box", "dot", "tee", "vee", "crow"] {
                        let drawing = ArrowGeometry.make(rotated, head: kind, tail: kind, lineWidth: width)
                        let message = "direction=\(direction) route=\(index) width=\(width) kind=\(kind)"
                        guard let head = drawing.head, let tail = drawing.tail else { failure(message); continue }
                        equal(head.tip, rotated.last!, message); equal(tail.tip, rotated.first!, message)
                        assertJoin(drawing.shaft, head, message)
                        assertJoin(Array(drawing.shaft.reversed()), tail, message)
                    }
                }
            }
        }
    }

    func testRawMultiSegmentBezierRetainsItsMiddleJoint() throws {
        let fixture = try unwrap(fixtures().first)
        var settings = fixture.project.diagram; settings.edgeRouting = "curved"
        var source = fixture.project.nodes[0], target = fixture.project.nodes[1]
        source.icon = nil; source.shape = "box"; target.icon = nil; target.shape = "box"
        let controls = [[0.7, 0.0], [1, 1], [1, 2], [2, 2], [3, 2], [3, 1], [3.3, 0]]
        let route = CanvasGeometry.edgePoints(fixture.project.edges[0],
            source: LayoutNode(id: source.id, x: 0, y: 0, width: 1.4, height: 1.2),
            target: LayoutNode(id: target.id, x: 4, y: 0, width: 1.4, height: 1.2),
            sourceNode: source, targetNode: target, settings: settings, proposed: controls.map(point))
        assertEqual(route.count, 49)
        equal(route[24], NSPoint(x: 2, y: 2), "Both cubic segments must be retained")
    }

    private func canvas(_ fixture: Fixture, zoom: CGFloat) -> DiagramCanvasView {
        _ = NSApplication.shared
        let view = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: max(150, CGFloat(fixture.layout.width)*zoom+80),
                                                  height: max(150, CGFloat(fixture.layout.height)*zoom+80)))
        view.isGridVisible = false
        view.update(diagram: fixture.project, layout: fixture.layout, selection: .project)
        view.fitToContent(minimumScale: zoom, maximumScale: zoom)
        return view
    }

    func testRealGraphvizLayoutsHaveIdenticalNativeAndSVGJoinsAtThreeZooms() throws {
        var csv = ["case,zoom,endpoint,shaft_x,shaft_y,tip_x,tip_y,rear_x,rear_y,join_error_pt"]
        let values = try fixtures()
        for fixture in values {
            for zoom in [CGFloat(12), 72, 220] {
                let view = canvas(fixture, zoom: zoom)
                let raw = view.edgePoints(for: "link")
                let geometry = try unwrap(fixture.layout.edges.first)
                assertEqual(raw.count, geometry.points.count, "\(fixture.name): normalized route must not be reconstructed")
                for (a, b) in zip(raw, geometry.points) { equal(a, NSPoint(x: b.x, y: b.y), fixture.name) }
                let drawing = try unwrap(view.edgeDrawing(for: "link"))
                for (endpoint, marker, shaft) in [("target", drawing.head, drawing.shaft), ("source", drawing.tail, Array(drawing.shaft.reversed()))] {
                    let marker = try unwrap(marker)
                    let message = "\(fixture.name) \(endpoint) zoom=\(zoom)"
                    assertJoin(shaft, marker, message)
                    equal(marker.tip, view.screenPoint(for: endpoint == "target" ? raw.last! : raw.first!), message)
                    let end = shaft.last!, base = rear(marker)
                    csv.append("\(fixture.name),\(zoom),\(endpoint),\(end.x),\(end.y),\(marker.tip.x),\(marker.tip.y),\(base.x),\(base.y),\(hypot(end.x-base.x,end.y-base.y))")
                    if zoom == 72 {
                        let svg = try unwrap(fixture.svgMeasurements.first(where: { $0.endpoint == endpoint }))
                        equal(NSPoint(x: end.x-marker.tip.x, y: end.y-marker.tip.y),
                              NSPoint(x: svg.shaftX-svg.tipX, y: svg.tipY-svg.shaftY), message, accuracy: 0.0002)
                    }
                }
            }
        }
        if let folder = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_ARROW_ARTIFACT_DIR"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try csv.joined(separator: "\n").write(toFile: folder+"/native-measurements.csv", atomically: true, encoding: .utf8)
        }
        print("Arrow observations completed: \(values.count) real Graphviz layouts × 3 zooms × 2 endpoints.")
    }

    func testRasterizedNativeLeadsHaveNoGapForSolidDashedAndDottedLines() throws {
        let selected = Set(["short-elbow-straight", "manual-RL-curved", "auto-dot-RL-curved", "fixed-ports-orthogonal", "icon-curved", "self-loop-angled"])
        for original in try fixtures().filter({ selected.contains($0.name) }) {
            for zoom in [CGFloat(12), 72, 220] {
                for style in ["solid", "dashed", "dotted"] {
                    var fixture = original; fixture.project.edges[0].style.lineStyle = style
                    let view = canvas(fixture, zoom: zoom)
                    let drawing = try unwrap(view.edgeDrawing(for: "link"))
                    let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    for marker in [drawing.head, drawing.tail].compactMap({ $0 }) {
                        let start = marker.guide, end = marker.base
                        let samples = max(1, Int(ceil(hypot(end.x-start.x, end.y-start.y)*4)))
                        for step in 0...samples {
                            let t = CGFloat(step)/CGFloat(samples)
                            let p = NSPoint(x: start.x+t*(end.x-start.x), y: start.y+t*(end.y-start.y))
                            assertTrue(redPixelNear(p, in: view, bitmap: bitmap), "\(fixture.name) \(style) zoom=\(zoom): missing rasterized rear join at \(p)")
                        }
                    }
                    if zoom == 72 && style == "solid", let folder = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_ARROW_ARTIFACT_DIR"] {
                        let png = try unwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: URL(fileURLWithPath: folder+"/\(fixture.name).png"))
                    }
                }
            }
        }
    }

    private func redPixelNear(_ p: NSPoint, in view: NSView, bitmap: NSBitmapImageRep) -> Bool {
        let x = Int(((p.x-view.bounds.minX)*CGFloat(bitmap.pixelsWide)/view.bounds.width).rounded())
        let y = Int(((view.bounds.maxY-p.y)*CGFloat(bitmap.pixelsHigh)/view.bounds.height).rounded())
        for dx in -1...1 { for dy in -1...1 {
            guard x+dx >= 0, x+dx < bitmap.pixelsWide, y+dy >= 0, y+dy < bitmap.pixelsHigh,
                  let color = bitmap.colorAt(x: x+dx, y: y+dy)?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.7 && color.greenComponent < 0.8 && color.blueComponent < 0.8 { return true }
        } }
        return false
    }

    func testHitTestingFollowsTheAdjustedShaft() throws {
        let fixture = try unwrap(fixtures().first(where: { $0.name == "short-elbow-straight" }))
        let view = canvas(fixture, zoom: 72)
        let shaft = try unwrap(view.edgeDrawing(for: "link")).shaft
        let a = shaft[shaft.count-3], b = shaft[shaft.count-2]
        let position = NSPoint(x: (a.x+b.x)/2, y: (a.y+b.y)/2)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var selected: DiagramSelection?
        view.onSelect = { selected = $0 }
        let event = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(position, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        assertEqual(selected, .edge("link"), "Clicking the shifted terminal shaft must select its edge")
    }

    func testUpdatesPreserveRoutesForStylesAndInvalidateChangedContours() throws {
        let fixture = try unwrap(fixtures().first(where: { $0.name == "manual-NW-curved" }))
        let view = canvas(fixture, zoom: 72)
        let original = view.edgePoints(for: "link")
        var project = fixture.project
        project.edges[0].style.color = "#AA3377"
        view.update(diagram: project, layout: fixture.layout, selection: .project)
        assertEqual(view.edgePoints(for: "link"), original, "Style changes must preserve the authoritative route")
        project.nodes[0].shape = "box"
        view.update(diagram: project, layout: fixture.layout, selection: .project)
        equal(try unwrap(view.edgePoints(for: "link").first), NSPoint(x: 3.3, y: 4.6),
              "Replacing the ellipse must update the attachment to the new box contour")
        project.edges[0].waypoints = [RoutePoint(x: 2.1, y: 5)]
        view.update(diagram: project, layout: fixture.layout, selection: .project)
        assertTrue(view.edgePoints(for: "link").contains(NSPoint(x: 2.1, y: 5)),
                   "Editing a route must invalidate cached backend geometry")
        let drawing = try unwrap(view.edgeDrawing(for: "link"))
        assertJoin(drawing.shaft, try unwrap(drawing.head), "Live route edit")
        assertJoin(Array(drawing.shaft.reversed()), try unwrap(drawing.tail), "Live route edit")
    }

    private func failure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        failures += 1
        failureMessages.append("\(file):\(line): \(message)")
        if failures <= 25 { FileHandle.standardError.write(Data("\(file):\(line): \(message)\n".utf8)) }
        else if failures == 26 { FileHandle.standardError.write(Data("Further failures are saved to the arrow artifact directory.\n".utf8)) }
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                          file: StaticString = #filePath, line: UInt = #line) {
        if actual != expected { failure("\(message): actual=\(actual), expected=\(expected)", file: file, line: line) }
    }

    private func assertEqual(_ actual: CGFloat, _ expected: CGFloat, accuracy: CGFloat, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        if !actual.isFinite || abs(actual-expected) > accuracy {
            failure("\(message): actual=\(actual), expected=\(expected), tolerance=\(accuracy)", file: file, line: line)
        }
    }

    private func assertTrue(_ condition: Bool, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        if !condition { failure(message, file: file, line: line) }
    }

    private func assertNil<T>(_ value: T?, _ message: String) { assertTrue(value == nil, message) }
    private func assertGreater<T: Comparable>(_ actual: T, _ minimum: T, _ message: String) { assertTrue(actual > minimum, message) }
    private func assertAtLeast<T: Comparable>(_ actual: T, _ minimum: T, _ message: String) { assertTrue(actual >= minimum, message) }
    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "ArrowRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing regression geometry"]) }
        return value
    }
}
