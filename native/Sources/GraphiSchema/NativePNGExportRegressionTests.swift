import AppKit
import Darwin

/// Exercises the real export window and rasterizer with an unregistered, isolated draft.
@MainActor
enum NativePNGExportRegressionTests {
    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private static var checks = 0
    private static func expect(_ condition: Bool,_ message: String) throws {
        checks += 1
        if !condition { throw Failure(message) }
    }
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        Task { @MainActor in
            let backend = BackendService()
            do {
                try await checkWindow(backend)
                backend.stop()
                print("PNG export regressions passed: \(checks) checks.")
                exit(0)
            } catch {
                backend.stop()
                FileHandle.standardError.write(Data("PNG export regression failed after \(checks) checks: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
    private static func find<T: NSView>(_ id: String,in view: NSView) -> T? {
        if view.identifier?.rawValue == id { return view as? T }
        for child in view.subviews { if let match: T = find(id,in: child) { return match } }
        return nil
    }
    private static func pixels(_ data: Data) throws -> Data {
        guard let bitmap = NSBitmapImageRep(data: data),let image = bitmap.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure("Cannot read PNG pixels") }
        context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        guard let pointer = context.data else { throw Failure("Missing PNG pixels") }
        return Data(bytes: pointer,count: image.width*image.height*4)
    }
    private static func checkWindow(_ backend: BackendService) async throws {
        let model = AppModel(backend: backend,blankCanvas: true); await model.bootstrap()
        try expect(backend.isReady && model.diagram != nil,"Isolated backend must start: \(backend.status)")
        let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var project = try decoder.decode(DiagramProject.self,from: Data(contentsOf: rootURL.appendingPathComponent("examples/starter.json")))
        project.project = model.diagram!.project; project.containers = []; project.diagram.layoutMode = "manual"
        project.nodes = Array(project.nodes.prefix(2))
        for i in project.nodes.indices {
            project.nodes[i].containerId = nil; project.nodes[i].x = Double(i)*4; project.nodes[i].y = 0
            project.nodes[i].icon = nil; project.nodes[i].shape = "box"; project.nodes[i].width = 2; project.nodes[i].height = 1.2
        }
        project.edges = [project.edges[0]]; project.edges[0].source = project.nodes[0].id; project.edges[0].target = project.nodes[1].id
        project.groups = [ObjectGroup(id: "export_group",label: "PNG group",nodeIds: project.nodes.map(\.id))]
        project.presentation.legendMode = "auto"; project.presentation.theme = "light"
        if let path = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_PNG_TEST_FIXTURE"] {
            let info = project.project
            project = try decoder.decode(DiagramProject.self,from: Data(contentsOf: URL(fileURLWithPath: path)))
            project.project = info
        }
        model.diagram = project
        let storageBefore = try await model.fetchStorageInfo()
        let window = PNGExportWindowController(model: model) { _ in }
        defer { window.close() }
        window.showWindow(nil)
        guard let root = window.window?.contentView,
              let save: NSButton = find("png-export-save",in: root),
              let status: NSTextField = find("png-export-status",in: root),
              let preview: NSImageView = find("png-export-preview",in: root),
              let legend: NSButton = find("png-export-legend",in: root),
              let groups: NSButton = find("png-export-groups",in: root),
              let proportional: NSButton = find("png-export-proportional",in: root),
              let height: NSTextField = find("png-export-height",in: root),
              let dpi: NSTextField = find("png-export-dpi",in: root),
              let background: NSPopUpButton = find("png-export-background",in: root),
              let fitButton: NSButton = find("png-export-fit",in: root),
              let width: NSTextField = find("png-export-width",in: root) else { throw Failure("PNG controls must be accessible") }
        width.stringValue = "800"
        func waitForImage() async throws -> Data {
            for _ in 0..<200 {
                if save.isEnabled,let data = preview.image?.tiffRepresentation { return data }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure("PNG save must enable after rendering; size=\(width.stringValue)×\(height.stringValue), live=\(width.currentEditor()?.string ?? "none")/\(height.currentEditor()?.string ?? "none"); status: \(status.stringValue)")
        }
        func toggle(_ button: NSButton) throws {
            guard let action = button.action else { throw Failure("Missing PNG action") }
            button.state = button.state == .on ? .off : .on
            try expect(NSApp.sendAction(action,to: button.target,from: button),"PNG option must invoke its render action")
            try expect(!save.isEnabled,"Stale PNG must not be saved while preparing changed options")
        }
        window.reloadSnapshot()
        let withLegend = try await waitForImage()
        try expect(save.isEnabled,"Initial PNG must be exportable")
        root.layoutSubtreeIfNeeded()
        for button in [save,legend,groups] {
            let point = button.convert(NSPoint(x: button.bounds.midX,y: button.bounds.midY),to: root)
            let hit = root.hitTest(point)
            try expect(hit === button || hit?.isDescendant(of: button) == true,"PNG controls must receive clicks: \(button.title)")
        }
        try toggle(legend)
        let plain = try await waitForImage()
        try expect(plain != withLegend,"Legend toggle must update actual PNG pixels")
        try toggle(groups)
        let grouped = try await waitForImage()
        try expect(grouped != plain,"Group frame toggle must update actual PNG pixels")
        try toggle(groups); try toggle(legend)
        let restored = try await waitForImage()
        try expect(restored == withLegend,"Rapid changes must render the latest options, without stale results")
        func edit(_ field: NSTextField,_ value: String) {
            field.stringValue = value
            window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,object: field))
        }
        func waitForInvalidPreview() async throws -> Data {
            for _ in 0..<200 {
                if !save.isEnabled,status.textColor == .systemRed,let data = preview.image?.tiffRepresentation { return data }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure("An incomplete number must not freeze the latest preview: \(status.stringValue)")
        }
        edit(width,"invalid"); try toggle(legend)
        let incomplete = try await waitForInvalidPreview()
        try expect(incomplete != restored && status.stringValue.contains("Размер PNG"),"Legend must refresh despite an invalid output size, with a visible validation error")
        do { _ = try await window.preparedPNGData(); throw Failure("Invalid settings unexpectedly exported") }
        catch is Failure { throw Failure("Invalid settings unexpectedly exported") } catch { checks += 1 }
        edit(width,"800"); _ = try await waitForImage()
        edit(dpi,"0"); try toggle(groups)
        _ = try await waitForInvalidPreview()
        try expect(status.stringValue.contains("DPI"),"Invalid DPI must explain disabled saving while keeping the current preview")
        edit(dpi,"300"); _ = try await waitForImage()
        try toggle(proportional)
        edit(width,"1200"); edit(height,"700")
        let finalPreview = try await waitForImage()
        let output = try await window.preparedPNGData()
        guard let bitmap = NSBitmapImageRep(data: output) else { throw Failure("Final PNG must decode") }
        try expect(bitmap.pixelsWide == 1200 && bitmap.pixelsHigh == 700,"The final file must have exactly the requested dimensions")
        try expect(abs(bitmap.size.width-Double(1200)*72/300)<1,"DPI must be written into PNG metadata")
        try expect(try pixels(output) == pixels(finalPreview),"Full export must use the same project, legend and groups as the preview")
        save.performClick(nil)
        for _ in 0..<100 {
            if window.window?.attachedSheet is NSSavePanel { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let panel = window.window?.attachedSheet as? NSSavePanel else { throw Failure("Enabled PNG save button must open the save dialog") }
        try expect(!save.isEnabled && !legend.isEnabled,"Export controls must remain fixed while saving")
        panel.cancel(nil)
        for _ in 0..<100 {
            if save.isEnabled { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect(save.isEnabled && legend.isEnabled,"Cancelling the save dialog must permit retrying")
        background.selectItem(at: 2)
        guard let action = background.action else { throw Failure("Missing background action") }
        _ = NSApp.sendAction(action,to: background.target,from: background)
        _ = try await waitForImage()
        let transparent = try await window.preparedPNGData()
        guard let transparentBitmap = NSBitmapImageRep(data: transparent) else { throw Failure("Transparent PNG must decode") }
        try expect(transparentBitmap.colorAt(x: 0,y: 0)?.alphaComponent == 0,"Transparent background must reach the actual exported pixels")
        edit(width,"8192"); edit(height,"8192"); try toggle(groups)
        let largePreview = try await waitForImage()
        try expect(save.isEnabled && status.stringValue.contains("Сглаживание 1×"),"A large PNG must retain its output resolution and automatically reduce oversampling instead of disabling export")
        let largeBitmap = NSBitmapImageRep(data: largePreview)
        try expect((largeBitmap?.pixelsWide ?? Int.max)<=1200 && (largeBitmap?.pixelsHigh ?? Int.max)<=900,"A 64 megapixel output must not build a full-size raster merely to update its preview")
        edit(width,"16384"); edit(height,"16384")
        _ = try await waitForInvalidPreview()
        try expect(!save.isEnabled && status.stringValue.contains("мегапиксел"),"Invalid output memory size must explain disabled saving without freezing group options")
        fitButton.performClick(nil); _ = try await waitForImage()
        try expect(width.integerValue*height.integerValue<=PNGExportSizing.maximumPixels && save.isEnabled,"Fit size must recover a valid large export without changing its aspect ratio")
        for (w,h) in [(2048.0,40000.0),(60000.0,2048.0),(16384.0,16384.0),(8192.0,8192.0)] {
            guard let fitted = PNGExportSizing.fit(width: w,height: h) else { throw Failure("Large PNG dimensions must fit") }
            try expect((64...16384).contains(fitted.width) && (64...16384).contains(fitted.height) && fitted.width*fitted.height<=PNGExportSizing.maximumPixels,"Automatic dimensions must satisfy pixel and memory bounds")
            try expect(abs(Double(fitted.width)/Double(fitted.height)/(w/h)-1)<0.01,"Large landscape and portrait PNG dimensions must preserve proportions")
        }
        try expect(PNGExportSizing.samples(width: 2048,height: 1536,highQuality: true) == 2 && PNGExportSizing.samples(width: 8192,height: 8192,highQuality: true) == 1,"Oversampling must adapt to output size")
        edit(width,"16384"); edit(height,"64"); _ = try await waitForImage()
        let widePNG = try await window.preparedPNGData()
        let wideBitmap = NSBitmapImageRep(data: widePNG)
        try expect(wideBitmap?.pixelsWide == 16384 && wideBitmap?.pixelsHigh == 64,"Actual PNG output must support a 16384-pixel side with adaptive 1× encoding")
        edit(width,"800"); edit(height,"600"); _ = try await waitForImage()
        window.reloadSnapshot(); try toggle(legend)
        _ = try await waitForImage()
        try expect(save.isEnabled,"Changes during snapshot reload must be rendered and recover saving")
        window.close(); window.showWindow(nil); window.reloadSnapshot()
        _ = try await waitForImage()
        try expect(save.isEnabled,"Closing and reopening the PNG window must cancel old tasks and permit a fresh export")
        backend.stop()
        try await Task.sleep(for: .milliseconds(400))
        try toggle(legend)
        for _ in 0..<200 {
            if status.textColor == .systemRed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect(!save.isEnabled && preview.image == nil && status.textColor == .systemRed,"A render failure must remove the stale image and explain disabled saving")
        await backend.start(); window.reloadSnapshot()
        _ = try await waitForImage()
        try expect(save.isEnabled,"Retrying after a render failure must recover PNG export")
        let folder = rootURL.appendingPathComponent("dist/quality/png-export")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        try output.write(to: folder.appendingPathComponent("full-resolution-300dpi.png"))
        try transparent.write(to: folder.appendingPathComponent("transparent.png"))
        root.layoutSubtreeIfNeeded()
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds,to: bitmap)
            if let image = bitmap.cgImage,let space = CGColorSpace(name: CGColorSpace.sRGB),
               let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.setFillColor(NSColor(hex: "#F5F7FA").cgColor)
                context.fill(CGRect(x: 0,y: 0,width: image.width,height: image.height))
                context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
                if let composed = context.makeImage() {
                    try NSBitmapImageRep(cgImage: composed).representation(using: .png,properties: [:])?.write(to: folder.appendingPathComponent("export-window.png"))
                }
            }
        }
        let expectedPNG = try await window.preparedPNGData()
        let destination = folder.appendingPathComponent("saved.png")
        try expectedPNG.write(to: destination,options: .atomic)
        try expect(try Data(contentsOf: destination) == expectedPNG,"Saved PNG must preserve the preview's immutable configuration")
        let storageAfter = try await model.fetchStorageInfo()
        try expect(model.diagram == project && model.isTransientProject && storageBefore.projectCount == storageAfter.projectCount && storageBefore.versionCount == storageAfter.versionCount,
                   "Preview options must not modify the diagram, register a draft, or create versions")
        // A very tall canvas used to create an invalid automatic height and leave
        // the export button disabled even with untouched default size fields.
        var tall = project
        tall.containers = []; tall.groups = []; tall.edges = []
        tall.nodes = Array(tall.nodes.prefix(2))
        for i in tall.nodes.indices { tall.nodes[i].containerId = nil; tall.nodes[i].x = 0; tall.nodes[i].y = Double(i)*80 }
        model.diagram = tall
        proportional.state = .on; width.stringValue = "2048"
        window.reloadSnapshot(); _ = try await waitForImage()
        try expect(height.integerValue<=16384 && width.integerValue*height.integerValue<=PNGExportSizing.maximumPixels && save.isEnabled,"Opening PNG on a very tall diagram must automatically fit dimensions and allow export")
    }
}
