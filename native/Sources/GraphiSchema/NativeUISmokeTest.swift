import AppKit
import Darwin

@MainActor
enum NativeUISmokeTest {
    private static var restorePreferences: (() -> Void)?
    static func run() {
        _ = NSApplication.shared
        let preferencesBackup = UserDefaults.standard.object(forKey: "GraphiSchema.ollama.preferences")
        let navigationBackup = UserDefaults.standard.object(forKey: "GraphiSchema.inverseTrackpad")
        restorePreferences = {
            UserDefaults.standard.set(preferencesBackup, forKey: "GraphiSchema.ollama.preferences")
            UserDefaults.standard.set(navigationBackup, forKey: "GraphiSchema.inverseTrackpad")
        }
        defer { restorePreferences?(); restorePreferences = nil }
        let model = AppModel()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("GraphiSchema/examples/starter.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples/starter.json"),
        ].compactMap { $0 }
        guard let starterData = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            fail("Native UI smoke test cannot load examples/starter.json.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let starter = try? decoder.decode(DiagramProject.self, from: starterData) else {
            fail("Native UI smoke test cannot decode the starter project.")
        }
        model.diagram = starter
        model.jsonDraft = model.prettyJSON(starter)
        var localEdit = starter
        localEdit.nodes[0].label = "Изменение из текущего окна"
        var otherWindowEdit = starter
        otherWindowEdit.nodes[0].style.stroke = "#AA3377"
        guard let merged = model.mergeProject(base: model.prettyJSON(starter), local: localEdit, remote: otherWindowEdit),
              merged.nodes[0].label == localEdit.nodes[0].label,
              merged.nodes[0].style.stroke == otherWindowEdit.nodes[0].style.stroke
        else { fail("Native UI smoke test failed: independent concurrent edits must merge.") }
        var sameFieldEdit = otherWindowEdit
        sameFieldEdit.nodes[0].label = "Конкурирующее изменение"
        guard model.mergeProject(base: model.prettyJSON(starter), local: localEdit, remote: sameFieldEdit) == nil else {
            fail("Native UI smoke test failed: conflicting edits to one field must be rejected safely.")
        }
        let mainWindow = MainWindowController(model: model)
        model.selection = .node("waf")
        mainWindow.refreshAll()
        model.selection = .container("dmz")
        mainWindow.refreshAll()
        model.selection = .edge(starter.edges.first?.id ?? "")
        mainWindow.refreshAll()
        let assistantWindow = OllamaAssistantWindowController(model: model)
        mainWindow.showWindow(nil)

        let initialNodeCount = model.nodes.count
        model.updateJSONDraft("{}")
        model.addNode(kind: "gateway")
        guard model.isEditingLocked, model.nodes.count == initialNodeCount else {
            fail("Native UI smoke test failed: editing must pause while a JSON draft is unapplied.")
        }
        model.discardJSONDraft()

