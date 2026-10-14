import AppKit
import Darwin

private final class CanvasScrollFixtureEvent: NSEvent {
    private let rawDelta: NSPoint
    private let natural: Bool
    init(delta: NSPoint, natural: Bool) {
        rawDelta = delta
        self.natural = natural
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { rawDelta.x }
    override var scrollingDeltaY: CGFloat { rawDelta.y }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var isDirectionInvertedFromDevice: Bool { natural }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var locationInWindow: NSPoint { .zero }
}

@MainActor
enum NativeUISmokeTest {
    private static var restorePreferences: (() -> Void)?
    static func run() {
        _ = NSApplication.shared
        let preferencesBackup = UserDefaults.standard.object(forKey: "GraphiSchema.ollama.preferences")
        let navigationBackup = UserDefaults.standard.object(forKey: "GraphiSchema.inverseTrackpad")
        let themeBackup = UserDefaults.standard.object(forKey: "GraphiSchema.themeMode")
        let starterBackup = UserDefaults.standard.object(forKey: "GraphiSchema.loadStarterOnLaunch")
        restorePreferences = {
            UserDefaults.standard.set(preferencesBackup, forKey: "GraphiSchema.ollama.preferences")
            UserDefaults.standard.set(navigationBackup, forKey: "GraphiSchema.inverseTrackpad")
            UserDefaults.standard.set(themeBackup, forKey: "GraphiSchema.themeMode")
            UserDefaults.standard.set(starterBackup, forKey: "GraphiSchema.loadStarterOnLaunch")
        }
        defer { restorePreferences?(); restorePreferences = nil }
        UserDefaults.standard.removeObject(forKey: "GraphiSchema.inverseTrackpad")
        let model = AppModel()
        guard !model.inverseTrackpad else { fail("Trackpad navigation must default to following finger movement.") }
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
        checkNodeStacking(starter)
        checkContainerAttachmentFromCanvas(starter)
        checkEmptyContainerContextMenu(starter)
        checkContainerDragBehavior(starter)
        checkEmptyContainerDragThroughController(starter)
        checkCanvasControlGeometry(starter)
        checkTrackpadNavigation()
        checkNodeStackContextMenu()
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
        let standardCollection = PaletteLibrary.collection(id: "standard")
        let hasBundledPaletteIcons = PaletteLibrary.allObjects.allSatisfy { $0.loadIcon() != nil }
        let hasChat = findView(identifier: "ollama-chat-panel", in: root) != nil
        guard editorSplit.arrangedSubviews[0].frame.width >= 220,
              editorSplit.arrangedSubviews[1].frame.width >= 340,
              editorSplit.arrangedSubviews[2].frame.width >= 370,
              hasPalette,
              (paletteScroll?.contentView.bounds.width ?? 0) >= 200,
              (paletteScroll?.contentView.bounds.height ?? 0) >= 400,
              (firstPaletteTile?.frame.width ?? 0) >= 180,
              collectionPicker != nil,
              collectionPicker?.itemArray.count == PaletteLibrary.collections.count,
              PaletteLibrary.collections.count == 5,
              standardCollection?.objects.count ?? 0 >= 9,
              tablerCollection?.objects.count ?? 0 >= 20,
              lucideCollection?.objects.count ?? 0 >= 15,
              PaletteLibrary.allObjects.count >= 50,
              hasAllPaletteItems,
              hasBundledPaletteIcons,
              hasChat,
              hasJSONCode
        else {
            fail("Native UI smoke test failed: palette, readable JSON, chat, and panel widths must be visible. panels=\(editorSplit.arrangedSubviews.map(\.frame.width)), paletteScroll=\(paletteScroll?.contentView.bounds ?? .zero), firstTile=\(firstPaletteTile?.frame ?? .zero), picker=\(collectionPicker?.itemArray.count ?? -1), objects=\(PaletteLibrary.allObjects.count), visibleTiles=\(hasAllPaletteItems), icons=\(hasBundledPaletteIcons), chat=\(hasChat), json=\(hasJSONCode).")
        }
        guard findButton(title: "Добавить связь", in: root) == nil else {
            fail("Project actions must create connections from the selected node control, not a separate sidebar button.")
        }
        checkPaletteLayout(root: root, split: editorSplit, collectionPicker: collectionPicker!, firstTile: firstPaletteTile!)
        checkSynchronizedGroupScaling(starter)
        checkArrowheadTouchesVisibleNode(starter)
        checkToolbarOverflow(mainWindow: mainWindow, root: root)
        checkPDFOptions(mainWindow: mainWindow)
        checkLongPressTextEditor(mainWindow: mainWindow, root: root, nodeID: "waf")
        guard NSApp.mainMenu?.items.contains(where: { $0.title == "Файл" }) == true,
              NSApp.mainMenu?.items.contains(where: { $0.title == "Настройки" }) == true,
              NSApp.mainMenu?.items.first(where: { $0.title == "Вид" })?.submenu?.items.contains(where: { $0.title == "Стиль и свойства…" }) == true,
              NSColor(hex: "#33669980").hexRGBA == "#33669980" else {
            fail("The macOS menu bar, system settings and RGBA color support must be available.")
        }
        if let collectionPicker,
           let standard = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == "standard" }) {
            collectionPicker.select(standard)
            _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
            guard (standardCollection?.objects ?? []).allSatisfy({ $0.loadIcon() != nil }) else { fail("Standard vector shapes must be available in the palette") }
            if let all = collectionPicker.itemArray.first(where: { ($0.representedObject as? String) == "all" }) {
                collectionPicker.select(all); _ = NSApp.sendAction(collectionPicker.action!, to: collectionPicker.target, from: collectionPicker)
            }
        }
        guard let promptEditor = findView(identifier: "ollama-prompt-editor", in: root) as? NSTextView,
              let expandPrompt = findView(identifier: "ollama-prompt-expand", in: root) as? NSButton else { fail("Chat must use an editable text area with an expansion button") }
        perform(expandPrompt)
        root.window?.contentView?.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        promptEditor.enclosingScrollView?.layoutSubtreeIfNeeded()
        guard promptEditor.isEditable, promptEditor.enclosingScrollView?.frame.height ?? 0 >= 70 else { fail("Expanded chat prompt must accept multiline text") }
        perform(expandPrompt)
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
              (findView(identifier: "ollama-system-prompt", in: assistantWindow.window?.contentView ?? NSView())?.frame.width ?? 0) >= 400,
              (findView(identifier: "ollama-help-system-prompt", in: assistantWindow.window?.contentView ?? NSView())?.toolTip?.isEmpty == false)
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
        let deleteButton = findView(identifier: "inspector-delete", in: styleContent) as? NSButton
        let nameHelp = findView(identifier: "inspector-help-Название", in: styleContent)
        let nodePropertiesHeight = styleContent.frame.height
        guard styleWindow?.isVisible == true,
              styleWindow?.frame.width ?? 0 >= 340,
              styleWindow?.frame.height ?? 700 < 650,
              nameField?.isEnabled == true,
              (nameField?.frame.width ?? 0) >= 180,
              (fillWell?.frame.width ?? 0) >= 180,
              (borderWell?.frame.width ?? 0) >= 180,
              (propertiesScroll?.contentView.bounds.width ?? 0) >= 320,
              (propertiesScroll?.contentView.bounds.height ?? 0) >= 150,
              (deleteButton?.frame.width ?? 0) >= 70,
              nameHelp?.toolTip?.isEmpty == false,
              deleteButton.map({ styleContent.bounds.contains($0.convert($0.bounds, to: styleContent)) }) == true,
              deleteButton?.superview?.subviews.compactMap({ $0 as? NSTextField }).first.map({
                  !deleteButton!.convert(deleteButton!.bounds, to: styleContent)
                      .intersects($0.convert($0.bounds, to: styleContent))
              }) == true
        else {
            fail("Native UI smoke test failed: unusable style layout (visible=\(styleWindow?.isVisible ?? false), window=\(styleWindow?.frame ?? .zero), content=\(styleContent.frame)/\(styleContent.bounds), name=\(nameField?.frame ?? .zero), enabled=\(nameField?.isEnabled ?? false), fill=\(fillWell?.frame ?? .zero), border=\(borderWell?.frame ?? .zero), delete=\(deleteButton?.frame ?? .zero), deleteHelp=\(nameHelp?.toolTip ?? "missing"), scrollFrame=\(propertiesScroll?.frame ?? .zero), scroll=\(propertiesScroll?.contentView.bounds ?? .zero)).")
        }
        model.selection = .project
        mainWindow.refreshAll()
        guard deleteButton?.isHidden == true else {
            fail("Project style settings must not show an element deletion button.")
        }
        checkProjectPropertiesSpacing(styleWindow: styleWindow)
        let projectPropertiesHeight = styleWindow?.contentView?.frame.height ?? 0
        let routingPicker = findView(identifier: "inspector-field-Маршрут связей", in: styleContent) as? NSPopUpButton
        guard let routingPicker,
              Set(routingPicker.itemArray.compactMap { $0.representedObject as? String }) == Set(["straight", "angled", "orthogonal", "curved"]),
              projectPropertiesHeight >= 220
        else {
            fail("Native UI smoke test failed: project properties must offer straight, angled, and orthogonal edge routes. height=\(projectPropertiesHeight), nodeHeight=\(nodePropertiesHeight), choices=\(routingPicker?.itemArray.compactMap { $0.representedObject as? String } ?? []).")
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
            borderControl.activate(true)
            let colorPanel = NSColorPanel.shared
            colorPanel.showsAlpha = true
            colorPanel.orderFront(nil)
            for color in ["#AA337780", "#3355AA60"] {
                borderControl.color = NSColor(hex: color)
                let colorActionHandled = NSApp.sendAction(borderAction, to: borderControl.target, from: borderControl)
                guard colorActionHandled,
                      model.nodes.first(where: { $0.id == "waf" })?.style.stroke == color else {
                    fail("Native UI smoke test failed: repeated RGBA color selection must update the object, expected \(color), well=\(borderControl.color.hexRGBA), handled=\(colorActionHandled), got \(model.nodes.first(where: { $0.id == "waf" })?.style.stroke ?? "missing").")
                }
            }
            colorPanel.close()
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
              (NSApp.windows.first(where: { $0.title == "Оформление и свойства" })?.frame.width ?? 0) >= 340
        else {
            fail("Native UI smoke test failed: expected editor, style, and Ollama windows.")
        }
        checkNewCanvasFeatures(model: model, controller: mainWindow, assistant: assistantWindow, root: root,
                               inspector: styleContent, firstPaletteTile: firstPaletteTile)
        print("Native UI smoke test passed: reliable single/group container attachment, blank-canvas creation menu, live container drag through controller refresh, explicit detachment, physical trackpad directions, aligned controls, compact properties, JSON, version history and Ollama.")
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

    private static func checkPaletteLayout(root: NSView, split: NSSplitView, collectionPicker: NSPopUpButton, firstTile: NSView) {
        guard let palette = findView(identifier: "palette-collection-list", in: root) as? NSStackView,
              let documentStack = findView(identifier: "sidebar-document-stack", in: root) as? NSStackView,
              let elements = findView(identifier: "sidebar-project-elements", in: root) as? NSStackView,
              let actionsHeading = findView(identifier: "sidebar-actions-heading", in: root),
              let toggle = findView(identifier: "palette-collection-toggle", in: root) as? NSButton,
              let heading = findView(identifier: "palette-collection-heading", in: root) as? NSStackView,
              let collectionBody = findView(identifier: "palette-collection-body", in: root) as? NSStackView,
              let search = findView(identifier: "palette-search-field", in: root) as? NSSearchField,
              let scroll = findView(identifier: "palette-scroll", in: root) as? NSScrollView,
              let results = findView(identifier: "palette-results-heading", in: root) else {
            fail("Palette layout controls must be identifiable for smoke tests.")
        }
        root.layoutSubtreeIfNeeded()
        guard palette.isFlipped,
              firstTile.frame.width >= 180,
              abs(firstTile.frame.width - palette.bounds.width) < 1,
              firstTile.frame.minY >= results.frame.maxY,
              heading.bounds.contains(toggle.convert(toggle.bounds, to: heading)),
              palette.bounds.contains(toggle.convert(toggle.bounds, to: palette)) else {
            fail("Palette rows must flow from the top, match the left-pane width, and keep the collapse control visible. flipped=\(palette.isFlipped), tile=\(firstTile.frame), list=\(palette.bounds), results=\(results.frame), heading=\(heading.frame), toggleInHeading=\(toggle.convert(toggle.bounds, to: heading)), toggleInList=\(toggle.convert(toggle.bounds, to: palette)).")
        }

        search.stringValue = "no-such-palette-entry"
        perform(search)
        root.layoutSubtreeIfNeeded()
        guard let empty = findView(identifier: "palette-empty-state", in: root),
              empty.frame.minY >= (findView(identifier: "palette-results-heading", in: root)?.frame.maxY ?? .greatestFiniteMagnitude),
              abs(scroll.contentView.bounds.origin.y) < 0.5 else {
            fail("An empty collection search must stay anchored at the top of the sidebar.")
        }
        search.stringValue = ""
        perform(search)
        root.layoutSubtreeIfNeeded()
        perform(toggle)
        root.layoutSubtreeIfNeeded()
        guard collectionBody.isHidden, !palette.arrangedSubviews.contains(collectionBody), !toggle.isHidden else {
            fail("The collection search block must collapse while leaving its disclosure button visible.")
        }
        root.layoutSubtreeIfNeeded()
        palette.layoutSubtreeIfNeeded()
        let collapsedPaletteFrame = palette.convert(palette.bounds, to: documentStack)
        let collapsedElementsFrame = elements.convert(elements.bounds, to: documentStack)
        let collapsedGap = collapsedElementsFrame.minY - collapsedPaletteFrame.maxY
        let collapsedActionOffset = actionsHeading.convert(actionsHeading.bounds, to: elements).minY
        perform(toggle)
        root.layoutSubtreeIfNeeded()
        palette.layoutSubtreeIfNeeded()
        let expandedPaletteFrame = palette.convert(palette.bounds, to: documentStack)
        let expandedElementsFrame = elements.convert(elements.bounds, to: documentStack)
        let expandedGap = expandedElementsFrame.minY - expandedPaletteFrame.maxY
        let expandedActionOffset = actionsHeading.convert(actionsHeading.bounds, to: elements).minY
        let collapsedIsCompact = collapsedPaletteFrame.height <= 58
            && collapsedGap >= -1 && collapsedGap <= 28
        guard !collectionBody.isHidden, palette.arrangedSubviews.contains(collectionBody),
              !search.isHidden, !collectionPicker.isHidden,
              collapsedIsCompact,
              collapsedPaletteFrame.height < expandedPaletteFrame.height - 40,
              abs(expandedGap-collapsedGap) < 2,
              abs(expandedActionOffset-collapsedActionOffset) < 2 else {
            fail("Collapsing the collection must hide its contents, keep the header compact, and leave no more than 28 pt before project actions. collapsed=\(collapsedPaletteFrame)/\(collapsedElementsFrame), expanded=\(expandedPaletteFrame)/\(expandedElementsFrame), gaps=\(collapsedGap)/\(expandedGap), compact=\(collapsedIsCompact), actionOffsets=\(collapsedActionOffset)/\(expandedActionOffset).")
        }

        let oldSidebarWidth = split.arrangedSubviews[0].frame.width
        split.setPosition(max(220, oldSidebarWidth - 30), ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        split.layoutSubtreeIfNeeded()
        guard palette.bounds.contains(toggle.convert(toggle.bounds, to: palette)),
              abs(firstTile.frame.width - palette.bounds.width) < 1 else {
            fail("The collection disclosure and item widths must adapt to a narrow left pane.")
        }
        split.setPosition(oldSidebarWidth, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
    }

    private static func checkNodeStacking(_ project: DiagramProject) {
        guard project.nodes.count >= 3 else { fail("z-index regression needs three nodes.") }
        var nodes = Array(project.nodes.prefix(3))
        for index in nodes.indices { nodes[index].zIndex = 0 }
        let originalOrder = nodes.map(\.id)
        guard DiagramNodeStackOrder.sorted(nodes).map(\.id) == originalOrder else {
            fail("Equal z-index values must preserve canonical model order.")
        }
        nodes[0].zIndex = 8
        guard DiagramNodeStackOrder.sorted(nodes).map(\.id) == [nodes[1].id, nodes[2].id, nodes[0].id] else {
            fail("Higher z-index objects must render later and appear above lower values.")
        }
        let front = DiagramNodeStackOrder.moving(nodes[1].id, in: nodes, toFront: true)
        let back = DiagramNodeStackOrder.moving(nodes[0].id, in: front, toFront: false)
        guard DiagramNodeStackOrder.sorted(front).last?.id == nodes[1].id,
              DiagramNodeStackOrder.sorted(back).first?.id == nodes[0].id else {
            fail("Bring-to-front and send-to-back must update deterministic paint order.")
        }
        var saturated = nodes
        for index in saturated.indices { saturated[index].zIndex = 1_000_000 }
        let rebased = DiagramNodeStackOrder.moving(saturated[0].id, in: saturated, toFront: true)
        guard DiagramNodeStackOrder.sorted(rebased).last?.id == saturated[0].id,
              rebased.allSatisfy({ (-1_000_000...1_000_000).contains($0.effectiveZIndex) }) else {
            fail("Reordering a saturated z-index stack must preserve order and legal values.")
        }

        var saved = project
        saved.nodes[0].zIndex = 42
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = try? encoder.encode(saved),
              String(data: data, encoding: .utf8)?.contains("\"z_index\"") == true,
              let restored = try? decoder.decode(DiagramProject.self, from: data),
              restored.nodes[0].effectiveZIndex == 42 else {
            fail("z-index must survive the canonical JSON save and load cycle.")
        }
        let probe = AppModel(); probe.diagram = project
        probe.moveNodeToFront(nodes[0].id)
        guard DiagramNodeStackOrder.sorted(probe.nodes).last?.id == nodes[0].id else {
            fail("Application commands must route bring-to-front through the project model.")
        }
        probe.moveNodeToBack(nodes[0].id)
        guard DiagramNodeStackOrder.sorted(probe.nodes).first?.id == nodes[0].id else {
            fail("Application commands must route send-to-back through the project model.")
        }
        probe.setNodeZIndex(nodes[0].id, 23)
        guard probe.nodes.first(where: { $0.id == nodes[0].id })?.effectiveZIndex == 23 else {
            fail("Manual z-index input must update the project model.")
        }
    }

    private static func checkContainerAttachmentFromCanvas(_ starter: DiagramProject) {
        let probe = AppModel()
        let controller = MainWindowController(model: probe)
        controller.showWindow(nil)
        guard let window = controller.window, let root = window.contentView,
              let canvas = findView(identifier: "diagram-canvas", in: root) as? DiagramCanvasView else {
            fail("Attachment regression needs the real canvas controller.")
        }
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let style = ContainerStyle(fill: "#E8EEF8", stroke: "#607090", text: "#172238")
        let starts = [NSPoint(x: -1, y: 3), NSPoint(x: 9, y: 3), NSPoint(x: 4, y: -1), NSPoint(x: 4, y: 7),
                      NSPoint(x: -1, y: -1), NSPoint(x: -1, y: 7), NSPoint(x: 9, y: -1), NSPoint(x: 9, y: 7)]
        var checks = 0
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        for occupied in [false, true] {
            for refreshStage in ["none", "mid-drag", "before-release", "release-only"] {
                for start in starts {
                    var project = starter
                    var node = starter.nodes[0]
                    node.id = "drop_probe"; node.icon = nil; node.shape = "box"; node.containerId = nil
                    node.x = start.x; node.y = start.y; node.width = 1; node.height = 1
                    project.nodes = [node]; project.edges = []; project.diagram.layoutMode = "manual"
                    project.containers = [DiagramContainer(id: "drop_target", label: "Drop target", parentId: nil,
                        style: style, x: 4, y: 3, width: 3, height: 2)]
                    var positions = [LayoutNode(id: node.id, x: start.x, y: start.y, width: 1, height: 1)]
                    if occupied {
                        var member = node; member.id = "existing_member"; member.containerId = "drop_target"
                        member.x = 4; member.y = 3; member.width = 3; member.height = 2
                        project.nodes.append(member)
                        positions.append(LayoutNode(id: member.id, x: 4, y: 3, width: 3, height: 2))
                    }
                    probe.diagram = project; probe.selection = .project
                    probe.layout = DiagramLayout(engine: "neato", width: 12, height: 10, minX: -2, minY: -2, nodes: positions, edges: [])
                    controller.refreshAll(); canvas.fitToContent(); canvas.zoom(by: 0.85)
                    canvas.scrollWheel(with: CanvasScrollFixtureEvent(delta: NSPoint(x: 10, y: -6), natural: true))
                    let source = canvas.screenPoint(for: start)
                    let destination = canvas.screenPoint(for: NSPoint(x: 4, y: 3))
                    let halfway = NSPoint(x: (source.x + destination.x) / 2, y: (source.y + destination.y) / 2)
                    canvas.mouseDown(with: event(.leftMouseDown, source))
                    canvas.mouseDragged(with: event(.leftMouseDragged, halfway))
                    if refreshStage == "mid-drag" {
                        probe.layout?.width += 0.25
                        controller.refreshAll()
                    }
                    if refreshStage != "release-only" {
                        canvas.mouseDragged(with: event(.leftMouseDragged, destination))
                    }
                    if refreshStage == "before-release" {
                        probe.layout?.width += 0.25
                        controller.refreshAll()
                    }
                    canvas.mouseUp(with: event(.leftMouseUp, destination))
                    guard let moved = probe.nodes.first, moved.containerId == "drop_target",
                          abs((moved.x ?? -100) - 4) < 1e-6, abs((moved.y ?? -100) - 3) < 1e-6 else {
                        fail("Attachment must work from every canvas direction through layout refresh and mouse-up: occupied=\(occupied), stage=\(refreshStage), source=\(start), result=\(String(describing: probe.nodes.first)).")
                    }
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    guard let saved = try? decoder.decode(DiagramProject.self, from: Data(probe.jsonDraft.utf8)),
                          saved.nodes.first?.containerId == "drop_target" else {
                        fail("Canvas attachment must synchronize container_id into project JSON.")
                    }
                    checks += 1
                }
            }
        }
        print("Container attachment: \(checks) controller scenarios passed (8 directions, empty/occupied targets, 4 refresh/release modes).")

        var project = starter
        var node = starter.nodes[0]
        node.id = "edge_grab"; node.icon = nil; node.shape = "box"; node.containerId = nil
        node.x = -1; node.y = 3; node.width = 2; node.height = 1
        project.nodes = [node]; project.edges = []; project.diagram.layoutMode = "manual"
        project.containers = [DiagramContainer(id: "drop_target", label: "Target", parentId: nil, style: style,
                                              x: 4, y: 3, width: 3, height: 2)]
        func load(_ project: DiagramProject, selection: DiagramSelection = .project) {
            probe.diagram = project; probe.selection = selection
            probe.layout = DiagramLayout(engine: "neato", width: 12, height: 10, minX: -2, minY: -2,
                nodes: project.nodes.map { LayoutNode(id: $0.id, x: $0.x!, y: $0.y!, width: $0.width!, height: $0.height!) }, edges: [])
            controller.refreshAll(); canvas.fitToContent()
        }
        load(project)
        let grabbed = canvas.screenPoint(for: NSPoint(x: -0.15, y: 3))
        let pointerDrop = canvas.screenPoint(for: NSPoint(x: 2.55, y: 3))
        canvas.mouseDown(with: event(.leftMouseDown, grabbed))
        canvas.mouseDragged(with: event(.leftMouseDragged, pointerDrop))
        canvas.mouseUp(with: event(.leftMouseUp, pointerDrop))
        guard probe.nodes.first?.containerId == "drop_target", abs((probe.nodes.first?.x ?? 0) - 1.7) < 1e-6 else {
            fail("Grabbing a shape near its edge must attach where the pointer is released, preserving the pointer-to-center offset.")
        }

        project.containers.insert(DiagramContainer(id: "outer", label: "Outer", parentId: nil, style: style,
                                                 x: 4, y: 3, width: 5, height: 4), at: 0)
        project.containers[1].parentId = "outer"
        load(project)
        let start = canvas.screenPoint(for: NSPoint(x: -1, y: 3))
        let end = canvas.screenPoint(for: NSPoint(x: 4, y: 3))
        canvas.mouseDown(with: event(.leftMouseDown, start)); canvas.mouseDragged(with: event(.leftMouseDragged, end))
        canvas.mouseUp(with: event(.leftMouseUp, end))
        guard probe.nodes.first?.containerId == "drop_target" else { fail("Overlapping nested containers must attach to the deepest target.") }

        project.containers.removeFirst(); project.containers[0].parentId = nil
        node.width = 1; node.y = 2.6
        var second = node; second.id = "group_second"; second.y = 3.4
        var outside = node; outside.id = "group_outside"; outside.y = 6.4
        project.nodes = [node, second, outside]
        let ids = Set(project.nodes.map(\.id))
        load(project, selection: .nodes(ids))
        project.diagram.layoutMode = "auto"
        for index in project.nodes.indices { project.nodes[index].x = nil; project.nodes[index].y = nil }
        probe.diagram = project; controller.refreshAll()
        let groupStart = canvas.screenPoint(for: NSPoint(x: -1, y: 2.6))
        let groupEnd = canvas.screenPoint(for: NSPoint(x: 4, y: 2.6))
        canvas.mouseDown(with: event(.leftMouseDown, groupStart)); canvas.mouseDragged(with: event(.leftMouseDragged, groupEnd))
        probe.layout?.width += 0.25
        for index in probe.layout!.nodes.indices { probe.layout!.nodes[index].x += 1 }
        controller.refreshAll()
        canvas.mouseUp(with: event(.leftMouseUp, groupEnd))
        guard probe.nodes[0].containerId == "drop_target", probe.nodes[1].containerId == "drop_target",
              probe.nodes[2].containerId == nil, probe.nodes.allSatisfy({ abs(($0.x ?? 0) - 4) < 1e-6 }) else {
            fail("Group movement must atomically attach members inside the target and leave outside members free, including layout refresh before release.")
        }
        let attachedStart = canvas.screenPoint(for: NSPoint(x: 4, y: 2.6))
        let attachedEnd = canvas.screenPoint(for: NSPoint(x: 8, y: 2.6))
        canvas.mouseDown(with: event(.leftMouseDown, attachedStart)); canvas.mouseDragged(with: event(.leftMouseDragged, attachedEnd))
        canvas.mouseUp(with: event(.leftMouseUp, attachedEnd))
        guard probe.nodes[0].containerId == "drop_target", probe.nodes[1].containerId == "drop_target" else {
            fail("Moving an attached group must keep existing container membership.")
        }
        print("Container attachment: edge grab, nested target, group attachment and retained membership passed.")
        window.close()
    }

    private static func checkEmptyContainerContextMenu(_ starter: DiagramProject) {
        var project = starter
        var node = starter.nodes[0]
        node.id = "context_node"; node.icon = nil; node.shape = "box"; node.containerId = nil
        node.x = -2; node.y = -2; node.width = 1; node.height = 1
        project.nodes = [node]; project.edges = []; project.containers = []; project.diagram.layoutMode = "manual"
        let probe = AppModel(); probe.diagram = project
        probe.layout = DiagramLayout(engine: "neato", width: 16, height: 12, minX: -4, minY: -4,
            nodes: [LayoutNode(id: node.id, x: -2, y: -2, width: 1, height: 1)], edges: [])
        let controller = MainWindowController(model: probe)
        controller.refreshAll(); controller.showWindow(nil)
        guard let window = controller.window, let root = window.contentView,
              let canvas = findView(identifier: "diagram-canvas", in: root) as? DiagramCanvasView else {
            fail("Empty-container context menu regression needs the real canvas controller.")
        }
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); canvas.fitToContent(); canvas.zoom(by: 0.8)
        canvas.scrollWheel(with: CanvasScrollFixtureEvent(delta: NSPoint(x: -10, y: 8), natural: true))
        func event(_ world: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .rightMouseDown, location: canvas.convert(canvas.screenPoint(for: world), to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let world = NSPoint(x: 8, y: 5)
        let clicked = canvas.screenPoint(for: world)
        guard let menu = canvas.menu(for: event(world)),
              menu.items.map(\.title) == ["Создать пустой контейнер"],
              let create = menu.items.first, let action = create.action else {
            fail("Right-clicking blank canvas must offer creation of an empty container.")
        }
        _ = NSApp.sendAction(action, to: create.target, from: create)
        guard probe.containers.count == 1, let created = probe.containers.first,
              created.parentId == nil, abs((created.x ?? 0) - 8) < 1e-6, abs((created.y ?? 0) - 5) < 1e-6,
              probe.nodes == project.nodes, probe.selection == .container(created.id),
              let frame = canvas.containerScreenFrame(for: created.id),
              abs(frame.midX - clicked.x) < 1e-6, abs(frame.midY - clicked.y) < 1e-6 else {
            fail("The canvas context action must create an empty selected container at the clicked point without moving the camera: count=\(probe.containers.count), container=\(String(describing: probe.containers.first)), selection=\(probe.selection), frame=\(String(describing: probe.containers.first.flatMap { canvas.containerScreenFrame(for: $0.id) })), clicked=\(clicked).")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let saved = try? decoder.decode(DiagramProject.self, from: Data(probe.jsonDraft.utf8)),
              saved.containers.first == created else { fail("The new context-created container must synchronize into canonical JSON.") }
        guard let nodeMenu = canvas.menu(for: event(NSPoint(x: -2, y: -2))),
              nodeMenu.items.contains(where: { $0.title == "Оформление и свойства…" }),
              !nodeMenu.items.contains(where: { $0.title == "Создать пустой контейнер" }),
              let containerMenu = canvas.menu(for: event(world)),
              containerMenu.items.contains(where: { $0.title == "Оформление и свойства…" }),
              !containerMenu.items.contains(where: { $0.title == "Создать пустой контейнер" }) else {
            fail("Node and container right-click menus must retain their own editing actions.")
        }
        capture(canvas, name: "context-created-empty-container")
        let count = probe.containers.count
        probe.updateJSONDraft("{}")
        guard canvas.menu(for: event(NSPoint(x: 1, y: 5))) == nil else {
            fail("A canvas locked by an unapplied JSON draft must not offer creation actions.")
        }
        _ = NSApp.sendAction(action, to: create.target, from: create)
        guard probe.containers.count == count else { fail("A stale context menu action must not modify a locked project.") }
        probe.discardJSONDraft()
        print("Canvas context menu: empty container at clicked world/screen coordinates, JSON synchronization, existing menus and editing lock passed.")
        window.close()
    }

    private static func checkContainerDragBehavior(_ starter: DiagramProject) {
        var project = starter
        guard var node = project.nodes.first else { fail("Container drag regression needs a node.") }
        node.id = "drag_node"; node.x = 2; node.y = 3; node.width = 1; node.height = 1; node.containerId = nil
        project.nodes = [node]
        project.edges = []
        project.diagram.layoutMode = "manual"
        let style = ContainerStyle(fill: "#E8EEF8", stroke: "#607090", text: "#172238")
        project.containers = [
            DiagramContainer(id: "target_zone", label: "Target", parentId: nil, style: style, x: 7, y: 3, width: 3, height: 2),
            DiagramContainer(id: "empty_zone", label: "Empty", parentId: nil, style: style, x: 10, y: 7, width: 3, height: 2),
        ]
        var layout = DiagramLayout(engine: "dot", edgeRouting: "angled", width: 13, height: 10,
                                   minX: 0, minY: 0,
                                   nodes: [LayoutNode(id: node.id, x: 2, y: 3, width: 1, height: 1)], edges: [])
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        canvas.isGridVisible = false
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFront(nil)
        canvas.update(diagram: project, layout: layout, selection: .project)
        canvas.onSelect = { selection in canvas.update(diagram: project, layout: layout, selection: selection) }
        window.displayIfNeeded()
        var moveResult: (String, Double, Double, String?)?
        canvas.onMoveNode = { id, x, y, containerID in moveResult = (id, x, y, containerID) }
        canvas.onMoveContainer = { _, _, _ in }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1)!
        }
        let source = canvas.screenPoint(for: NSPoint(x: 2, y: 3))
        let inside = canvas.screenPoint(for: NSPoint(x: 7, y: 3))
        canvas.mouseDown(with: event(.leftMouseDown, source, 1))
        canvas.mouseDragged(with: event(.leftMouseDragged, inside, 1))
        canvas.mouseUp(with: event(.leftMouseUp, inside, 1))
        guard moveResult?.0 == node.id, moveResult?.3 == "target_zone" else {
            fail("Dropping a node inside a container must assign that container. Result=\(String(describing: moveResult)).")
        }

        moveResult = nil
        node.containerId = "target_zone"; node.x = 7; node.y = 3
        var anchor = node; anchor.id = "stationary_member"; anchor.x = 6
        project.nodes = [node, anchor]
        layout.nodes = [LayoutNode(id: node.id, x: 7, y: 3, width: 1, height: 1),
                        LayoutNode(id: anchor.id, x: 6, y: 3, width: 1, height: 1)]
        canvas.update(diagram: project, layout: layout, selection: .node(node.id))
        let initialContainerFrame = canvas.containerScreenFrame(for: "target_zone")!
        let attached = canvas.screenPoint(for: NSPoint(x: 7, y: 3))
        let outside = canvas.screenPoint(for: NSPoint(x: 10, y: 3))
        canvas.mouseDown(with: event(.leftMouseDown, attached, 2))
        canvas.mouseDragged(with: event(.leftMouseDragged, outside, 2))
        guard let expanded = canvas.containerScreenFrame(for: "target_zone"), expanded.contains(outside),
              abs(expanded.minX - initialContainerFrame.minX) < 0.01,
              expanded.width > initialContainerFrame.width + 1 else {
            fail("The container must expand around its dragged member before the pointer is released.")
        }
        canvas.mouseUp(with: event(.leftMouseUp, outside, 2))
        guard moveResult?.3 == "target_zone" else {
            fail("Dragging a member beyond the old container boundary must keep its membership. Result=\(String(describing: moveResult)).")
        }

        let modelProbe = AppModel(); modelProbe.diagram = project; modelProbe.layout = layout
        modelProbe.moveNode(node.id, x: 7, y: 3, containerID: "target_zone")
        guard modelProbe.nodes.first?.containerId == "target_zone" else {
            fail("The application model must persist node attachment after a canvas drop.")
        }
        modelProbe.moveNode(node.id, x: 10, y: 3, containerID: nil)
        guard modelProbe.nodes.first?.containerId == "target_zone", modelProbe.nodes.first?.x == 10 else {
            fail("A movement callback must preserve container membership while updating position.")
        }
        modelProbe.moveNode(node.id, x: 10, y: 3, containerID: "empty_zone")
        guard modelProbe.nodes.first?.containerId == "target_zone" else {
            fail("Dragging an attached member into another container must not reparent it.")
        }
        var detachedID: String?
        canvas.onDetachNodeFromContainer = { id in detachedID = id; modelProbe.detachNodeFromContainer(id) }
        guard let detach = canvas.detachContainerMenuItem(for: node.id), let action = detach.action else {
            fail("Attached nodes must have a context menu action to remove container membership.")
        }
        _ = NSApp.sendAction(action, to: detach.target, from: detach)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let saved = try? decoder.decode(DiagramProject.self, from: Data(modelProbe.jsonDraft.utf8))
        guard detachedID == node.id, modelProbe.nodes.first?.containerId == nil,
              modelProbe.nodes.first?.x == 10, modelProbe.nodes.first?.y == 3,
              saved?.nodes.first?.containerId == nil, saved?.nodes.first?.x == 10 else {
            fail("Explicit detachment must update JSON without changing node position.")
        }

        guard let originalFrame = canvas.containerScreenFrame(for: "empty_zone") else {
            fail("Empty container frame is needed for live drag preview regression.")
        }
        let containerStart = NSPoint(x: originalFrame.midX, y: originalFrame.midY)
        let containerEnd = NSPoint(x: containerStart.x + 36, y: containerStart.y + 24)
        canvas.mouseDown(with: event(.leftMouseDown, containerStart, 3))
        canvas.mouseDragged(with: event(.leftMouseDragged, containerEnd, 3))
        guard let previewFrame = canvas.containerScreenFrame(for: "empty_zone"),
              abs(previewFrame.midX - containerStart.x - 36) < 1,
              abs(previewFrame.midY - containerStart.y - 24) < 1 else {
            fail("An empty container must visibly follow the pointer before mouse-up. Original=\(originalFrame), preview=\(String(describing: canvas.containerScreenFrame(for: "empty_zone"))).")
        }
        canvas.mouseUp(with: event(.leftMouseUp, containerEnd, 3))
        window.close()
    }

    private static func checkEmptyContainerDragThroughController(_ starter: DiagramProject) {
        var project = starter
        project.nodes = []; project.edges = []
        project.diagram.layoutMode = "manual"
        project.containers = [DiagramContainer(id: "empty", label: "Empty drag preview", parentId: nil,
            style: ContainerStyle(fill: "#FFFFFF", stroke: "#FF0000", text: "#172238"),
            x: 4, y: 3, width: 3, height: 2)]
        let model = AppModel(); model.diagram = project
        model.layout = DiagramLayout(engine: "neato", width: 8, height: 6, minX: 0, minY: 0, nodes: [], edges: [])
        let controller = MainWindowController(model: model)
        controller.refreshAll(); controller.showWindow(nil)
        guard let window = controller.window, let root = window.contentView,
              let canvas = findView(identifier: "diagram-canvas", in: root) as? DiagramCanvasView else {
            fail("Container preview regression needs the real controller and canvas.")
        }
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        for delta in [NSPoint(x: 36, y: 24), NSPoint(x: -36, y: 0), NSPoint(x: 0, y: -24)] {
            guard let before = canvas.containerScreenFrame(for: "empty"), let original = model.containers.first else {
                fail("Empty container fixture must have a visible frame.")
            }
            let start = NSPoint(x: before.midX, y: before.midY)
            let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
            canvas.mouseDown(with: event(.leftMouseDown, start))
            canvas.mouseDragged(with: event(.leftMouseDragged, end))
            controller.refreshAll() // A selection/status refresh must preserve the live preview.
            window.displayIfNeeded()
            guard let preview = canvas.containerScreenFrame(for: "empty"),
                  abs(preview.midX - before.midX - delta.x) < 0.01,
                  abs(preview.midY - before.midY - delta.y) < 0.01,
                  model.containers.first?.x == original.x, model.containers.first?.y == original.y else {
                fail("An empty container must follow the pointer through controller refreshes before committing.")
            }
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { fail("Cannot capture empty container preview.") }
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let border = NSPoint(x: preview.maxX, y: preview.midY)
            let pixelX = Int((border.x * CGFloat(bitmap.pixelsWide) / canvas.bounds.width).rounded())
            let pixelY = Int((border.y * CGFloat(bitmap.pixelsHigh) / canvas.bounds.height).rounded())
            let borderVisible = [pixelY, bitmap.pixelsHigh - pixelY].contains { y in
                (-2...2).contains { dx in
                    let x = pixelX + dx
                    guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
                          let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.7 && color.greenComponent < 0.35 && color.blueComponent < 0.35
                }
            }
            guard borderVisible else { fail("The dragged empty container border must be painted at its preview coordinates before mouse-up.") }
            capture(canvas, name: "empty-container-live-drag")
            let expected = canvas.worldPoint(for: end)
            canvas.mouseUp(with: event(.leftMouseUp, end))
            guard let committed = model.containers.first,
                  abs((committed.x ?? 0) - expected.x) < 1e-6,
                  abs((committed.y ?? 0) - expected.y) < 1e-6,
                  let frame = canvas.containerScreenFrame(for: "empty"),
                  abs(frame.midX - preview.midX) < 0.01, abs(frame.midY - preview.midY) < 0.01 else {
                fail("Mouse-up must commit the preview position without a visible jump.")
            }
        }
        window.close()
    }

    private static func checkCanvasControlGeometry(_ starter: DiagramProject) {
        var project = starter
        var source = starter.nodes[0]; source.id = "control_source"; source.icon = nil; source.shape = "box"
        source.containerId = nil; source.width = 2; source.height = 1; source.x = 2; source.y = 2
        var target = source; target.id = "control_target"; target.x = 6
        project.nodes = [source, target]; project.containers = []; project.edges = []; project.diagram.layoutMode = "manual"
        let layout = DiagramLayout(engine: "neato", width: 8, height: 4, minX: 0, minY: 0,
            nodes: [LayoutNode(id: source.id, x: 2, y: 2, width: 2, height: 1),
                    LayoutNode(id: target.id, x: 6, y: 2, width: 2, height: 1)], edges: [])
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas; window.orderFront(nil)
        canvas.update(diagram: project, layout: layout, selection: .node(source.id)); window.displayIfNeeded()
        guard let controls = canvas.nodeControlFrames(for: source.id),
              controls.resize.width == controls.resize.height,
              controls.resize.size == controls.connection.size,
              abs(controls.resize.midX - controls.connection.midX) < 0.01,
              !controls.resize.intersects(controls.connection) else { fail("Circular canvas controls must have equal size, align vertically, and remain separate.") }
        let center = NSPoint(x: controls.resize.midX, y: controls.resize.midY)
        let triangles = DiagramCanvasView.resizeGlyphTriangles(center: center)
        let outward = NSPoint(x: 24, y: -24)
        guard triangles.count == 2, triangles.allSatisfy({ $0.count == 3 }),
              triangles.allSatisfy({ triangle in
                  let tip = triangle[0], rear = NSPoint(x: (triangle[1].x + triangle[2].x) / 2, y: (triangle[1].y + triangle[2].y) / 2)
                  let axis = NSPoint(x: tip.x - rear.x, y: tip.y - rear.y)
                  return abs(axis.x * outward.y - axis.y * outward.x) < 1e-6
              }), (triangles[0][0].x - center.x) * (triangles[1][0].x - center.x) < 0 else {
            fail("Scale triangles must face opposite ways along the pointer's outward/inward resize diagonal.")
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        for direction in [CGFloat(1), CGFloat(-1)] {
            canvas.update(diagram: project, layout: layout, selection: .node(source.id))
            var resized: (Double, Double)?
            canvas.onResizeNode = { _, width, height in resized = (width, height) }
            let control = canvas.nodeControlFrames(for: source.id)!.resize
            let start = NSPoint(x: control.midX, y: control.midY)
            let end = NSPoint(x: start.x + direction * outward.x, y: start.y + direction * outward.y)
            canvas.mouseDown(with: event(.leftMouseDown, start)); canvas.mouseDragged(with: event(.leftMouseDragged, end))
            canvas.mouseUp(with: event(.leftMouseUp, end))
            guard let resized, direction * (resized.0 - 2) > 0, direction * (resized.1 - 1) > 0 else {
                fail("Dragging the visible resize circle along either triangle must grow/shrink both dimensions.")
            }
            // Commit the callback result so the next interaction starts from canonical geometry.
            project.nodes[0].width = resized.0; project.nodes[0].height = resized.1
            canvas.update(diagram: project, layout: layout, selection: .node(source.id))
            project.nodes[0] = source
            canvas.update(diagram: project, layout: layout, selection: .node(source.id))
        }
        var connection: (String, String)?
        canvas.onCreateEdge = { connection = ($0, $1) }
        let start = NSPoint(x: controls.connection.midX, y: controls.connection.midY)
        let end = canvas.screenPoint(for: NSPoint(x: 6, y: 2))
        canvas.mouseDown(with: event(.leftMouseDown, start)); canvas.mouseDragged(with: event(.leftMouseDragged, end))
        canvas.mouseUp(with: event(.leftMouseUp, end))
        guard connection?.0 == source.id, connection?.1 == target.id else { fail("Dragging the visible connection circle must create a connection, without resizing the node.") }
        capture(canvas, name: "canvas-circular-controls")
        window.close()
    }

    private static func checkTrackpadNavigation() {
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // Device coordinates for natural scrolling: right/up fingers produce +X/-Y.
        // With natural scrolling disabled, macOS reverses both event deltas.
        let motions = [NSPoint(x: 12, y: 0), NSPoint(x: -12, y: 0), NSPoint(x: 0, y: 9),
                       NSPoint(x: 0, y: -9), NSPoint(x: 12, y: 9), NSPoint(x: -12, y: -9),
                       NSPoint(x: 12, y: -9), NSPoint(x: -12, y: 9)]
        for natural in [true, false] {
            for inverse in [false, true] {
                canvas.inverseTrackpad = inverse
                for fingers in motions {
                    let sign: CGFloat = natural ? 1 : -1
                    let event = CanvasScrollFixtureEvent(delta: NSPoint(x: sign * fingers.x, y: -sign * fingers.y), natural: natural)
                    let before = canvas.screenPoint(for: .zero)
                    canvas.scrollWheel(with: event)
                    let after = canvas.screenPoint(for: .zero)
                    let expected: CGFloat = inverse ? -1 : 1
                    guard abs(after.x - before.x - expected * fingers.x) < 1e-6,
                          abs(after.y - before.y - expected * fingers.y) < 1e-6 else {
                        fail("Canvas must follow physical fingers on BOTH axes: fingers=\(fingers), natural=\(natural), inverse=\(inverse), movement=\(NSPoint(x: after.x - before.x, y: after.y - before.y)).")
                    }
                }
            }
        }
    }

    private static func checkProjectPropertiesSpacing(styleWindow: NSWindow?) {
        guard let window = styleWindow, let content = window.contentView,
              let title = findView(identifier: "inspector-title", in: content),
              let firstSection = findView(identifier: "inspector-section-СВЕДЕНИЯ", in: content) else {
            fail("Project properties need a header and the first settings section.")
        }
        let originalSize = content.bounds.size
        for height in [originalSize.height, CGFloat(740)] {
            window.setContentSize(NSSize(width: originalSize.width, height: height))
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let titleFrame = title.convert(title.bounds, to: content)
            let sectionFrame = firstSection.convert(firstSection.bounds, to: content)
            let gap = titleFrame.minY - sectionFrame.maxY
            guard gap >= 0, gap <= 28 else {
                fail("Project property fields must stay within 2em of the header at every window height: gap=\(gap), title=\(titleFrame), section=\(sectionFrame).")
            }
            print("Project properties: height=\(height), header-to-fields gap=\(gap)pt (limit 28pt).")
        }
        window.setContentSize(originalSize)
        content.layoutSubtreeIfNeeded()
        capture(content, name: "compact-project-properties")
    }

    private static func checkNodeStackContextMenu() {
        let canvas = DiagramCanvasView(frame: .zero)
        let titles = canvas.nodeStackMenuItems(for: "fixture")
        guard titles.map(\.title) == ["Переместить на передний план", "Переместить на задний план", "Указать z-index…"],
              titles.allSatisfy({ $0.representedObject as? String == "fixture" && $0.target === canvas }) else {
            fail("Node context menu must provide forward, back and manual z-index actions for the selected node.")
        }
    }

    private static func checkSynchronizedGroupScaling(_ project: DiagramProject) {
        guard project.nodes.count >= 2 else { fail("Group scaling smoke test needs at least two nodes.") }
        let probe = AppModel()
        probe.diagram = project
        let positions = project.nodes.enumerated().map { index, node in
            LayoutNode(id: node.id, x: Double(index * 3), y: 2,
                       width: node.width ?? 2, height: node.height ?? 1)
        }
        probe.layout = DiagramLayout(engine: project.diagram.layoutEngine, edgeRouting: project.diagram.edgeRouting,
                                     width: Double(project.nodes.count * 3), height: 4, minX: 0, minY: 0,
                                     nodes: positions, edges: [])
        let ids = Set(project.nodes.prefix(2).map(\.id))
        let original = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        probe.scaleNodes(ids, factor: 1.25)
        guard let scaled = probe.diagram?.nodes,
              scaled.allSatisfy({ node in
                  guard let position = positions.first(where: { $0.id == node.id }),
                        let before = original[node.id] else { return false }
                  let expectedWidth = before.width ?? position.width
                  let expectedHeight = before.height ?? position.height
                  if ids.contains(node.id) {
                      return abs((node.width ?? 0) - expectedWidth * 1.25) < 1e-6
                          && abs((node.height ?? 0) - expectedHeight * 1.25) < 1e-6
                          && node.x == position.x && node.y == position.y
                  }
                  return node.x == position.x && node.y == position.y
                      && node.width == before.width && node.height == before.height
              }) else {
            fail("Group resize must scale each selected shape by one factor without shifting node centers.")
        }
    }

    private static func checkArrowheadTouchesVisibleNode(_ project: DiagramProject) {
        guard var edge = project.edges.first,
              let source = project.nodes.first(where: { $0.id == edge.source }),
              let target = project.nodes.first(where: { $0.id == edge.target }) else {
            fail("Arrow rendering smoke test requires a connected node pair.")
        }
        var arrowProject = project
        var sourceNode = source
        var targetNode = target
        sourceNode.icon = nil; sourceNode.shape = "box"; sourceNode.label = ""
        sourceNode.width = 1.4; sourceNode.height = 1.2; sourceNode.x = 4; sourceNode.y = 1
        sourceNode.style.fill = "#FFFFFF"; sourceNode.style.stroke = "#00AA00"; sourceNode.style.penwidth = 5
        targetNode.icon = nil; targetNode.shape = "box"; targetNode.label = ""
        targetNode.width = 1.4; targetNode.height = 1.2; targetNode.x = 1; targetNode.y = 1
        targetNode.style.fill = "#FFFFFF"; targetNode.style.stroke = "#00AA00"; targetNode.style.penwidth = 5
        arrowProject.nodes = [sourceNode, targetNode]
        arrowProject.containers = []
        arrowProject.diagram.layoutMode = "manual"
        arrowProject.diagram.direction = "RL"
        arrowProject.diagram.edgeRouting = "angled"
        arrowProject.presentation.theme = "light"
        arrowProject.presentation.background = "#FFFFFF"
        edge.direction = "forward"
        edge.routing = nil
        edge.sourcePort = "auto"
        edge.targetPort = "auto"
        edge.waypoints = []
        edge.style.color = "#FF0000"
        edge.style.penwidth = 2
        edge.style.arrowhead = "normal"
        edge.style.arrowtail = "none"
        arrowProject.edges = [edge]

        let sourcePosition = LayoutNode(id: source.id, x: 4, y: 1, width: 1.4, height: 1.2)
        let targetPosition = LayoutNode(id: target.id, x: 1, y: 1, width: 1.4, height: 1.2)
        let geometry = LayoutEdge(id: edge.id, source: source.id, target: target.id,
                                  points: [LayoutPoint(x: 1.7, y: 1), LayoutPoint(x: 3.5, y: 1),
                                           LayoutPoint(x: 1.4, y: 1), LayoutPoint(x: 3.3, y: 1)], label: "")
        let layout = DiagramLayout(engine: "neato", edgeRouting: "angled", width: 5.5, height: 3,
                                   minX: 0, minY: 0, nodes: [sourcePosition, targetPosition], edges: [geometry])
        let canvas = DiagramCanvasView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        canvas.isGridVisible = false
        canvas.fitToContent()
        var route: [NSPoint] = []
        for routing in ["straight", "angled", "curved"] {
            var routedProject = arrowProject
            routedProject.diagram.edgeRouting = routing
            var routedLayout = layout
            routedLayout.edgeRouting = routing
            canvas.update(diagram: routedProject, layout: routedLayout, selection: .project)
            route = canvas.edgePoints(for: edge.id)
            guard let tip = route.last, route.count > 1 else { fail("Arrow endpoint geometry is missing for \(routing).") }
            let previous = route[route.count-2]
            let inward = NSPoint(x: targetPosition.x-tip.x, y: targetPosition.y-tip.y)
            let tangent = NSPoint(x: tip.x-previous.x, y: tip.y-previous.y)
            guard let drawing = canvas.edgeDrawing(for: edge.id), let marker = drawing.head,
                  drawing.shaft.count > 1 else { fail("Missing rendered arrow geometry for \(routing).") }
            let vertices = marker.polygon
            let rear = NSPoint(x: (vertices[1].x+vertices[2].x)/2, y: (vertices[1].y+vertices[2].y)/2)
            let end = drawing.shaft.last!, previousEnd = drawing.shaft[drawing.shaft.count-2]
            let axis = NSPoint(x: marker.tip.x-rear.x, y: marker.tip.y-rear.y)
            let approach = NSPoint(x: end.x-previousEnd.x, y: end.y-previousEnd.y)
            guard tangent.x*inward.x + tangent.y*inward.y > 0,
                  hypot(end.x-rear.x, end.y-rear.y) < 1e-6,
                  abs(axis.x*approach.y-axis.y*approach.x) < 1e-6,
                  axis.x*approach.x+axis.y*approach.y > 0 else {
                fail("The \(routing) shaft must end at the centre of the arrow's rear edge and enter from behind, including right-to-left routes.")
            }
        }
        arrowProject.diagram.edgeRouting = "angled"
        canvas.update(diagram: arrowProject, layout: layout, selection: .project)
        route = canvas.edgePoints(for: edge.id)
        guard let tip = route.last else { fail("Arrow endpoint geometry is missing.") }
        let screenTip = canvas.screenPoint(for: tip)
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            fail("Cannot rasterize arrow rendering smoke fixture.")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        capture(canvas, name: "arrow-render-order")
        let pixelX = Int((screenTip.x * CGFloat(bitmap.pixelsWide) / max(1, canvas.bounds.width)).rounded())
        let pixelY = Int((screenTip.y * CGFloat(bitmap.pixelsHigh) / max(1, canvas.bounds.height)).rounded())
        let ySamples = [pixelY, bitmap.pixelsHigh - pixelY]
        let visibleArrowPixels = ySamples.flatMap { y in
            (-2...2).flatMap { dy in
                (-2...2).compactMap { dx -> NSColor? in
                    let x = pixelX + dx, sampleY = y + dy
                    guard x >= 0, x < bitmap.pixelsWide, sampleY >= 0, sampleY < bitmap.pixelsHigh else { return nil }
                    return bitmap.colorAt(x: x, y: sampleY)?.usingColorSpace(.deviceRGB)
                }
            }
        }.contains { $0.redComponent > 0.7 && $0.greenComponent < 0.35 && $0.blueComponent < 0.35 }
        guard visibleArrowPixels else {
            fail("The arrow tip must remain visible over the target outline at its actual attachment point (tip=\(screenTip), pixel=\(pixelX),\(pixelY)).")
        }
    }

    private static func checkToolbarOverflow(mainWindow: MainWindowController, root: NSView) {
        guard let window = mainWindow.window,
              let toolbar = findView(identifier: "workspace-toolbar-scroll", in: root) as? NSScrollView else {
            fail("Workspace toolbar must be hosted in a horizontal scroll view.")
        }
        let originalSize = root.bounds.size
        window.setContentSize(NSSize(width: 1_100, height: max(640, originalSize.height)))
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let documentWidth = toolbar.documentView?.frame.width ?? 0
        let viewportWidth = toolbar.contentView.bounds.width
        guard toolbar.hasHorizontalScroller, documentWidth > viewportWidth + 40 else {
            fail("Workspace toolbar must scroll horizontally when side panels leave limited room.")
        }
        window.setContentSize(originalSize)
        root.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func checkPDFOptions(mainWindow: MainWindowController) {
        guard let window = mainWindow.window,
              let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Файл" })?.submenu,
              let export = fileMenu.items.first(where: { $0.title == "Экспортировать PDF…" }),
              let action = export.action else { fail("PDF export menu action is missing.") }
        _ = NSApp.sendAction(action, to: export.target, from: export)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let alert = mainWindow.pendingPDFExportAlert,
              let options = alert.accessoryView,
              let alertContent = alert.window.contentView else {
            fail("PDF export must create a settings alert before the save panel.")
        }
        options.layoutSubtreeIfNeeded()
        let page = findView(identifier: "pdf-page-format", in: options) as? NSPopUpButton
        let helpWidth = findView(identifier: "pdf-page-size-help", in: options)?.frame.width ?? 0
        let legend = findView(identifier: "pdf-include-legend", in: options) as? NSButton
        let cancel = findButton(title: "Отмена", in: alertContent)
        guard options.frame.width >= 360, options.frame.height >= 100,
              page?.itemArray.count == 3, helpWidth > 0, legend != nil, cancel != nil else {
            fail("PDF options sheet must expose page format and legend controls. options=\(options.frame), pageItems=\(page?.itemArray.count ?? -1), help=\(helpWidth), legend=\(legend?.frame ?? .zero), cancel=\(cancel?.title ?? "missing").")
        }
        perform(cancel!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if window.attachedSheet != nil { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }

    private static func checkLongPressTextEditor(mainWindow: MainWindowController, root: NSView, nodeID: String) {
        guard let window = mainWindow.window,
              let canvas = findView(identifier: "diagram-canvas", in: root) as? DiagramCanvasView,
              let position = canvas.nodePositions.first(where: { $0.id == nodeID }) else {
            fail("Canvas node position is required for the long-press text-editor test.")
        }
        let point = canvas.screenPoint(for: NSPoint(x: position.x, y: position.y))
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(point, to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 31, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: down)
        RunLoop.main.run(until: Date().addingTimeInterval(0.72))
        guard let editor = NSApp.windows.first(where: { $0.title == "Текст фигуры" }),
              editor.isVisible,
              findView(identifier: "node-text-value", in: editor.contentView ?? NSView()) is NSTextField else {
            fail("Holding the trackpad press on a node must open the text editor.")
        }
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: canvas.convert(point, to: nil),
                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 32, clickCount: 1, pressure: 0)!
        canvas.mouseUp(with: up)
        editor.close()
    }

    private static func findButton(title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for child in view.subviews {
            if let match = findButton(title: title, in: child) { return match }
        }
        return nil
    }

    private static func checkNewCanvasFeatures(model: AppModel, controller: MainWindowController, assistant: OllamaAssistantWindowController,
                                               root: NSView, inspector: NSView, firstPaletteTile: NSView?) {
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
              canvas.nodePositions.contains(where: { $0.id == cloud.id }) else { fail("Cloud geometry missing") }
        controller.refreshAll()
        canvas.displayIfNeeded()
        guard canvas.toolTip?.contains("Стрелка справа создаёт связь") == true,
              canvas.toolTip?.contains("значок масштабирует объект") == true else {
            fail("Selected node controls must identify the connection arrow and scale glyph.")
        }
        guard let cloudControl = canvas.nodeControlFrames(for: cloud.id)?.resize else { fail("Selected cloud must have a resize circle.") }
        let handle = NSPoint(x: cloudControl.midX, y: cloudControl.midY)
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
        let naturalFollowDelta = DiagramCanvasView.scrollOffsetDelta(x: 6, y: -4, precise: true, natural: true, inverse: false)
        let naturalInverseDelta = DiagramCanvasView.scrollOffsetDelta(x: 6, y: -4, precise: true, natural: true, inverse: true)
        let systemInverseDelta = DiagramCanvasView.scrollOffsetDelta(x: 6, y: -4, precise: true, natural: false, inverse: true)
        let systemDirectionDelta = DiagramCanvasView.scrollOffsetDelta(x: 6, y: -4, precise: true, natural: false, inverse: false)
        guard canvas.inverseTrackpad,
              DiagramCanvasView.scrollDirection(precise: true, natural: true, inverse: false) == 1,
              DiagramCanvasView.scrollDirection(precise: true, natural: false, inverse: false) == -1,
              DiagramCanvasView.scrollDirection(precise: true, natural: true, inverse: true) == -1,
              DiagramCanvasView.scrollDirection(precise: true, natural: false, inverse: true) == 1,
              DiagramCanvasView.scrollDirection(precise: false, natural: true, inverse: true) == 1,
              naturalFollowDelta == NSPoint(x: 6, y: 4),
              naturalInverseDelta == NSPoint(x: -6, y: -4),
              systemInverseDelta == NSPoint(x: 6, y: 4),
              systemDirectionDelta == NSPoint(x: -6, y: -4) else {
            fail("Trackpad inversion must convert device Y-down to canvas Y-up and apply the same physical direction to both axes")
        }
        model.inverseTrackpad = false
        guard !canvas.inverseTrackpad else { fail("Navigation preference must apply immediately") }

        canvas.fitToContent()
        model.updateThemeMode("dark")
        guard model.diagram?.presentation.theme == "dark", model.diagram?.presentation.background == "#21172F",
              root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              assistant.window?.contentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              let text = findTextView(containing: "schema_version", in: root), text.backgroundColor.hexRGB == "#21172F" else {
            fail("Night theme must cover the editor and auxiliary windows: theme=\(model.diagram?.presentation.theme ?? "nil"), background=\(model.diagram?.presentation.background ?? "nil"), root=\(root.effectiveAppearance.name.rawValue), assistant=\(assistant.window?.contentView?.effectiveAppearance.name.rawValue ?? "nil"), editor=\(findTextView(containing: "schema_version", in: root)?.backgroundColor.hexRGB ?? "nil")")
        }
        capture(root, name: "native-night")
        model.updateThemeMode("light")
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
        model.updateThemeMode("dark")
        guard variableRoot.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
              value.backgroundColor.hexRGB == "#21172F" else { fail("Variables window must follow the project theme") }
        capture(variableRoot, name: "prompt-variables-night")
        model.updateThemeMode("light")
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
