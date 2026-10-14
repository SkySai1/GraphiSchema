import AppKit
import Darwin

@MainActor
enum NativeInteractionRegressionTests {
    private struct Fixture: Decodable {
        let text: String; let width: Double; let fontSize: Double; let wrap: Bool; let expected: [String]
    }
    private struct Failure: Error { let message: String }
    private static var checks = 0
    private static func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw Failure(message: message) }
    }

    static func run() {
        _ = NSApplication.shared
        do {
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let starter = try decoder.decode(DiagramProject.self, from: Data(contentsOf: root.appendingPathComponent("examples/starter.json")))
            try checkTextFixtures(decoder, root: root)
            try checkAllFigureContours(starter)
            try checkRasterizedInk(starter)
            try checkLiveMoveAndStretch(starter)
            try checkTextWindow(starter)
            try checkInspectorTyping(starter)
            try checkWindowPlacement()
            print("Native interaction regressions passed: \(checks) checks; 54 collection figures, 6 shapes, four zooms, independent sizes, rasterized ink, drag/stretch previews, live text, caret and window placement.")
        } catch {
            let message = (error as? Failure)?.message ?? String(describing: error)
            FileHandle.standardError.write(Data("Native interaction regression failed: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func checkTextFixtures(_ decoder: JSONDecoder, root: URL) throws {
        let fixtures = try decoder.decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("native/Tests/GraphiSchemaTests/Fixtures/text_layout.json")))
        for f in fixtures {
            try expect(DiagramTextLayout.lines(f.text, width: f.width, fontSize: f.fontSize, wrap: f.wrap) == f.expected,
                       "Shared line break fixture: \(f.text.debugDescription)")
        }
    }

    private static func project(_ starter: DiagramProject, icon: String? = nil, shape: String = "box", width: Double = 1, height: Double = 1) -> DiagramProject {
        var result = starter
        var node = starter.nodes[0]
        node.id = "figure"; node.icon = icon; node.shape = shape; node.containerId = nil
        node.label = "X"; node.labelAlignment = "center"; node.labelVerticalAlignment = "middle"; node.labelWrap = false
        node.x = 2; node.y = 2; node.width = width; node.height = height
        node.style.fill = "#00FF00"; node.style.stroke = "#FF0000"; node.style.text = "#FF0000"; node.style.penwidth = 1.5
        node.style.fontSize = 10
        result.nodes = [node]; result.containers = []; result.edges = []
        result.diagram.layoutMode = "manual"; result.presentation.theme = "light"; result.presentation.background = "#FFFFFF"
        return result
    }

    private static func layout(_ project: DiagramProject) -> DiagramLayout {
        // Deliberately stale coordinates and dimensions. The canvas must use the
        // current model during an edit, before a backend layout arrives.
        DiagramLayout(engine: "neato", edgeRouting: "angled", width: 8, height: 8, minX: 0, minY: 0,
                      nodes: project.nodes.map { LayoutNode(id: $0.id, x: 5, y: 5, width: 1, height: 1) }, edges: [])
    }

    private static func rect(_ node: DiagramNode, canvas: DiagramCanvasView) -> NSRect {
        let a = canvas.screenPoint(for: NSPoint(x: node.x!-node.width!/2, y: node.y!-node.height!/2))
        let b = canvas.screenPoint(for: NSPoint(x: node.x!+node.width!/2, y: node.y!+node.height!/2))
        return NSRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y)
    }

    private static func checkAllFigureContours(_ starter: DiagramProject) throws {
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        canvas.isGridVisible = false
        let figures: [(String?, String)] = CanvasGeometry.icons.keys.sorted().map { ($0, "box") }
            + ["box", "ellipse", "diamond", "hexagon", "cylinder", "cloud"].map { (nil, $0) }
        for (icon, shape) in figures {
            for (width, height) in [(0.5, 0.5), (3.0, 0.6), (0.7, 3.0)] {
                let p = project(starter, icon: icon, shape: shape, width: width, height: height)
                for zoom in [CGFloat(12), 72, 160, 300] {
                    canvas.update(diagram: p, layout: layout(p), selection: .project)
                    canvas.fitToContent(minimumScale: zoom, maximumScale: zoom)
                    let frame = rect(p.nodes[0], canvas: canvas)
                    let name = "\(icon ?? shape) \(width)×\(height) @\(zoom)"
                    for contour in CanvasGeometry.paths(p.nodes[0]) {
                        for (a, b) in zip(contour, contour.dropFirst()) {
                            let point = NSPoint(x: frame.minX+(a.x+b.x)/2*frame.width, y: frame.minY+(a.y+b.y)/2*frame.height)
                            try expect(canvas.nodeID(at: point) == "figure", "Visible contour missed: \(name), \(point)")
                        }
                    }
                    for point in [NSPoint(x: frame.midX, y: frame.minY-10), .init(x: frame.midX, y: frame.maxY+10),
                                  .init(x: frame.minX-10, y: frame.midY), .init(x: frame.maxX+10, y: frame.midY)] {
                        try expect(canvas.nodeID(at: point) == nil, "Invisible area selected: \(name), \(point)")
                    }
                    if icon == nil, shape == "box" {
                        try expect(canvas.nodeID(at: .init(x: frame.maxX+3, y: frame.midY)) == "figure", "Screen tolerance too small: \(name)")
                        try expect(canvas.nodeID(at: .init(x: frame.maxX+5, y: frame.midY)) == nil, "Screen tolerance changes with zoom: \(name)")
                    }
                }
            }
        }
    }

    private static func checkRasterizedInk(_ starter: DiagramProject) throws {
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        canvas.isGridVisible = false
        var cases = CanvasGeometry.icons.keys.sorted().map { ($0, project(starter, icon: $0, width: 1.6, height: 1.3)) }
        for horizontal in ["left", "center", "right"] {
            for vertical in ["top", "middle", "bottom"] {
                var p = project(starter, icon: "lucide/icons/activity.svg", width: 1.3, height: 1.3)
                p.nodes[0].label = "ab ab\njgjgjg"; p.nodes[0].labelWrap = true; p.nodes[0].style.fontSize = 18
                p.nodes[0].labelAlignment = horizontal; p.nodes[0].labelVerticalAlignment = vertical
                p.nodes[0].style.stroke = "#0000FF"; p.nodes[0].style.fill = "#00000000"
                cases.append(("wrapped label \(horizontal)/\(vertical)", p))
            }
        }
        for (icon, p) in cases {
            canvas.update(diagram: p, layout: layout(p), selection: .project)
            canvas.fitToContent(minimumScale: 72, maximumScale: 72)
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw Failure(message: "No bitmap for \(icon)") }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let frame = rect(p.nodes[0], canvas: canvas).insetBy(dx: -2, dy: -2)
            let sx = canvas.bounds.width/CGFloat(bitmap.pixelsWide), sy = canvas.bounds.height/CGFloat(bitmap.pixelsHigh)
            var inkCount = 0
            for y in stride(from: max(0, Int((canvas.bounds.maxY-frame.maxY)/sy)), to: min(bitmap.pixelsHigh, Int((canvas.bounds.maxY-frame.minY)/sy)+1), by: 2) {
                for x in stride(from: max(0, Int(frame.minX/sx)), to: min(bitmap.pixelsWide, Int(frame.maxX/sx)+1), by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent > 0.7,
                          color.greenComponent < 0.35, color.blueComponent < 0.35 else { continue }
                    let point = NSPoint(x: canvas.bounds.minX+(CGFloat(x)+0.5)*sx, y: canvas.bounds.maxY-(CGFloat(y)+0.5)*sy)
                    inkCount += 1
                    if canvas.nodeID(at: point) != "figure" {
                        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/interaction-debug")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("failure.png"))
                        throw Failure(message: "Actual painted pixel is not clickable: \(icon), \(point), frame=\(frame), glyphBounds=\(NodeLabelLayout(node: p.nodes[0], in: rect(p.nodes[0], canvas: canvas), scale: 72).visibleGlyphBounds), bitmap=\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
                    }
                    try expect(true, "Painted pixel")
                }
            }
            try expect(inkCount > 5, "Raster observation has no usable ink: \(icon)")
        }
    }

    private static func event(_ type: NSEvent.EventType, point: NSPoint, canvas: DiagramCanvasView, window: NSWindow) throws -> NSEvent {
        guard let value = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure(message: "No mouse event") }
        return value
    }

    private static func checkLiveMoveAndStretch(_ starter: DiagramProject) throws {
        var p = project(starter, icon: "tabler-icons/outline/shield.svg", width: 1, height: 1)
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        canvas.update(diagram: p, layout: layout(p), selection: .project)
        canvas.fitToContent(minimumScale: 72, maximumScale: 72)
        let center = canvas.screenPoint(for: .init(x: 2, y: 2))
        var selected: DiagramSelection?
        canvas.onSelect = { selected = $0 }
        canvas.mouseDown(with: try event(.leftMouseDown, point: .init(x: center.x, y: center.y-50), canvas: canvas, window: window))
        canvas.mouseUp(with: try event(.leftMouseUp, point: .init(x: center.x, y: center.y-50), canvas: canvas, window: window))
        try expect(selected == .project, "Click below the figure must not use the old external label target.")
        canvas.mouseDown(with: try event(.leftMouseDown, point: center, canvas: canvas, window: window))
        try expect(selected == .node("figure"), "Real mouse click misses visual center.")
        let destination = NSPoint(x: center.x+150, y: center.y+90)
        canvas.mouseDragged(with: try event(.leftMouseDragged, point: destination, canvas: canvas, window: window))
        try expect(canvas.nodeID(at: destination) == "figure" && canvas.nodeID(at: center) == nil, "Drag hit area must move with its preview.")
        var moved: NSPoint?
        canvas.onMoveNode = { _, x, y, _ in moved = .init(x: x, y: y) }
        canvas.mouseUp(with: try event(.leftMouseUp, point: destination, canvas: canvas, window: window))
        guard let moved else { throw Failure(message: "Drag did not commit") }
        p.nodes[0].x = moved.x; p.nodes[0].y = moved.y
        p.nodes[0].icon = nil
        canvas.update(diagram: p, layout: layout(p), selection: .node("figure"))
        guard let handle = canvas.nodeStretchFrames(for: "figure").first(where: { $0.direction == .init(x: 1, y: 0) }) else { throw Failure(message: "No stretch handle") }
        let start = NSPoint(x: handle.frame.midX, y: handle.frame.midY), end = NSPoint(x: handle.frame.midX+110, y: handle.frame.midY)
        canvas.mouseDown(with: try event(.leftMouseDown, point: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: try event(.leftMouseDragged, point: end, canvas: canvas, window: window))
        try expect(canvas.nodeID(at: .init(x: end.x-5, y: end.y)) == "figure", "Stretch preview must expand the hit area.")
        try expect(canvas.nodeID(at: .init(x: end.x+8, y: end.y)) == nil, "Stretch preview must keep a screen-sized hit tolerance.")
        canvas.mouseUp(with: try event(.leftMouseUp, point: end, canvas: canvas, window: window))
    }

    private static func find<T: NSView>(_ identifier: String, in view: NSView) -> T? {
        if view.identifier?.rawValue == identifier { return view as? T }
        for child in view.subviews { if let found: T = find(identifier, in: child) { return found } }
        return nil
    }
    private static func perform(_ control: NSControl) {
        if let action = control.action { _ = NSApp.sendAction(action, to: control.target, from: control) }
    }

    private static func checkTextWindow(_ starter: DiagramProject) throws {
        var node = project(starter).nodes[0]
        var callbacks = 0
        var controller: NodeTextEditorWindowController!
        controller = NodeTextEditorWindowController(node: node) { label, h, v, size, wrap in
            callbacks += 1; node.label = label; node.labelAlignment = h; node.labelVerticalAlignment = v
            node.style.fontSize = size; node.labelWrap = wrap
            controller.refresh(node: node, editingLocked: false)
        }
        defer { controller.close() }
        guard let content = controller.window?.contentView,
              let text: NSTextView = find("node-text-value", in: content),
              let font: NSTextField = find("node-text-font-size", in: content),
              let wrap: NSButton = find("node-text-wrap", in: content),
              let horizontal: NSPopUpButton = find("node-text-horizontal", in: content),
              let vertical: NSPopUpButton = find("node-text-vertical", in: content) else { throw Failure(message: "No live text controls") }
        controller.window?.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        guard let done: NSButton = find("node-text-done", in: content),
              let scroll: NSScrollView = find("node-text-scroll", in: content) else { throw Failure(message: "No text layout controls") }
        try expect(font.frame.height >= 18 && horizontal.frame.height >= 18 && vertical.frame.height >= 18 && scroll.frame.height >= 86
                   && content.bounds.contains(done.convert(done.bounds, to: content)),
                   "Text window compresses or clips its controls: font=\(font.frame), horizontal=\(horizontal.frame), vertical=\(vertical.frame), done=\(done.convert(done.bounds, to: content)), content=\(content.bounds)")
        text.string = "New\nmanual line"; text.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
        try expect(node.label == text.string && callbacks == 1 && text.selectedRange().location == 4, "Typing must apply immediately and preserve the caret.")
        controller.showNearCursor(nil); controller.window?.makeFirstResponder(font)
        guard let fontEditor = font.currentEditor() as? NSTextView else { throw Failure(message: "No live font field editor") }
        fontEditor.string = "18,5"; fontEditor.didChangeText()
        try expect(node.style.effectiveFontSize == 18.5 && callbacks == 2, "Font changes must apply without Save.")
        wrap.state = .on; perform(wrap)
        horizontal.selectItem(at: 0); perform(horizontal)
        vertical.selectItem(at: 2); perform(vertical)
        try expect(node.effectiveLabelWrap && node.effectiveLabelAlignment == "left" && node.effectiveLabelVerticalAlignment == "bottom", "Text parameters must update live.")
        font.stringValue = ""; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: font))
        try expect(node.style.effectiveFontSize == 18.5, "Incomplete font input must preserve the last valid size.")
        controller.refresh(node: node, editingLocked: true)
        text.string = "Locked change"; controller.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
        try expect(node.label != "Locked change", "Locked text changes must not apply.")
        node.label = "👨‍👩‍👧‍👦"
        let emoji = NodeLabelLayout(node: node, in: .init(x: 0, y: 0, width: 120, height: 120), scale: 72)
        try expect(!emoji.visibleGlyphBounds.isEmpty, "Bitmap emoji labels must retain a clickable region.")
    }

    private static func checkInspectorTyping(_ starter: DiagramProject) throws {
        let model = AppModel(); model.diagram = project(starter); model.layout = layout(model.diagram!)
        model.jsonDraft = model.prettyJSON(model.diagram!); model.selection = .node("figure")
        let main = MainWindowController(model: model); main.refreshAll(); main.showStyleWindow()
        defer { NSApp.windows.filter { $0 !== main.window }.forEach { $0.orderOut(nil) }; main.close() }
        guard let style = NSApp.windows.first(where: { $0.title == "Оформление и свойства" }), let content = style.contentView,
              let name: NSTextField = find("inspector-field-Название", in: content),
              let font: NSTextField = find("inspector-field-Размер текста, pt", in: content),
              let wrap: NSButton = find("inspector-field-Перенос строк", in: content) else { throw Failure(message: "No inspector text controls") }
        style.makeKeyAndOrderFront(nil); style.makeFirstResponder(name)
        guard let editor = name.currentEditor() as? NSTextView else { throw Failure(message: "No inspector field editor") }
        editor.string = "Live typing"; editor.setSelectedRange(NSRange(location: 5, length: 0)); editor.didChangeText()
        let sameName: NSTextField? = find("inspector-field-Название", in: content)
        try expect(model.nodes[0].label == "Live typing" && sameName === name && name.currentEditor() === editor && editor.selectedRange().location == 5,
                   "Model refresh must preserve inspector input, field identity and caret: model=\(model.nodes[0].label), editor=\(editor.string), field=\(name.stringValue), sameField=\(sameName === name), sameEditor=\(name.currentEditor() === editor), caret=\(editor.selectedRange()), firstResponder=\(String(describing: style.firstResponder)), locked=\(model.isEditingLocked)")
        style.makeFirstResponder(font)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        guard let fontEditor = font.currentEditor() as? NSTextView else { throw Failure(message: "Changing fields lost font focus") }
        fontEditor.string = "22,5"; fontEditor.didChangeText()
        try expect(model.nodes[0].style.effectiveFontSize == 22.5, "Inspector font must apply during typing.")
        style.makeFirstResponder(nil); wrap.state = .on; perform(wrap)
        try expect(model.nodes[0].effectiveLabelWrap, "Inspector wrap checkbox must update the live model.")
    }

    private static func checkWindowPlacement() throws {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 878), NSRect(x: -1920, y: -200, width: 1920, height: 1058)] {
            for size in [NSSize(width: 360, height: 500), NSSize(width: 830, height: 620)] {
                for cursor in [NSPoint(x: screen.midX, y: screen.midY), .init(x: screen.minX+5, y: screen.maxY-5),
                               .init(x: screen.maxX-5, y: screen.minY+5), .init(x: screen.minX+5, y: screen.minY+5),
                               .init(x: screen.maxX-5, y: screen.maxY-5)] {
                    let origin = SettingsWindowPlacement.origin(size: size, cursor: cursor, visibleFrame: screen)
                    try expect(screen.contains(NSRect(origin: origin, size: size)), "Settings window must remain on its screen, including negative screen coordinates.")
                }
            }
        }
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080), cursor = NSPoint(x: 500, y: 800)
        let origin = SettingsWindowPlacement.origin(size: .init(width: 360, height: 500), cursor: cursor, visibleFrame: screen)
        try expect(origin == .init(x: 512, y: 288), "Window must open 12 points beside the cursor, not at the screen center.")
        guard let visible = NSScreen.main?.visibleFrame else {
            throw Failure(message: "WindowServer access is required to verify real settings window placement.")
        }
        do {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let controller = NSWindowController(window: window)
            defer { controller.close() }
            let pointer = NSPoint(x: visible.midX, y: visible.maxY-80)
            let expected = SettingsWindowPlacement.origin(size: window.frame.size, cursor: pointer, visibleFrame: visible)
            controller.showNearCursor(nil, near: pointer)
            try expect(window.frame.origin == expected, "Showing a real window must preserve cursor placement.")
            window.setFrameOrigin(.zero)
            controller.showNearCursor(nil, near: pointer)
            try expect(window.frame.origin == expected, "Reopening an existing settings window must position it by the current cursor.")
        }
    }
}
