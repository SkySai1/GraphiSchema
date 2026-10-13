import AppKit

@MainActor
enum NativeUISmokeTest {
    static func run() {
        _ = NSApplication.shared
        let model = AppModel()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("GraphiSchema/examples/starter.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples/starter.json"),
        ].compactMap { $0 }
        guard let starterData = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first else {
            fatalError("Native UI smoke test cannot load examples/starter.json.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let starter = try? decoder.decode(DiagramProject.self, from: starterData) else {
            fatalError("Native UI smoke test cannot decode the starter project.")
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
        else { fatalError("Native UI smoke test failed: independent concurrent edits must merge.") }
        var sameFieldEdit = otherWindowEdit
        sameFieldEdit.nodes[0].label = "Конкурирующее изменение"
        guard model.mergeProject(base: model.prettyJSON(starter), local: localEdit, remote: sameFieldEdit) == nil else {
            fatalError("Native UI smoke test failed: conflicting edits to one field must be rejected safely.")
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
            fatalError("Native UI smoke test failed: editing must pause while a JSON draft is unapplied.")
        }
        model.discardJSONDraft()

        guard let root = mainWindow.window?.contentView,
              let editorSplit = findEditorSplit(in: root),
              editorSplit.arrangedSubviews.count == 3
        else {
            fatalError("Native UI smoke test failed: expected palette, canvas, and JSON panels.")
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
            fatalError("Native UI smoke test failed: palette, readable JSON, chat, and panel widths must be visible.")
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
                fatalError("Native UI smoke test failed: selecting a collection must load all included SVG objects and filter other collections.")
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
                    fatalError("Native UI smoke test failed: repeated collection switches must reuse tiles without accumulating width constraints.")
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
            fatalError("Native UI smoke test failed: Ollama fields need usable width and padding.")
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
            fatalError("Native UI smoke test failed: unusable style layout (visible=\(styleWindow?.isVisible ?? false), window=\(styleWindow?.frame ?? .zero), content=\(styleContent.frame)/\(styleContent.bounds), name=\(nameField?.frame ?? .zero), enabled=\(nameField?.isEnabled ?? false), fill=\(fillWell?.frame ?? .zero), border=\(borderWell?.frame ?? .zero), scrollFrame=\(propertiesScroll?.frame ?? .zero), scroll=\(propertiesScroll?.contentView.bounds ?? .zero)).")
        }
        model.selection = .project
        mainWindow.refreshAll()
        let projectPropertiesHeight = styleWindow?.contentView?.frame.height ?? 0
        guard let routingPicker = findView(identifier: "inspector-field-Маршрут связей", in: styleContent) as? NSPopUpButton,
              Set(routingPicker.itemArray.compactMap { $0.representedObject as? String }) == Set(["straight", "angled", "orthogonal"]),
              projectPropertiesHeight >= 280,
              projectPropertiesHeight < nodePropertiesHeight
        else {
            fatalError("Native UI smoke test failed: project properties must offer straight, angled, and orthogonal edge routes.")
        }
        let originalRouting = model.diagram?.diagram.edgeRouting ?? "angled"
        if let orthogonal = routingPicker.itemArray.first(where: { ($0.representedObject as? String) == "orthogonal" }),
           let routingAction = routingPicker.action {
            routingPicker.select(orthogonal)
            _ = NSApp.sendAction(routingAction, to: routingPicker.target, from: routingPicker)
            guard model.diagram?.diagram.edgeRouting == "orthogonal", model.jsonDraft.contains("orthogonal") else {
                fatalError("Native UI smoke test failed: routing actions must update the project and synchronized JSON.")
            }
            model.updateEdgeRouting(originalRouting)
        }
        model.selection = .edge(starter.edges.first?.id ?? "")
        mainWindow.refreshAll()
        guard findView(identifier: "inspector-field-Маршрут всех связей", in: styleContent) is NSPopUpButton else {
            fatalError("Native UI smoke test failed: selected edge properties must expose the shared routing setting.")
        }
        model.selection = .node("waf")
        mainWindow.refreshAll()
        if let nameField = findView(identifier: "inspector-field-Название", in: styleContent) as? NSTextField,
           let action = nameField.action {
            let oldName = model.nodes.first(where: { $0.id == "waf" })?.label ?? "WAF"
            nameField.stringValue = "Inspector smoke edit"
            _ = NSApp.sendAction(action, to: nameField.target, from: nameField)
            guard model.nodes.first(where: { $0.id == "waf" })?.label == "Inspector smoke edit" else {
                fatalError("Native UI smoke test failed: changing a property must update the selected object.")
            }
            model.editNode("waf") { $0.label = oldName }
            mainWindow.refreshAll()
            guard let borderControl = findView(identifier: "inspector-field-Граница", in: styleContent) as? NSColorWell,
                  let borderAction = borderControl.action
            else { fatalError("Native UI smoke test failed: border color control must be available after a property refresh.") }
            let oldStroke = model.nodes.first(where: { $0.id == "waf" })?.style.stroke ?? "#000000"
            borderControl.color = NSColor(hex: "#AA3377")
            let editedStroke = borderControl.color.hexRGB
            let borderActionHandled = NSApp.sendAction(borderAction, to: borderControl.target, from: borderControl)
            guard model.nodes.first(where: { $0.id == "waf" })?.style.stroke == editedStroke else {
                fatalError("Native UI smoke test failed: color action handled=\(borderActionHandled), enabled=\(borderControl.isEnabled), resulting stroke=\(model.nodes.first(where: { $0.id == "waf" })?.style.stroke ?? "missing").")
            }
            model.editNode("waf") { $0.style.stroke = oldStroke }
            mainWindow.refreshAll()
        } else {
            fatalError("Native UI smoke test failed: selected object name must have an active edit action.")
        }
        guard findView(identifier: "palette-item-template:service", in: root) === firstPaletteTile else {
            fatalError("Native UI smoke test failed: changing diagram properties must preserve palette views.")
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
            fatalError("Native UI smoke test failed: version history must show snapshots, compare, and restore controls.")
        }
        historyWindow.close()

        guard mainWindow.window?.title == "GraphiSchema",
              mainWindow.window?.contentView?.subviews.isEmpty == false,
              assistantWindow.window?.title == "GraphiSchema · Ollama",
              assistantWindow.window?.contentView?.subviews.isEmpty == false,
              NSApp.windows.contains(where: { $0.title == "Оформление и свойства" }),
              (NSApp.windows.first(where: { $0.title == "Оформление и свойства" })?.frame.width ?? 0) >= 440
        else {
            fatalError("Native UI smoke test failed: expected editor, style, and Ollama windows.")
        }
        print("Native UI smoke test passed: cached SVG collections, compact interactive inspector, three edge routes, version history, synchronized JSON, chat, and Ollama settings.")
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