        guard let root = mainWindow.window?.contentView,
              let editorSplit = findEditorSplit(in: root),
              editorSplit.arrangedSubviews.count == 3
        else {
            fail("Native UI smoke test failed: expected palette, canvas, and JSON panels.")
        }
        root.layoutSubtreeIfNeeded()
        editorSplit.layoutSubtreeIfNeeded()
        mainWindow.window?.displayIfNeeded()
        editorSplit.displayIfNeeded()
        let hasJSONCode = findTextView(containing: "schema_version", in: root) != nil
        let hasPalette = findView(identifier: "diagram-palette", in: root) != nil
        let paletteScroll = findView(identifier: "palette-scroll", in: root) as? NSScrollView
        let firstPaletteTile = findView(identifier: "palette-item-template:service", in: root)
        let collectionPicker = findView(identifier: "palette-collection-picker", in: root) as? NSPopUpButton
        let hasAllPaletteItems = PaletteItem.allCases.allSatisfy {
            findView(identifier: "palette-item-template:\($0.rawValue)", in: root) != nil
        }
        let tablerCollection = PaletteLibrary.collection(id: "tabler")
        let lucideCollection = PaletteLibrary.collection(id: "lucide")
        let hasBundledPaletteIcons = PaletteLibrary.allObjects.allSatisfy { $0.loadIcon() != nil }
        let hasChat = findView(identifier: "ollama-chat-panel", in: root) != nil
        guard editorSplit.arrangedSubviews[0].frame.width >= 220,
              editorSplit.arrangedSubviews[1].frame.width >= 580,
              editorSplit.arrangedSubviews[2].frame.width >= 370,
              hasPalette,
              (paletteScroll?.contentView.bounds.width ?? 0) >= 200,
              (paletteScroll?.contentView.bounds.height ?? 0) >= 400,
              (firstPaletteTile?.frame.width ?? 0) >= 180,
              collectionPicker != nil,
              collectionPicker?.itemArray.count == PaletteLibrary.collections.count,
              PaletteLibrary.collections.count == 4,
              tablerCollection?.objects.count ?? 0 >= 20,
              lucideCollection?.objects.count ?? 0 >= 15,
              PaletteLibrary.allObjects.count >= 50,
              hasAllPaletteItems,
              hasBundledPaletteIcons,
              hasChat,
              hasJSONCode
        else {
            fail("Native UI smoke test failed: palette, readable JSON, chat, and panel widths must be visible.")
        }
        if let collectionPicker,
           let tabler = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == "tabler" }) {
            collectionPicker.select(tabler)
            _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
            let tablerItemsVisible = (tablerCollection?.objects ?? []).allSatisfy {
                findView(identifier: "palette-item-\($0.id)", in: root) != nil
            }
            let tablerContainsLoadedSVGs = (tablerCollection?.objects ?? []).contains { $0.id.hasPrefix("svg:tabler:") }
            let lucideItemsHidden = (lucideCollection?.objects ?? []).allSatisfy {
                findView(identifier: "palette-item-\($0.id)", in: root) == nil
            }
            guard tablerItemsVisible, tablerContainsLoadedSVGs, lucideItemsHidden else {
                fail("Native UI smoke test failed: selecting a collection must load all included SVG objects and filter other collections.")
            }
            if let all = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == "all" }) {
                collectionPicker.select(all)
                _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
                for _ in 0..<12 {
                    collectionPicker.select(tabler)
                    _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
                    collectionPicker.select(all)
                    _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
                }
                guard let reusedTile = findView(identifier: "palette-item-template:service", in: root),
                      reusedTile === firstPaletteTile,
                      let column = reusedTile.superview,
                      column.constraints.filter({
                          $0.isActive && $0.firstAttribute == .width && $0.relation == .equal
                              && ($0.firstItem as? NSView) === reusedTile && ($0.secondItem as? NSView) === column
                      }).count == 1
                else {
                    fail("Native UI smoke test failed: repeated collection switches must reuse tiles without accumulating width constraints.")
                }
            }
        }
        model.selection = .node("waf")
        mainWindow.showStyleWindow()
        assistantWindow.showWindow(nil)
        assistantWindow.window?.contentView?.layoutSubtreeIfNeeded()
        guard (assistantWindow.window?.frame.width ?? 0) >= 560,
              (findView(identifier: "ollama-system-prompt", in: assistantWindow.window?.contentView ?? NSView())?.frame.width ?? 0) >= 400
        else {
            fail("Native UI smoke test failed: Ollama fields need usable width and padding.")
        }
        let styleContent = NSApp.windows.first(where: { $0.title == "Оформление и свойства" })?.contentView ?? NSView()
        styleContent.layoutSubtreeIfNeeded()
        let styleWindow = NSApp.windows.first(where: { $0.title == "Оформление и свойства" })
        styleWindow?.layoutIfNeeded()
        styleWindow?.displayIfNeeded()
        let nameField = findView(identifier: "inspector-field-Название", in: styleContent) as? NSTextField
        let fillWell = findView(identifier: "inspector-field-Заливка", in: styleContent) as? NSColorWell
        let borderWell = findView(identifier: "inspector-field-Граница", in: styleContent) as? NSColorWell
        let propertiesScroll = findView(identifier: "inspector-properties-scroll", in: styleContent) as? NSScrollView
        let nodePropertiesHeight = styleContent.frame.height
        guard styleWindow?.isVisible == true,
              styleWindow?.frame.width ?? 0 >= 440,
              styleWindow?.frame.height ?? 700 < 650,
              nameField?.isEnabled == true,
              (nameField?.frame.width ?? 0) >= 180,
              (fillWell?.frame.width ?? 0) >= 180,
              (borderWell?.frame.width ?? 0) >= 180,
              (propertiesScroll?.contentView.bounds.width ?? 0) >= 400,
              (propertiesScroll?.contentView.bounds.height ?? 0) >= 300
        else {
            fail("Native UI smoke test failed: unusable style layout (visible=\(styleWindow?.isVisible ?? false), window=\(styleWindow?.frame ?? .zero), content=\(styleContent.frame)/\(styleContent.bounds), name=\(nameField?.frame ?? .zero), enabled=\(nameField?.isEnabled ?? false), fill=\(fillWell?.frame ?? .zero), border=\(borderWell?.frame ?? .zero), scrollFrame=\(propertiesScroll?.frame ?? .zero), scroll=\(propertiesScroll?.contentView.bounds ?? .zero)).")
        }
        model.selection = .project
        mainWindow.refreshAll()
        let projectPropertiesHeight = styleWindow?.contentView?.frame.height ?? 0
        guard let routingPicker = findView(identifier: "inspector-field-Маршрут связей", in: styleContent) as? NSPopUpButton,
              Set(routingPicker.itemArray.compactMap { $0.representedObject as? String }) == Set(["straight", "angled", "orthogonal"]),
              projectPropertiesHeight >= 280,
              projectPropertiesHeight < nodePropertiesHeight
        else {
            fail("Native UI smoke test failed: project properties must offer straight, angled, and orthogonal edge routes.")
        }
        let originalRouting = model.diagram?.diagram.edgeRouting ?? "angled"
        if let orthogonal = routingPicker.itemArray.first(where: { ($0.representedObject as? String) == "orthogonal" }),
           let routingAction = routingPicker.action {
            routingPicker.select(orthogonal)
            _ = NSApp.sendAction(routingAction, to: routingPicker.target, from: routingPicker)
            guard model.diagram?.diagram.edgeRouting == "orthogonal", model.jsonDraft.contains("orthogonal") else {
                fail("Native UI smoke test failed: routing actions must update the project and synchronized JSON.")
            }
            model.updateEdgeRouting(originalRouting)
        }
        model.selection = .edge(starter.edges.first?.id ?? "")
        mainWindow.refreshAll()
        guard findView(identifier: "inspector-field-Маршрут этой связи", in: styleContent) is NSPopUpButton else {
            fail("Native UI smoke test failed: selected edge properties must expose their own routing setting.")
        }
        model.selection = .node("waf")
        mainWindow.refreshAll()
        if let nameField = findView(identifier: "inspector-field-Название", in: styleContent) as? NSTextField,
           let action = nameField.action {
            let oldName = model.nodes.first(where: { $0.id == "waf" })?.label ?? "WAF"
            nameField.stringValue = "Inspector smoke edit"
            _ = NSApp.sendAction(action, to: nameField.target, from: nameField)
            guard model.nodes.first(where: { $0.id == "waf" })?.label == "Inspector smoke edit" else {
                fail("Native UI smoke test failed: changing a property must update the selected object.")
            }
            model.editNode("waf") { $0.label = oldName }
            mainWindow.refreshAll()
            guard let borderControl = findView(identifier: "inspector-field-Граница", in: styleContent) as? NSColorWell,
                  let borderAction = borderControl.action
            else { fail("Native UI smoke test failed: border color control must be available after a property refresh.") }
            let oldStroke = model.nodes.first(where: { $0.id == "waf" })?.style.stroke ?? "#000000"
            borderControl.color = NSColor(hex: "#AA3377")
            let editedStroke = borderControl.color.hexRGB
            let borderActionHandled = NSApp.sendAction(borderAction, to: borderControl.target, from: borderControl)
            guard model.nodes.first(where: { $0.id == "waf" })?.style.stroke == editedStroke else {
                fail("Native UI smoke test failed: color action handled=\(borderActionHandled), enabled=\(borderControl.isEnabled), resulting stroke=\(model.nodes.first(where: { $0.id == "waf" })?.style.stroke ?? "missing").")
            }
            model.editNode("waf") { $0.style.stroke = oldStroke }
            mainWindow.refreshAll()
        } else {
            fail("Native UI smoke test failed: selected object name must have an active edit action.")
        }
        guard findView(identifier: "palette-item-template:service", in: root) === firstPaletteTile else {
            fail("Native UI smoke test failed: changing diagram properties must preserve palette views.")
        }

        let historyWindow = VersionHistoryWindowController(model: model, onRestore: {}, onShowDiff: { _ in })
        historyWindow.update([
            ProjectVersion(id: 2, projectId: "smoke", title: "Последняя версия", revision: "aabbccdd", createdAt: "2026-10-13T12:00:00Z"),
            ProjectVersion(id: 1, projectId: "smoke", title: "Начальная версия", revision: "11223344", createdAt: "2026-10-13T11:00:00Z"),
        ])
        historyWindow.showWindow(nil)
        guard let historyContent = historyWindow.window?.contentView,
              let historyTable = findView(identifier: "version-history-table", in: historyContent) as? NSTableView,
              historyTable.numberOfRows == 2,
              findView(identifier: "version-history-compare", in: historyContent) != nil,
              findView(identifier: "version-history-restore", in: historyContent) != nil
        else {
            fail("Native UI smoke test failed: version history must show snapshots, compare, and restore controls.")
        }
        historyWindow.close()

        guard mainWindow.window?.title == "GraphiSchema",
              mainWindow.window?.contentView?.subviews.isEmpty == false,
              assistantWindow.window?.title == "GraphiSchema · Ollama",
              assistantWindow.window?.contentView?.subviews.isEmpty == false,
              NSApp.windows.contains(where: { $0.title == "Оформление и свойства" }),
              (NSApp.windows.first(where: { $0.title == "Оформление и свойства" })?.frame.width ?? 0) >= 440
        else {
            fail("Native UI smoke test failed: expected editor, style, and Ollama windows.")
        }
        checkNewCanvasFeatures(model: model, controller: mainWindow, assistant: assistantWindow, root: root, inspector: styleContent)
        print("Native UI smoke test passed: vector collection figures, figure replacement, edge ports and mouse route handles, day/night UI, inverse trackpad, prompt variables CRUD/reset, version history, JSON and Ollama.")
    }

    private static func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> Never {
        restorePreferences?()
        FileHandle.standardError.write(Data("\(file):\(line): \(message)\n".utf8))
        exit(1)
    }

    private static func perform(_ button: NSControl) {
        guard let action = button.action else { fail("Missing UI action") }
        _ = NSApp.sendAction(action, to: button.target, from: button)
    }

    private static func checkNewCanvasFeatures(model: AppModel, controller: MainWindowController, assistant: OllamaAssistantWindowController, root: NSView, inspector: NSView) {
        guard !ProjectResources.graphvizDeclaration.isEmpty,
              PaletteLibrary.allObjects.allSatisfy({ CanvasGeometry.icons[$0.iconPath] != nil })
        else { fail("Collection geometry and Graphviz template resources must be bundled") }
        model.selection = .node("waf"); controller.refreshAll()
        guard findView(identifier: "inspector-field-Форма", in: inspector) == nil,
              let collection = findView(identifier: "inspector-field-Коллекция", in: inspector) as? NSPopUpButton else { fail("Figure replacement must expose collection selection") }
        collection.select(collection.itemArray.first { ($0.representedObject as? String) == "lucide" }); perform(collection)
        guard let picker = findView(identifier: "inspector-field-Фигура", in: inspector) as? NSPopUpButton,
              let chosen = picker.itemArray.first(where: { ($0.representedObject as? String)?.hasPrefix("svg:lucide:") == true }),
              chosen.image != nil else { fail("Figure picker must show collection artwork") }
        let oldLabel = model.nodes.first { $0.id == "waf" }!.label
        picker.select(chosen); perform(picker)
        guard let node = model.nodes.first(where: { $0.id == "waf" }), node.icon?.hasPrefix("lucide/") == true,
              node.label == oldLabel, model.jsonDraft.contains(node.icon!) else { fail("Replacement must preserve identity/label and update JSON") }
        let count = model.nodes.count
        model.addNode(PaletteLibrary.object(id: "template:cloud")!, at: (x: 9, y: 4))
        guard model.nodes.count == count+1, model.nodes.last?.icon == PaletteItem.cloud.iconPath else { fail("Palette creation must persist figure artwork") }
        let cloud = model.nodes.last!
        guard let geometry = CanvasGeometry.icons[cloud.icon!], let width = cloud.width, let height = cloud.height,
              abs(width/height-geometry.aspectRatio) < 1e-6 else { fail("Canvas collection figures must preserve SVG proportions") }
        guard let canvas = findView(identifier: "diagram-canvas", in: root) as? DiagramCanvasView,
              let cloudPosition = canvas.nodePositions.first(where: { $0.id == cloud.id }) else { fail("Cloud geometry missing") }
        controller.refreshAll()
        let handle = canvas.screenPoint(for: NSPoint(x: cloudPosition.x+width/2, y: cloudPosition.y-height/2))
        let resized = NSPoint(x: handle.x+24, y: handle.y)
        func resizeEvent(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: resizeEvent(.leftMouseDown, point: handle))
        canvas.mouseDragged(with: resizeEvent(.leftMouseDragged, point: resized))
        canvas.mouseUp(with: resizeEvent(.leftMouseUp, point: resized))
        guard let resizedCloud = model.nodes.last, resizedCloud.width! > width,
              abs(resizedCloud.width!/resizedCloud.height!-geometry.aspectRatio) < 1e-6 else { fail("Mouse scaling must preserve figure proportions") }

        guard let edge = model.edges.first else { fail("Canvas missing") }
        model.selection = .edge(edge.id); controller.refreshAll()
        guard let sourcePort = findView(identifier: "inspector-field-Привязка источника", in: inspector) as? NSPopUpButton,
              let top = sourcePort.itemArray.first(where: { ($0.representedObject as? String) == "n" }) else { fail("Edge ports missing") }
        sourcePort.select(top); perform(sourcePort)
        guard model.edges.first?.sourcePort == "n" else { fail("Port UI action must update JSON") }
        let points = canvas.edgePoints(for: edge.id)
        let middle = canvas.screenPoint(for: canvas.routeMidpoint(points))
        let destination = NSPoint(x: middle.x+42, y: middle.y+27)
        func event(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, point: middle))
        canvas.mouseDragged(with: event(.leftMouseDragged, point: destination))
        canvas.mouseUp(with: event(.leftMouseUp, point: destination))
        guard model.edges.first?.waypoints.count == 1, model.diagram?.diagram.layoutMode == "manual",
              model.nodes.allSatisfy({ $0.x != nil && $0.y != nil }) else { fail("Mouse route handles must pin and persist the current layout") }
        let expected = canvas.worldPoint(for: destination), actual = model.edges.first!.waypoints[0]
        guard abs(expected.x-actual.x) < 1e-6 && abs(expected.y-actual.y) < 1e-6 else { fail("Route handle geometry must match the mouse") }
        if let directory = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_UI_ARTIFACT_DIR"] {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try encoder.encode(model.diagram!).write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-project.json")) }
            catch { fail("Cannot write native JSON roundtrip fixture: \(error)") }
        }
        if let reset = findView(identifier: "inspector-reset-route", in: inspector) as? NSButton { perform(reset) }
        guard model.edges.first?.waypoints.isEmpty == true else { fail("Reset route action failed") }

        model.inverseTrackpad = true
        guard canvas.inverseTrackpad,
              DiagramCanvasView.scrollDirection(precise: true, natural: true, inverse: true) == -1,
              DiagramCanvasView.scrollDirection(precise: true, natural: false, inverse: true) == 1,
              DiagramCanvasView.scrollDirection(precise: false, natural: true, inverse: true) == 1 else { fail("Inverse physical trackpad direction and mouse wheel must remain independent") }
        model.inverseTrackpad = false
        guard !canvas.inverseTrackpad else { fail("Navigation preference must apply immediately") }

        guard let toggle = findView(identifier: "theme-toggle", in: root) as? NSButton else { fail("Theme control missing") }
        canvas.fitToContent()
        if model.diagram?.presentation.theme != "light" { model.updateTheme("light") }
        perform(toggle)
        guard model.diagram?.presentation.theme == "dark", model.diagram?.presentation.background == "#21172F",
              root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              assistant.window?.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              let text = findTextView(containing: "schema_version", in: root), text.backgroundColor.hexRGB == "#21172F" else {
            fail("Night theme must cover the editor and auxiliary windows: theme=\(model.diagram?.presentation.theme ?? "nil"), background=\(model.diagram?.presentation.background ?? "nil"), root=\(root.effectiveAppearance.name.rawValue), assistant=\(assistant.window?.contentView?.effectiveAppearance.name.rawValue ?? "nil"), editor=\(findTextView(containing: "schema_version", in: root)?.backgroundColor.hexRGB ?? "nil")")
        }
        capture(root, name: "native-night")
        perform(toggle)
        guard model.diagram?.presentation.theme == "light", text.backgroundColor.hexRGB == "#FFFFFF" else { fail("Day theme must restore light surfaces") }
        capture(root, name: "native-day")

        assistant.showVariables()
        guard let variables = NSApp.windows.first(where: { $0.title == "Переменные системного промпта" }), let variableRoot = variables.contentView,
              let name = findView(identifier: "prompt-variable-name", in: variableRoot) as? NSTextField,
              let value = findView(identifier: "prompt-variable-value", in: variableRoot) as? NSTextView,
              let add = findView(identifier: "prompt-variable-add", in: variableRoot) as? NSButton,
              let save = findView(identifier: "prompt-variable-save", in: variableRoot) as? NSButton,
              let remove = findView(identifier: "prompt-variable-delete", in: variableRoot) as? NSButton,
              let reset = findView(identifier: "prompt-variable-reset", in: variableRoot) as? NSButton,
              let list = findView(identifier: "prompt-variables-list", in: variableRoot) as? NSTableView else { fail("Prompt variables CRUD controls missing") }
        variableRoot.layoutSubtreeIfNeeded()
        capture(variableRoot, name: "prompt-variables")
        guard value.frame.width >= 400, variables.frame.width >= 740 else { fail("Variable editor needs padding and usable width") }
        perform(add); name.stringValue = "smoke_architecture_role"; value.string = "Network architect"; perform(save)
        guard model.ollamaPreferences.variables["smoke_architecture_role"] == "Network architect",
              AppModel().ollamaPreferences.variables["smoke_architecture_role"] == "Network architect" else { fail("Variables must persist locally") }
        perform(remove)
        guard model.ollamaPreferences.variables["smoke_architecture_role"] == nil else { fail("Custom variable deletion failed") }
        // The built-in is sorted before default variable names; locate it through the table data source.
        let names = model.ollamaPreferences.variables.keys.sorted()
        if let index = names.firstIndex(of: "graphviz_attributes") { list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        value.string = "Changed declaration"; perform(save); perform(reset)
        guard model.ollamaPreferences.variables["graphviz_attributes"] == ProjectResources.graphvizDeclaration else { fail("Default Graphviz declaration reset failed") }
        model.updateTheme("dark")
        guard variableRoot.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              value.backgroundColor.hexRGB == "#21172F" else { fail("Variables window must follow the project theme") }
        capture(variableRoot, name: "prompt-variables-night")
        model.updateTheme("light")
        variables.close()
    }

    private static func capture(_ view: NSView, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_UI_ARTIFACT_DIR"] else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("Cannot capture UI artifact") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name+".png"))
        } catch { fail("Cannot save UI artifact: \(error)") }
    }

    private static func findEditorSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 3 { return split }
        for child in view.subviews {
            if let split = findEditorSplit(in: child) { return split }
        }
        return nil
    }

    private static func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let match = findView(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    private static func findTextView(containing value: String, in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.string.contains(value) { return textView }
        for child in view.subviews {
            if let match = findTextView(containing: value, in: child) { return match }
        }
        return nil
    }
}
