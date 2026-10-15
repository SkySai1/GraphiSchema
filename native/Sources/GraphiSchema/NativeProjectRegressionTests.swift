import AppKit
import Darwin

/// Runs against an ephemeral real backend and actual AppKit views. Never opens user data.
@MainActor
enum NativeProjectRegressionTests {
    private struct Failure: Error { var message: String }
    private static var checks = 0
    private static var windows: [NSWindowController] = []
    private static func expect(_ value: Bool, _ message: String) throws {
        checks += 1; if !value { throw Failure(message: message) }
    }
    static func run() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        Task { @MainActor in
            let backend = BackendService()
            do {
                stage("settings and alignment"); try checkSettings(); try checkAlignment()
                let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let starter = try decoder.decode(DiagramProject.self, from: Data(contentsOf: root.appendingPathComponent("examples/starter.json")))
                stage("smooth routes"); try checkSmoothRoutes(starter)
                stage("54 rasterized fills"); try checkEveryFigureFill(starter)
                stage("canvas selection and long press"); try await checkCanvasSelectionAndLongPress(starter)
                stage("startup and transient canvases"); try await checkStartupAndTransientProjects(backend)
                stage("real projects and windows"); try await checkProjectsAndWindows(backend)
                stage("project trash and permanent removal"); try await checkProjectTrash(backend)
                stage("relative border spacing"); checks += try await NativeBorderRegressionTests.run(starter, backend: backend)
                windows.forEach { $0.close() }
                backend.stop()
                print("Native project regressions passed: \(checks) checks; isolated settings, startup, real API, projects, branches, trash, permanent removal, windows, palettes, edge groups, guides, 54 figure fills, smooth ports and long press.")
                exit(0)
            } catch {
                windows.forEach { $0.close() }; backend.stop()
                let message = (error as? Failure)?.message ?? error.localizedDescription
                FileHandle.standardError.write(Data("Native project regression failed: \(message)\n".utf8)); exit(1)
            }
        }
        app.run()
    }
    private static func stage(_ name: String) { FileHandle.standardOutput.write(Data("Project regression: \(name)\n".utf8)) }
    private static func checkSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graphischema-settings-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SettingsStore(directory: directory, migrateLegacy: false), second = SettingsStore(directory: directory, migrateLegacy: false)
        first.set("A", forKey: "first"); second.set(true, forKey: "second"); first.set(Data([0,1,2,255]), forKey: "bytes")
        try expect(second.string(forKey: "first") == "A" && first.bool(forKey: "second"), "Settings instances must merge independent writes.")
        try expect(second.data(forKey: "bytes") == Data([0,1,2,255]), "Settings Data must roundtrip.")
        let permissions = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o600, "Settings must have private file permissions.")
        let old = try Data(contentsOf: first.fileURL)
        let before = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.modificationDate] as? Date
        first.set("A", forKey: "first")
        let after = try FileManager.default.attributesOfItem(atPath: first.fileURL.path)[.modificationDate] as? Date
        try expect(before == after, "Repeated state refresh must not rewrite settings.")
        let invalid = Data("invalid JSON".utf8); try invalid.write(to: first.fileURL)
        second.set("must not overwrite", forKey: "unsafe")
        try expect(second.lastError != nil && (try? Data(contentsOf: first.fileURL)) == invalid, "Corrupt settings must remain recoverable.")
        try old.write(to: first.fileURL); first.removeObject(forKey: "first")
        try expect(second.string(forKey: "first") == nil && second.bool(forKey: "second"), "Removing one setting must preserve others.")
        let repository=directory.appendingPathComponent("projects")
        try expect(BackendService.matchesDataDirectory(repository.path,expected:repository), "A backend may reuse only the configured repository.")
        try expect(!BackendService.matchesDataDirectory(directory.appendingPathComponent("other").path,expected:repository), "A compatible backend with another repository must not be reused.")
        try expect(!BackendService.matchesDataDirectory(nil,expected:repository), "A backend without an explicit repository path must not be reused.")
        try expect(SettingsStore.shared.directory.path.contains("graphischema-settings-"), "Native tests must isolate real settings.")
        try expect(StartupPreferences.mode(in: first) == .lastProject && StartupPreferences.workspaceToRestore(in: first) == nil,
                   "Default startup restores the last project, falling back to a blank canvas when absent.")
        let saved = ProjectWorkspace(projectId: "project_saved", branchId: "branch_saved")
        first.set(try JSONEncoder().encode(saved), forKey: StartupPreferences.lastWorkspaceKey)
        try expect(StartupPreferences.workspaceToRestore(in: second) == saved, "Last project and its branch must survive settings reload.")
        second.set(StartupWindowMode.emptyCanvas.rawValue, forKey: StartupPreferences.modeKey)
        try expect(StartupPreferences.mode(in: first) == .emptyCanvas && StartupPreferences.workspaceToRestore(in: first) == nil,
                   "Empty startup must ignore the remembered project without deleting it.")
        first.set(StartupWindowMode.lastProject.rawValue, forKey: StartupPreferences.modeKey)
        try expect(StartupPreferences.workspaceToRestore(in: second) == saved, "Switching startup back must restore the previous project.")
        first.set("unknown", forKey: StartupPreferences.modeKey)
        try expect(StartupPreferences.mode(in: second) == .lastProject, "Invalid startup settings must use the safe default.")
    }
    private static func checkAlignment() throws {
        for scale in [CGFloat(12),72,160,300] {
            let body = NSRect(x: 0,y: 0,width: 10,height: 10), peer = NSRect(x: 3,y: 2,width: 10,height: 10)
            let tolerance = 6/scale
            let delta = NSPoint(x: 3+tolerance*0.8,y: 2-tolerance*0.8)
            let snapped = DiagramAlignment.snap(moving: body, peers: [peer], delta: delta, scale: scale, enabled: true)
            try expect(abs(snapped.delta.x-3)<1e-8 && abs(snapped.delta.y-2)<1e-8, "Screen-sized snapping tolerance at \(scale).")
            let disabled = DiagramAlignment.snap(moving: body, peers: [peer], delta: delta, scale: scale, enabled: false)
            try expect(disabled.delta == delta && disabled.vertical == nil && disabled.horizontal == nil, "Disabled snapping cannot change motion.")
            let locked = DiagramAlignment.snap(moving: body, peers: [peer], delta: delta, scale: scale, enabled: true, lockedHorizontal: true)
            try expect(locked.delta.y == delta.y && locked.horizontal == nil, "Shift axis lock must suppress cross-axis snapping.")
            let distant = DiagramAlignment.snap(moving: body, peers: [peer], delta: .init(x: 3+tolerance*1.1,y: 2), scale: scale, enabled: true)
            try expect(distant.vertical == nil, "Objects outside the screen tolerance cannot snap.")
        }
        let clip=NSRect(x: 1,y: 1,width: 1,height: 1)
        try expect(CanvasGeometry.segmentIntersectsRect(.init(x: 0,y: 1.5),.init(x: 3,y: 1.5),clip), "Marquee must select a crossing line even when both endpoints are outside.")
        try expect(!CanvasGeometry.segmentIntersectsRect(.init(x: 0,y: 1),.init(x: 1,y: 3),clip), "Marquee must not select a diagonal whose bounding box alone intersects.")
        let result = DiagramAlignment.snap(moving: NSRect(x: 0,y: 0,width: 3,height: 2), peers: [NSRect(x: 5,y: 3,width: 2,height: 2)], delta: .init(x: 4.54,y: 3.03), scale: 72, enabled: true)
        try expect(abs(result.delta.x-4.5)<1e-8 && abs(result.delta.y-3)<1e-8, "A group snaps as one union without changing internal spacing.")
    }
    private static func checkSmoothRoutes(_ starter: DiagramProject) throws {
        let source = LayoutNode(id: "a",x: 0,y: 0,width: 1.4,height: 1)
        let target = LayoutNode(id: "b",x: 4,y: 2,width: 1.4,height: 1)
        var a=starter.nodes[0], b=starter.nodes[0]; a.id="a"; b.id="b"; a.icon=nil; b.icon=nil; a.shape="box";b.shape="box"
        var settings=starter.diagram;settings.edgeRouting="curved"
        let ports=["n","ne","e","se","s","sw","w","nw","vertex:0","vertex:2"]
        for from in ports { for to in ports {
            var edge=starter.edges[0];edge.source="a";edge.target="b";edge.sourcePort=from;edge.targetPort=to;edge.routing="curved";edge.waypoints=[]
            let points=CanvasGeometry.edgePoints(edge,source: source,target: target,sourceNode: a,targetNode: b,settings: settings)
            try expect(points.count==97 && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "Fixed ports must produce one sampled cubic: \(from)/\(to).")
            for (tip,next,center) in [(points[0],points[1],NSPoint(x: 0,y: 0)),(points.last!,points[points.count-2],NSPoint(x: 4,y: 2))] {
                let nx=tip.x-center.x,ny=tip.y-center.y,dx=next.x-tip.x,dy=next.y-tip.y
                try expect((nx*dx+ny*dy)/(hypot(nx,ny)*hypot(dx,dy)) > 0.985, "Curve tangent must leave the port outward: \(from)/\(to).")
            }
        } }
        let route=CanvasGeometry.smoothRoute([.init(x: 0,y: 0),.init(x: 1,y: 2),.init(x: 3,y: 1),.init(x: 5,y: 3)])
        for index in [96,192] {
            let before=route[index-1], at=route[index], after=route[index+1]
            let u=NSPoint(x: at.x-before.x,y: at.y-before.y),v=NSPoint(x: after.x-at.x,y: after.y-at.y)
            try expect((u.x*v.x+u.y*v.y)/(hypot(u.x,u.y)*hypot(v.x,v.y)) > 0.995, "Waypoint joins must be tangent-continuous.")
        }
    }
    private static func checkEveryFigureFill(_ starter: DiagramProject) throws {
        let canvas=DiagramCanvasView(frame: NSRect(x: 0,y: 0,width: 400,height: 320));canvas.isGridVisible=false
        for icon in CanvasGeometry.icons.keys.sorted() {
            var p=starter;var node=p.nodes[0];node.id="body";node.label=" ";node.icon=icon;node.x=0;node.y=0;node.width=2;node.height=1.8;node.containerId=nil
            node.style.fill="#00FF00";node.style.stroke="#FF0000";node.style.fillMode="custom";node.style.strokeMode="custom"
            p.nodes=[node];p.edges=[];p.containers=[];p.diagram.layoutMode="manual";p.presentation.theme="light";p.presentation.background="#FFFFFF"
            let layout=DiagramLayout(engine:"test",edgeRouting:"angled",width:4,height:4,minX:-2,minY:-2,nodes:[LayoutNode(id:"body",x:0,y:0,width:2,height:1.8)],edges:[])
            canvas.update(diagram:p,layout:layout,selection:.project);canvas.fitToContent(minimumScale:90,maximumScale:90)
            guard let image=canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {throw Failure(message:"No figure bitmap")}
            canvas.cacheDisplay(in:canvas.bounds,to:image)
            var fills=0, strokes=0
            for y in stride(from:0,to:image.pixelsHigh,by:4) { for x in stride(from:0,to:image.pixelsWide,by:4) {
                guard let color=image.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else {continue}
                if color.greenComponent>0.8 && color.redComponent<0.2 && color.blueComponent<0.2 {
                    fills += 1
                    let point=NSPoint(x:(CGFloat(x)+0.5)*canvas.bounds.width/CGFloat(image.pixelsWide),y:canvas.bounds.height-(CGFloat(y)+0.5)*canvas.bounds.height/CGFloat(image.pixelsHigh))
                    if fills % 101 == 1 { try expect(canvas.nodeID(at:point)=="body", "Filled area must be clickable: \(icon).") }
                }
                if color.redComponent>0.8 && color.greenComponent<0.2 && color.blueComponent<0.2 {strokes += 1}
            } }
            try expect(strokes>10,"Every semantic figure stroke must survive fill: \(icon).")
            if CanvasGeometry.icons[icon]?.fillPaths?.isEmpty == false {try expect(fills>20,"Every body must receive fill: \(icon).")}
            else {try expect(fills==0,"Wire-only icons must not acquire a false body: \(icon).")}
        }
    }
    private static func event(_ type: NSEvent.EventType, _ point: NSPoint, _ canvas: DiagramCanvasView, _ window: NSWindow, flags: NSEvent.ModifierFlags=[]) throws -> NSEvent {
        guard let event=NSEvent.mouseEvent(with:type,location:canvas.convert(point,to:nil),modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1) else {throw Failure(message:"Mouse event unavailable")};return event
    }
    private static func checkCanvasSelectionAndLongPress(_ starter: DiagramProject) async throws {
        var p=starter;p.diagram.layoutMode="manual";p.diagram.edgeRouting="straight";p.containers=[]
        var a=p.nodes[0],b=a,c=a;a.id="a";b.id="b";c.id="c"
        for node in [a,b,c] {try expect(!node.label.isEmpty,"Fixture labels")}
        a.x=0;a.y=0;b.x=4;b.y=0;c.x=4;c.y=3
        a.containerId=nil;b.containerId=nil;c.containerId=nil;a.icon=nil;b.icon=nil;c.icon=nil
        a.width=1;a.height=1;b.width=1;b.height=1;c.width=1;c.height=1;p.nodes=[a,b,c]
        var e=p.edges[0],f=e;e.id="ab";e.source="a";e.target="b";e.waypoints=[];e.sourcePort="auto";e.targetPort="auto"
        f=e;f.id="ac";f.target="c";p.edges=[e,f]
        p.containers=[DiagramContainer(id:"empty",label:"Empty",parentId:nil,style:ContainerStyle(fill:"#FFFFFF",stroke:"#111111",text:"#111111"),x:7,y:1,width:2,height:2)]
        let positions=p.nodes.map {LayoutNode(id:$0.id,x:$0.x!,y:$0.y!,width:1,height:1)}
        let layout=DiagramLayout(engine:"test",edgeRouting:"straight",width:10,height:7,minX:-1,minY:-1,nodes:positions,edges:[LayoutEdge(id:"ab",source:"a",target:"b",points:[.init(x:0.5,y:0),.init(x:3.5,y:0)],label:"",labelX:nil,labelY:nil),LayoutEdge(id:"ac",source:"a",target:"c",points:[.init(x:0.5,y:0.5),.init(x:3.5,y:2.5)],label:"",labelX:nil,labelY:nil)])
        let canvas=DiagramCanvasView(frame:NSRect(x:0,y:0,width:1000,height:650));canvas.alignmentGuides=false
        let window=NSWindow(contentRect:canvas.frame,styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=canvas;defer{window.close()}
        canvas.update(diagram:p,layout:layout,selection:.project);canvas.fitToContent(minimumScale:72,maximumScale:72)
        var selected=DiagramSelection.project,edited:DiagramSelection?,moves=0,waypointCommits=0
        canvas.onSetEdgeWaypoints={_,_,_ in waypointCommits += 1}
        canvas.onSelect={selected=$0};canvas.onEditElementText={edited=$0};canvas.onEditNodeText={edited = .node($0)};canvas.onMoveContainer={_,_,_ in moves += 1}
        let first=canvas.screenPoint(for:.init(x:2,y:0)),second=canvas.screenPoint(for:.init(x:2,y:1.5))
        canvas.mouseDown(with:try event(.leftMouseDown,first,canvas,window));canvas.mouseUp(with:try event(.leftMouseUp,first,canvas,window))
        canvas.mouseDown(with:try event(.leftMouseDown,second,canvas,window,flags:.shift));canvas.mouseUp(with:try event(.leftMouseUp,second,canvas,window,flags:.shift))
        try expect(selected == .edges(["ab","ac"]),"Shift click must select multiple connections.")
        let menu=canvas.menu(for:try event(.rightMouseDown,second,canvas,window))
        try expect(selected == .edges(["ab","ac"]) && menu?.items.contains(where:{$0.title=="Наконечник у цели"}) == true,"Context actions must preserve and edit the edge group.")
        for (target,point) in [(DiagramSelection.edge("ab"),first),(.node("a"),canvas.screenPoint(for:.zero))] {
            edited=nil;canvas.update(diagram:p,layout:layout,selection:.project)
            canvas.mouseDown(with:try event(.leftMouseDown,point,canvas,window))
            for _ in 0..<30 { if edited != nil { break }; try await Task.sleep(for:.milliseconds(100)) }
            try expect(edited==target,"Long press must edit \(target); selected=\(selected), edited=\(String(describing: edited)), point=\(point), route=\(canvas.edgePoints(for: "ab")).")
            canvas.mouseUp(with:try event(.leftMouseUp,point,canvas,window))
        }
        canvas.update(diagram:p,layout:layout,selection:.edge("ab"))
        edited=nil;canvas.mouseDown(with:try event(.leftMouseDown,first,canvas,window))
        for _ in 0..<30 { if edited != nil { break }; try await Task.sleep(for:.milliseconds(100)) }
        try expect(edited == .edge("ab"), "Holding a selected edge's route handle must edit text without adding a waypoint.")
        canvas.mouseUp(with:try event(.leftMouseUp,first,canvas,window))
        try expect(waypointCommits==0,"Holding a route handle must not create a waypoint.")
        edited=nil;canvas.mouseDown(with:try event(.leftMouseDown,first,canvas,window))
        let routeDrag=NSPoint(x:first.x+20,y:first.y+30)
        canvas.mouseDragged(with:try event(.leftMouseDragged,routeDrag,canvas,window))
        try await Task.sleep(for:.milliseconds(720))
        canvas.mouseUp(with:try event(.leftMouseUp,routeDrag,canvas,window))
        try expect(edited==nil && waypointCommits==1,"Dragging the route handle must keep editing its path and cancel text editing.")
        canvas.update(diagram:p,layout:layout,selection:.container("empty"))
        guard let frame=canvas.containerScreenFrame(for:"empty") else {throw Failure(message:"No empty frame")}
        let point=NSPoint(x:frame.midX,y:frame.midY)
        edited=nil;canvas.mouseDown(with:try event(.leftMouseDown,point,canvas,window))
        for _ in 0..<30 { if edited != nil { break }; try await Task.sleep(for:.milliseconds(100)) }
        try expect(edited == .container("empty"),"Long press must edit a container.")
        canvas.mouseUp(with:try event(.leftMouseUp,point,canvas,window));try expect(moves==0,"Long press must not move the container.")
        edited=nil;canvas.mouseDown(with:try event(.leftMouseDown,point,canvas,window))
        let moved=NSPoint(x:point.x+30,y:point.y+20);canvas.mouseDragged(with:try event(.leftMouseDragged,moved,canvas,window));try await Task.sleep(for:.milliseconds(720))
        try expect(edited==nil,"Dragging must cancel delayed text editing.");canvas.mouseUp(with:try event(.leftMouseUp,moved,canvas,window))
    }
    private static func find<T:NSView>(_ id:String,_ view:NSView)->T? {
        if view.identifier?.rawValue==id {return view as? T}
        for child in view.subviews {if let result:T=find(id,child){return result}};return nil
    }
    private static func snapshot(_ name: String, _ controller: NSWindowController) async throws {
        guard let window=controller.window, let view=window.contentView else { return }
        let folder=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("dist/quality")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        window.layoutIfNeeded();view.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(180))
        let output=folder.appendingPathComponent(name+".png")
        let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
        capture.arguments=["-x","-o","-l",String(window.windowNumber),output.path]
        capture.standardOutput=FileHandle.nullDevice;capture.standardError=FileHandle.nullDevice
        try capture.run();capture.waitUntilExit()
        if capture.terminationStatus==0 {return}
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {return}
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
        try bitmap.representation(using:.png,properties:[:])?.write(to:output)
        FileHandle.standardOutput.write(Data("Quality capture: offscreen fallback for \(name)\n".utf8))
    }
    private static func checkProjectsAndWindows(_ backend: BackendService) async throws {
        let owner=AppModel(backend:backend);await owner.bootstrap()
        try expect(backend.isReady && owner.diagram != nil,"Real isolated backend must start and decode project.")
        let aWorkspace=try await owner.createProject(title:"Regression A",template:true),bWorkspace=try await owner.createProject(title:"Regression B")
        let a=AppModel(backend:backend,workspace:aWorkspace),b=AppModel(backend:backend,workspace:bWorkspace)
        await a.bootstrap();await b.bootstrap()
        let aWindow=MainWindowController(model:a),bWindow=MainWindowController(model:b);windows += [aWindow,bWindow]
        aWindow.showWindow(nil);bWindow.showWindow(nil);aWindow.refreshAll();bWindow.refreshAll()
        try expect(a.projectID != b.projectID && aWindow.window !== bWindow.window,"Projects need independent models and windows.")
        a.updateTitle("Window A edit");b.updateTitle("Window B edit");try await a.saveNow();try await b.saveNow()
        let aTree=try await a.fetchCommitTree(),bTree=try await b.fetchCommitTree()
        try expect(aTree.commits.allSatisfy{$0.projectId==a.projectID} && bTree.commits.allSatisfy{$0.projectId==b.projectID},"Version trees cannot mix projects.")
        let original=aTree.commits.last!.id,mainHead=a.headVersionID
        let fork=try await a.createBranch(name:"experiment",fromVersionID:original)
        let branch=AppModel(backend:backend,workspace:fork);await branch.bootstrap()
        let branchWindow=MainWindowController(model:branch);windows.append(branchWindow);branchWindow.showWindow(nil)
        branch.updateTitle("Branch independent");try await branch.saveNow()
        let forkTree=try await branch.fetchCommitTree()
        try expect(forkTree.branches.count==2 && forkTree.commits.contains{$0.parentId==original && $0.branchId==fork.branchId},"Graphical branch tree needs real commit ancestry.")
        await a.reloadWorkspaceIfClean();try expect(a.headVersionID==mainHead && a.diagram?.project.title=="Window A edit","Saving another branch cannot change the main window.")
        do { _ = try await b.fetchVersionPreview(original);throw Failure(message:"Cross-project preview unexpectedly accepted") } catch is Failure {throw Failure(message:"Cross-project preview unexpectedly accepted")} catch {}
        let preview=try await branch.fetchVersionPreview(original)
        try expect(branch.diagram?.project.title=="Branch independent" && preview.diagram.project.title != "Branch independent","Version selection must be read-only.")
        try await branch.restoreVersion(original)
        try expect(branch.headVersionID != original && branch.diagram?.project.title==preview.diagram.project.title,"Restoration appends a new commit.")
        try await a.commit(message:"Checkpoint A");let manual=try await a.fetchCommitTree()
        try expect(manual.commits.first?.message=="Checkpoint A","Manual commit label must appear in chronology.")
        try await checkProjectMenuOwnership(aWindow, bWindow, a: a, b: b)
        a.selection = .edges(Set(a.edges.prefix(2).map(\.id)))
        let ids=a.selection.edgeIDs;try expect(ids.count==2,"Fixture needs an edge group.")
        a.setStyle(.penwidth(4),for:a.selection);a.setStyle(.routing("curved"),for:a.selection)
        a.setSelectionColor(.stroke,value:"#12345680");try await a.saveNow()
        try expect(a.edges.filter{ids.contains($0.id)}.allSatisfy{$0.style.penwidth==4 && $0.routing=="curved" && $0.style.color=="#12345680" && $0.style.colorMode=="custom"},"All selected edges must share style and alpha.")
        let before=a.edges.count;a.duplicateSelection(deltaX:0,deltaY:0);try await a.saveNow()
        try expect(a.edges.count==before+2 && a.selection.edgeIDs.count==2 && a.selection.edgeIDs.isDisjoint(with:ids),"Copied edge groups need new IDs and selection.")
        a.deleteSelection();try await a.saveNow();try expect(a.edges.count==before,"Group delete must remove every selected edge.")
        try await a.undo();try expect(a.edges.count==before+2,"Group deletion must undo atomically.")
        a.selection = .node(a.nodes[0].id);a.setSelectionColorMode(.fill,mode:"theme");a.setSelectionColorMode(.text,mode:"inverse")
        a.updateThemeMode("light");try expect(a.colorSelection(for:.fill).color=="#FFFFFF" && a.colorSelection(for:.text).color=="#FFFFFF","Day auto/inverse colors.")
        a.updateThemeMode("dark");try expect(a.colorSelection(for:.fill).color=="#000000" && a.colorSelection(for:.text).color=="#000000","Night auto/inverse colors.")
        a.setSelectionColor(.text,value:"#FEDCBA40");a.updateThemeMode("light");try expect(a.colorSelection(for:.text).color=="#FEDCBA40","Explicit RGBA must survive theme changes.")
        a.savePaletteColor("#FEDCBA40");a.savePaletteColor("#FEDCBA40");try await a.saveNow()
        try expect(a.diagram?.presentation.savedColors?.count==1 && b.diagram?.presentation.savedColors?.isEmpty != false,"Saved palette must be project-scoped and deduplicated.")
        let palette=ColorEditorWindowController(parameter:.fill,model:a);windows.append(palette);palette.showNearCursor(nil);palette.refresh()
        let mode:NSPopUpButton?=palette.window?.contentView.flatMap{find("color-mode",$0)}
        try expect(mode?.selectedItem?.representedObject as? String == "theme","Color window must track the active object's color mode.")
        let pencils:PencilPaletteView?=palette.window?.contentView.flatMap{find("color-pencils",$0)}
        try expect(pencils != nil && PencilPaletteView.colors.count>=24,"Pencil palette must be present alongside HSV controls.")
        if let root=palette.window?.contentView {try expect(find("color-save-project",root) as NSButton? != nil,"Project palette save action must exist.")}
        a.updateThemeMode("dark");b.updateThemeMode("light");aWindow.refreshAll();bWindow.refreshAll()
        try expect(aWindow.window?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua && bWindow.window?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .aqua,"Project window themes must remain independent.")
        try expect(a.themeMode=="dark" && b.themeMode=="light", "Theme preferences must remain scoped to the active project.")
        try expect(NSApp.appearance==nil, "Manual project themes must not override the macOS system appearance for other projects.")
        palette.refresh()
        try expect(palette.window?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua, "A color panel must retain its project's theme when another project becomes light.")
        try expect(NSApp.windowsMenu != nil, "macOS Window menu must expose the open project windows.")
        let systemProbe=AppModel(backend:backend,workspace:bWorkspace)
        await systemProbe.bootstrap();systemProbe.updateThemeMode("system")
        let expectedSystem=NSApp.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? "dark" : "light"
        try expect(systemProbe.diagram?.presentation.theme==expectedSystem && a.themeMode=="dark", "System mode must follow macOS without changing another project's manual theme.")
        let systemWindow=MainWindowController(model:systemProbe);windows.append(systemWindow)
        systemProbe.diagram?.presentation.theme=expectedSystem=="dark" ? "light" : "dark"
        // Exercise the actual KVO callback without changing the user's macOS theme.
        notifySystemAppearanceChange()
        for _ in 0..<20 { if systemProbe.diagram?.presentation.theme==expectedSystem {break};try await Task.sleep(for:.milliseconds(50)) }
        try expect(systemProbe.diagram?.presentation.theme==expectedSystem && a.themeMode=="dark", "The macOS appearance observer must update only projects in system mode.")
        // Keep window B's manual setting for the remainder of the scenario.
        try await systemProbe.saveNow();try await b.saveNow();await b.reloadWorkspaceIfClean();b.updateThemeMode("light");try await b.saveNow()
        let manager=ProjectManagerWindowController(model:a){_,_ in};windows.append(manager);manager.reloadAndShow()
        let branches=BranchManagerWindowController(model:a){_,_ in};windows.append(branches);branches.reloadAndShow()
        let settings=ApplicationSettingsWindowController(model:a);windows.append(settings);settings.reloadAndShow()
        try await Task.sleep(for:.milliseconds(450))
        let table:NSTableView?=manager.window?.contentView.flatMap{find("project-manager-table",$0)}
        try expect((table?.numberOfRows ?? 0)>=3,"Manager must load the real project list.")
        let search:NSSearchField?=manager.window?.contentView.flatMap{find("project-manager-search",$0)}
        if let search {search.stringValue="Window B";manager.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))}
        try expect(table?.numberOfRows==1 && search?.stringValue=="Window B","Manager search must retain typed text and filter.")
        let size:NSTextField?=settings.window?.contentView.flatMap{find("settings-database-size",$0)}
        try expect(size?.stringValue.contains("проектов:")==true && size?.toolTip?.contains("WAL:")==true,"Settings must show actual SQLite, WAL and SHM sizes.")
        let storage=try await a.fetchStorageInfo();try expect(storage.totalBytes==storage.databaseBytes+storage.walBytes+storage.shmBytes && storage.projectCount>=3,"Database size must be factual.")
        for (name,controller) in [("main",aWindow as NSWindowController),("project-manager",manager),("branches",branches),("settings",settings),("palette",palette)] { try await snapshot(name,controller) }
        a.savePaletteColor("#FEDCBA40",remove:true);try await a.saveNow();try expect(a.diagram?.presentation.savedColors==[],"Removing saved color must persist.")
        let retainedDiagram=a.diagram, retainedDOT=a.dotSource, previousAlert=a.onAlert
        a.onAlert={_ in};a.updateDOTDraft(retainedDOT+"\n// pending")
        let imported=await a.importJSON(b.exportData())
        try expect(!imported && a.diagram==retainedDiagram && a.dotSource.hasSuffix("// pending"), "Import must preserve an unapplied DOT draft and the current workspace.")
        a.onAlert=previousAlert;a.alertMessage=nil;a.updateDOTDraft(retainedDOT)
        try await a.openWorkspace(bWorkspace);try expect(a.projectID==b.projectID && a.diagram?.project.title=="Window B edit","Switching must reload the selected project.")
        try await checkJSONRepositories(owner, source: b)

        let models=[a,b,branch,owner];for model in models {try await model.saveNow()}
    }

    private static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<120 {
            if condition() { try expect(true, message); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try expect(false, message)
    }

    private static func checkProjectTrash(_ backend: BackendService) async throws {
        let owner = AppModel(backend: backend, blankCanvas: true); await owner.bootstrap()
        let parentWorkspace = try await owner.createProject(title: "Trash parent", template: true)
        let parent = AppModel(backend: backend, workspace: parentWorkspace); await parent.bootstrap()
        let forkWorkspace = try await parent.forkProject(title: "Trash fork")
        let fork = AppModel(backend: backend, workspace: forkWorkspace), twin = AppModel(backend: backend, workspace: forkWorkspace)
        await fork.bootstrap(); await twin.bootstrap()
        fork.updateTitle("Trash fork edited"); try await fork.saveNow()
        _ = try await fork.createBranch(name: "retained experiment")
        let before = try await fork.fetchCommitTree(), parentBefore = try await parent.fetchCommitTree()
        let storageBefore = try await owner.fetchStorageInfo()
        let forkWindow = MainWindowController(model: fork), twinWindow = MainWindowController(model: twin)
        windows += [forkWindow, twinWindow]; forkWindow.showWindow(nil); twinWindow.showWindow(nil)
        let manager = ProjectManagerWindowController(model: fork) { _,_ in }
        windows.append(manager); manager.reloadAndShow()
        guard let root = manager.window?.contentView,
              let mode: NSSegmentedControl = find("project-manager-mode", root),
              let table: NSTableView = find("project-manager-table", root),
              let search: NSSearchField = find("project-manager-search", root),
              let trash: NSButton = find("project-manager-trash", root),
              let restore: NSButton = find("project-manager-restore", root),
              let purge: NSButton = find("project-manager-purge", root),
              let open: NSButton = find("project-manager-open", root) else { throw Failure(message: "Project trash controls missing") }
        func click(_ button: NSButton) throws {
            try expect(button.isEnabled && !button.isHidden, "Trash action must be available: \(button.title)")
            guard let action = button.action else { throw Failure(message: "No action for \(button.title)") }
            NSApp.sendAction(action, to: button.target, from: button)
        }
        func switchMode(_ index: Int) {
            mode.selectedSegment = index
            if let action = mode.action { NSApp.sendAction(action, to: mode.target, from: mode) }
        }
        func filterFork() {
            search.stringValue = "Trash fork"
            manager.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        try await waitFor("Manager must load active projects before trash", { table.numberOfRows == storageBefore.projectCount })
        filterFork()
        try await waitFor("Manager selects the fork to delete", { table.numberOfRows == 1 && trash.isEnabled })
        let themeKey = "GraphiSchema.themeMode.\(forkWorkspace.projectId)", fileKey = "GraphiSchema.projectFile.\(forkWorkspace.projectId)"
        SettingsStore.shared.set("dark", forKey: themeKey); SettingsStore.shared.set("/tmp/independent-export.json", forKey: fileKey)
        fork.rememberWorkspace()
        // A pending autosave in another window must not resurrect a trashed project.
        twin.updateTitle("Pending edit must not resurrect the fork")
        try click(trash)
        try await waitFor("Both windows must discard a removed project and show independent transient canvases", {
            fork.isTransientProject && twin.isTransientProject && fork.workspace == nil && twin.workspace == nil && table.numberOfRows == 0
        })
        try expect(fork.diagram?.project.id != twin.diagram?.project.id && fork.nodes.isEmpty && twin.nodes.isEmpty,
                   "Removed windows need distinct empty drafts and no retained project entities")
        try expect(!fork.history.canUndo && !twin.history.canUndo && !fork.jsonDraftIsDirty && !twin.jsonDraftIsDirty,
                   "Removal must clear history controls and editor drafts")
        try await fork.saveNow(); try await twin.saveNow()
        let trashItems = try await owner.fetchProjects(trashed: true)
        try expect(trashItems.count == 1 && trashItems[0].id == forkWorkspace.projectId && trashItems[0].branchCount == 2,
                   "Trash must retain the fork and every branch")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let deletedAt = trashItems[0].deletedAt.flatMap(formatter.date(from:)), purgeAfter = trashItems[0].purgeAfter.flatMap(formatter.date(from:))
        try expect(deletedAt != nil && purgeAfter != nil && abs(purgeAfter!.timeIntervalSince(deletedAt!)-864000)<0.01,
                   "The UI receives an exact ten-day retention deadline")
        let inTrashStorage = try await owner.fetchStorageInfo()
        try expect(inTrashStorage.projectCount == storageBefore.projectCount-1 && inTrashStorage.trashedProjectCount == 1 && inTrashStorage.versionCount == storageBefore.versionCount,
                   "Trash hides projects without deleting versions or registering reset canvases")
        switchMode(1)
        try await waitFor("Trash mode must load the deleted fork and enable restore", { table.numberOfRows == 1 && restore.isEnabled })
        try expect(!open.isEnabled && trash.isHidden && !restore.isHidden && !purge.isHidden,
                   "Trash must offer restore/permanent deletion, without opening or editing")
        try expect(table.tableColumns.first { $0.identifier.rawValue == "date" }?.title == "Удаление после (UTC)",
                   "Trash must display the expiry date explicitly")
        try await snapshot("project-trash", manager)
        try click(restore)
        try await waitFor("Restore must return to the active project list", { mode.selectedSegment == 0 && !trash.isHidden && trash.isEnabled })
        try await fork.openWorkspace(forkWorkspace)
        let restored = try await fork.fetchCommitTree()
        try expect(restored.commits.map(\.id) == before.commits.map(\.id) && restored.branches.map(\.headVersionId) == before.branches.map(\.headVersionId),
                   "Restoration must preserve commit IDs and all branch heads exactly")
        try expect(fork.diagram?.project.title == "Trash fork edited" && twin.isTransientProject,
                   "Restore requires explicit reopening and cannot apply another window's pending edit")
        filterFork()
        try await waitFor("Restored fork must be selectable for another deletion", { table.numberOfRows == 1 && trash.isEnabled })
        try click(trash)
        try await waitFor("Second trash operation must finish", { table.numberOfRows == 0 && fork.isTransientProject })
        switchMode(1)
        try await waitFor("Permanent deletion must be available in trash", { table.numberOfRows == 1 && purge.isEnabled })
        try click(purge)
        try await waitFor("Permanent deletion must require explicit confirmation", { manager.pendingPermanentDeleteAlert != nil })
        if let alert = manager.pendingPermanentDeleteAlert { manager.window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
        try await waitFor("Cancel must leave the trash item intact", { manager.pendingPermanentDeleteAlert == nil && table.numberOfRows == 1 })
        try expect((try await owner.fetchProjects(trashed: true)).count == 1, "Cancel cannot delete project data")
        try click(purge)
        try await waitFor("Deletion confirmation must reopen", { manager.pendingPermanentDeleteAlert != nil })
        if let alert = manager.pendingPermanentDeleteAlert { manager.window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
        try await waitFor("Confirmed permanent deletion must remove the item", { table.numberOfRows == 0 && manager.pendingPermanentDeleteAlert == nil })
        let finalStorage = try await owner.fetchStorageInfo(), finalTrash = try await owner.fetchProjects(trashed: true)
        try expect(finalTrash.isEmpty && finalStorage.trashedProjectCount == 0 && finalStorage.projectCount == storageBefore.projectCount-1 && finalStorage.versionCount == storageBefore.versionCount-before.commits.count,
                   "Permanent deletion must remove every own snapshot, leaving other projects intact")
        try expect(SettingsStore.shared.object(forKey: themeKey) == nil && SettingsStore.shared.object(forKey: fileKey) == nil,
                   "Permanent deletion must clear project settings and file associations")
        try expect(StartupPreferences.workspaceToRestore()?.projectId != forkWorkspace.projectId,
                   "Deleted project cannot remain the startup workspace")
        let parentAfter = try await parent.fetchCommitTree()
        try expect(parentAfter.commits.map(\.id) == parentBefore.commits.map(\.id) && parentAfter.branches.map(\.headVersionId) == parentBefore.branches.map(\.headVersionId),
                   "Deleting a fork must preserve the parent's entire history")
        do { try await owner.openWorkspace(forkWorkspace); throw Failure(message: "Purged project unexpectedly opened") }
        catch is Failure { throw Failure(message: "Purged project unexpectedly opened") } catch {}
        manager.close(); forkWindow.close(); twinWindow.close()
    }

    private static func checkStartupAndTransientProjects(_ backend: BackendService) async throws {
        let empty = AppModel(backend: backend, blankCanvas: true)
        await empty.bootstrap()
        try expect(empty.alertMessage == nil && empty.isTransientProject && empty.workspace == nil, "Blank startup must remain an unregistered draft.")
        guard let initial = empty.diagram else { throw Failure(message: "Blank startup must load canonical JSON") }
        try expect(initial.nodes.isEmpty && initial.containers.isEmpty && initial.edges.isEmpty && empty.layout != nil && !empty.dotSource.isEmpty,
                   "A transient canvas still needs JSON, DOT and geometry.")
        try expect(initial.project.title.range(of: "^Unnamed-[a-z0-9]+$", options: .regularExpression) != nil,
                   "Default project names need Unnamed and a random identifier.")
        let database = SettingsStore.shared.directory.appendingPathComponent("projects/graphischema.sqlite3")
        try expect(!FileManager.default.fileExists(atPath: database.path), "Cold blank startup must not even initialize the project database.")
        let previousStarter = empty.loadStarterOnLaunch
        empty.loadStarterOnLaunch = true
        let editor = MainWindowController(model: empty); windows.append(editor); editor.refreshAll()
        await editor.loadStarterTemplateIfNeeded()
        empty.loadStarterOnLaunch = previousStarter
        try expect(empty.diagram == initial, "Automatic starter templates must not populate or register an empty startup window.")
        await empty.selectTab(.dot)
        try await empty.previewDOTDraft()
        await empty.validate()
        try await empty.saveNow()
        try expect(empty.isTransientProject && empty.dotPreview == nil && empty.alertMessage == nil, "Read-only checks and saving an untouched canvas must remain stateless.")
        let projectsBefore = try await empty.fetchProjects()
        let storageBefore = try await empty.fetchStorageInfo()
        let versionsBefore = try await empty.fetchVersions()
        try expect(projectsBefore.isEmpty && storageBefore.projectCount == 0 && storageBefore.versionCount == 0 && versionsBefore.isEmpty,
                   "Opening the manager/settings/history must not create a placeholder project.")
        let settings = ApplicationSettingsWindowController(model: empty); windows.append(settings); settings.reloadAndShow()
        let popup: NSPopUpButton? = settings.window?.contentView.flatMap { find("settings-startup-window", $0) }
        try expect(popup?.itemArray.count == 2, "Application settings must expose exactly the two startup choices.")
        if let popup, let item = popup.itemArray.first(where: { $0.representedObject as? String == StartupWindowMode.emptyCanvas.rawValue }), let action = popup.action {
            popup.select(item); NSApp.sendAction(action, to: popup.target, from: popup)
        }
        try expect(empty.startupWindowMode == .emptyCanvas && empty.isTransientProject, "Changing startup preference must not change or register the canvas.")
        empty.startupWindowMode = .lastProject
        let savedMarker = ProjectWorkspace(projectId: "project_remembered", branchId: "branch_remembered")
        SettingsStore.shared.set(try JSONEncoder().encode(savedMarker), forKey: StartupPreferences.lastWorkspaceKey)
        empty.rememberWorkspace()
        try expect(StartupPreferences.workspaceToRestore() == savedMarker, "An empty window must not replace the last real project.")
        var creations = 0
        let manager = ProjectManagerWindowController(model: empty, onCreateBlank: { creations += 1 }) { _,_ in }
        windows.append(manager); manager.createProject()
        let projectsAfterNew = try await empty.fetchProjects()
        try expect(creations == 1 && projectsAfterNew.isEmpty, "New canvas actions must defer database registration.")
        empty.addNode(kind: "server", at: (x: 2, y: 3))
        try await empty.saveNow()
        try expect(!empty.isTransientProject && empty.workspace != nil && empty.diagram?.project.id == initial.project.id,
                   "First mutation must atomically register the same draft ID.")
        try expect(empty.diagram?.project.title == initial.project.title && empty.nodes.count == 1, "Registration must retain the generated name and first object.")
        let firstVersions = try await empty.fetchVersions()
        try expect(firstVersions.count == 1 && firstVersions[0].projectNumber == 1 && empty.history.canUndo,
                   "First mutation must create one root commit with undo support, without an empty initial commit.")
        empty.rememberWorkspace(); let remembered = StartupPreferences.workspaceToRestore()
        try await empty.undo(); try expect(empty.nodes.isEmpty && !empty.isTransientProject, "Undo of the first change keeps the registered project.")
        try await empty.redo(); try expect(empty.nodes.count == 1, "Redo must recover the first object.")
        let another = AppModel(backend: backend, blankCanvas: true); await another.bootstrap()
        another.rememberWorkspace()
        try expect(another.isTransientProject && another.diagram?.project.id != initial.project.id && another.diagram?.project.title != initial.project.title,
                   "Every empty window needs its own temporary ID and generated name.")
        let projectsAfterBlank = try await another.fetchProjects()
        try expect(StartupPreferences.workspaceToRestore() == remembered && projectsAfterBlank.count == 1,
                   "Another blank window must preserve the previous real project and repository size.")
        let anotherID = another.diagram?.project.id
        try await another.openWorkspace(empty.workspace!)
        let projectsAfterOpen = try await another.fetchProjects()
        try expect(!another.isTransientProject && another.projectID == empty.projectID && projectsAfterOpen.count == 1,
                   "Opening an existing project must discard the untouched draft without registering it.")
        try expect(!(try await another.fetchProjects()).contains { $0.id == anotherID }, "Discarded transient IDs must stay out of the project manager.")
        let missing = AppModel(backend: backend, workspace: ProjectWorkspace(projectId: "project_missing", branchId: "branch_missing"))
        await missing.bootstrap(fallbackToBlank: true)
        try expect(missing.isTransientProject && missing.workspace == nil && missing.alertMessage == nil,
                   "A missing last project must fall back to an unregistered blank canvas.")
        let finalStorage = try await missing.fetchStorageInfo()
        try expect(finalStorage.projectCount == 1, "Fallback startup must not register a second project.")
        editor.close(); settings.close()
    }

    private static func menuItem(_ title: String) throws -> NSMenuItem {
        guard let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.title == title }) else {
            throw Failure(message: "Missing menu command: \(title); key=\(NSApp.keyWindow?.title ?? "nil"); menu=\(NSApp.mainMenu?.items.map(\.title) ?? [])")
        }
        return item
    }

    private static func notifySystemAppearanceChange() {
        NSApp.willChangeValue(forKey: "effectiveAppearance")
        NSApp.didChangeValue(forKey: "effectiveAppearance")
    }

    private static func activateProjectWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        // Drive the actual observer deterministically: macOS can deny foreground
        // activation to a CLI test process while another application is active.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    private static func checkProjectMenuOwnership(_ aWindow: MainWindowController, _ bWindow: MainWindowController,
                                                  a: AppModel, b: AppModel) async throws {
        let originalWorkspace = a.workspace!
        func openBranches(_ owner: MainWindowController, projectID: String) async throws -> NSWindow {
            stage("menu for \(owner.window?.title ?? "nil")")
            activateProjectWindow(owner.window)
            let item = try menuItem("Ветки и коммиты…")
            try expect(item.target === owner, "The active editor must own branch commands.")
            guard let action = item.action else { throw Failure(message: "Branch menu action missing") }
            NSApp.sendAction(action, to: item.target, from: item)
            try await Task.sleep(for: .milliseconds(350))
            guard let window = NSApp.windows.first(where: { $0.windowController is BranchManagerWindowController && $0.isVisible && $0.title.contains(projectID) }) else {
                throw Failure(message: "Branch command must open its project window; windows=\(NSApp.windows.map { "\($0.title):\($0.isVisible):\(String(describing: $0.windowController))" })")
            }
            return window
        }
        let aBranches = try await openBranches(aWindow, projectID: originalWorkspace.projectId)
        let bBranches = try await openBranches(bWindow, projectID: b.projectID!)
        activateProjectWindow(aBranches)
        try expect(try menuItem("Ветки и коммиты…").target === aWindow,
                   "Reactivating A's branch window must route macOS commands to A, even after editing B.")
        let rememberedA = StartupPreferences.workspaceToRestore()
        try expect(rememberedA == a.workspace, "The last project must follow the active editor or its auxiliary windows.")
        try await b.commit(message: "Background save must not change startup")
        try expect(StartupPreferences.workspaceToRestore() == rememberedA,
                   "Saving an inactive project must not replace the user's last active project.")
        let graphA: CommitGraphView? = aBranches.contentView.flatMap { find("commit-tree", $0) }
        let graphB: CommitGraphView? = bBranches.contentView.flatMap { find("commit-tree", $0) }
        try expect(graphA?.commits.isEmpty == false && graphA!.commits.allSatisfy { $0.projectId == a.projectID }, "A's branch window must contain only A's commits.")
        try expect(graphB?.commits.isEmpty == false && graphB!.commits.allSatisfy { $0.projectId == b.projectID }, "B's branch window must contain only B's commits.")
        activateProjectWindow(bBranches)
        try expect(try menuItem("Сохранить коммит…").target === bWindow, "Commit commands must follow the project of the active auxiliary window.")
        activateProjectWindow(aWindow.window)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = MainWindowController(model: AppModel(backend: b.backend, workspace: b.workspace))
        windows.append(hidden)
        try expect(try menuItem("Ветки и коммиты…").target === aWindow,
                   "Constructing an inactive editor must not steal the active project's menu.")
        let variables = PromptVariablesWindowController(model: a, promptSource: { a.ollamaPreferences.systemPrompt })
        windows.append(variables)
        variables.showNearCursor(nil)
        activateProjectWindow(variables.window)
        try expect(try menuItem("Сохранить коммит…").target === aWindow,
                   "Nested settings windows must keep the commands bound to their project's editor.")
        variables.close()
        activateProjectWindow(aBranches)
        try await a.openWorkspace(b.workspace!)
        try expect(!aBranches.isVisible, "Switching projects must close the previous project's branch tree.")
        let switchedBranches = try await openBranches(aWindow, projectID: b.projectID!)
        let switched: CommitGraphView? = switchedBranches.contentView.flatMap { find("commit-tree", $0) }
        try expect(switched?.commits.isEmpty == false && switched!.commits.allSatisfy { $0.projectId == b.projectID },
                   "A reused editor must display only its newly opened project's commits.")
        try expect(switchedBranches.title.contains(b.projectID!), "Branch window must identify the project explicitly.")
        switchedBranches.close()
        // The remainder of the scenario edits A, so return to its original branch.
        try await a.openWorkspace(originalWorkspace)
        aBranches.close(); bBranches.close()
    }

    private static func checkJSONRepositories(_ model: AppModel, source: AppModel) async throws {
        let sourceWorkspace = source.workspace!, sourceTree = try await source.fetchCommitTree()
        let data = source.exportData()
        var importedIDs = Set<String>()
        for _ in 0..<2 {
            try expect(await model.importJSON(data), "Importing a portable JSON copy must succeed.")
            try expect(model.projectID != source.projectID, "Import must allocate an independent project ID.")
            importedIDs.insert(model.projectID!)
            let tree = try await model.fetchCommitTree()
            try expect(tree.branches.count == 1 && tree.commits.count == 1 && tree.commits[0].parentId == nil && tree.commits[0].projectNumber == 1,
                       "Each imported copy must have its own main branch and root commit №1.")
        }
        try expect(importedIDs.count == 2, "Repeated imports with identical JSON IDs must remain separate projects.")
        let importedWorkspace = model.workspace!
        try expect(await model.importJSON(data, asNewProject: false), "Opening a known JSON project must resume its repository.")
        try expect(model.workspace == sourceWorkspace, "Opening an unchanged JSON must preserve the existing branch.")
        let afterOpen = try await source.fetchCommitTree()
        try expect(afterOpen.commits.count == sourceTree.commits.count, "Opening a file must not manufacture new commits.")
        func switchTo(_ target: ProjectWorkspace) async throws -> Bool {
            do { try await model.openWorkspace(target); return true }
            catch ClientError.pendingChanges { return false }
        }
        let firstSwitch = Task { try await switchTo(importedWorkspace) }
        let secondSwitch = Task { try await switchTo(sourceWorkspace) }
        let outcomes = try await [firstSwitch.value, secondSwitch.value]
        try expect(outcomes.filter { $0 }.count == 1, "Concurrent project switches must serialize instead of rolling back each other's workspace.")
        try expect(model.projectID == model.diagram?.project.id && !model.isSwitchingWorkspace, "After concurrent switches, workspace and diagram IDs must agree and controls must unlock.")
        try await model.openWorkspace(sourceWorkspace)
        let previous = model.workspace
        try await model.applyTemplate(data)
        try expect(model.workspace == previous && model.projectID == source.projectID, "Loading a template must retain the target project and branch.")
    }
}
