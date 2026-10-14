import AppKit

@MainActor
enum NativeDOTRegressionTests {
    static func run(_ project: DiagramProject) -> String? {
        let theme = UserDefaults.standard.object(forKey: "GraphiSchema.themeMode")
        UserDefaults.standard.set("light", forKey: "GraphiSchema.themeMode")
        defer { UserDefaults.standard.set(theme, forKey: "GraphiSchema.themeMode") }
        var completed = false
        var failure: String?
        let task = Task { @MainActor in
            do {
                try await checkFreshDOT(project)
                try await checkEditedDraft(project)
                try await checkStaleResponse(project)
                completed = true
            } catch { failure = error.localizedDescription; completed = true }
        }
        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard completed else { task.cancel(); return "Native DOT regression timed out." }
        if failure == nil { print("Native DOT regression passed: fresh source after pending canvas saves, draft baseline, explicit apply/cancel, stale response and no-op validation.") }
        return failure
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private static func start(_ project: DiagramProject) async throws -> (AppModel, DOTTransportFixture, URLSession) {
        let fixture = DOTTransportFixture(project)
        DOTFixtureProtocol.handler = { try fixture.respond(to: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DOTFixtureProtocol.self]
        let session = URLSession(configuration: config)
        let model = AppModel(backend: BackendService(baseURL: URL(string: "http://graphischema.test")!), session: session)
        await model.bootstrap()
        try expect(model.diagram == project, "DOT fixture bootstrap failed: \(model.alertMessage ?? model.status)")
        await model.selectTab(.dot)
        try expect(!model.dotDraftIsDirty && !model.dotSource.isEmpty, "Opening DOT must load a clean generated source.")
        return (model, fixture, session)
    }

    private static func checkFreshDOT(_ project: DiagramProject) async throws {
        let (model, fixture, session) = try await start(project)
        defer { session.invalidateAndCancel() }
        let previous = model.dotSource
        model.addNode(kind: "gateway", at: (x: 9.123456789, y: 4.987654321))
        let latest = model.diagram!
        try expect(previous != DOTTransportFixture.dot(latest), "The regression needs stale DOT before saving canvas changes.")
        try await model.previewDOTDraft()
        try expect(model.diagram == latest && fixture.snapshot == latest, "DOT verification must retain pending canvas changes.")
        try expect(fixture.checkedSource == DOTTransportFixture.dot(latest) && fixture.checkedBase == latest,
                   "DOT verification must use generated source and baseline from the latest saved canvas.")
        try expect(fixture.writeCount == 1, "A no-op DOT check must only flush the pending edit, without another project write.")
        try expect(model.dotPreview == nil && !model.isEditingLocked && !model.isCheckingDOT,
                   "Checking unchanged DOT must not leave a proposal or lock the editor.")
    }

    private static func checkEditedDraft(_ project: DiagramProject) async throws {
        let (model, fixture, session) = try await start(project)
        defer { session.invalidateAndCancel() }
        let draft = model.dotSource.replacingOccurrences(of: "\"WAF\"", with: "\"DOT label\"")
        model.updateDOTDraft(draft)
        model.addNode(kind: "gateway", at: (x: 8, y: 4))
        let latest = model.diagram!
        try await model.previewDOTDraft()
        try expect(model.diagram == latest && model.dotSource == draft && fixture.checkedBase == project,
                   "Saving the canvas must preserve the edited DOT draft and its original baseline.")
        try expect(model.dotPreview?.diagram.nodes.count == latest.nodes.count,
                   "The DOT proposal must keep recently added canvas objects.")
        let revision = model.revision, layout = model.layout
        model.cancelCurrentProposal()
        try expect(model.diagram == latest && model.layout == layout && model.revision == revision && model.dotSource == draft,
                   "Cancelling verification must retain the live diagram, draft and revision.")
        try expect(fixture.writeCount == 1, "Cancelling DOT must not write the project.")
        try await model.previewDOTDraft()
        try await model.applyCurrentProposal()
        try expect(model.nodes.first(where: { $0.id == "waf" })?.label == "DOT label"
                   && model.nodes.count == latest.nodes.count && fixture.writeCount == 2,
                   "Only explicit application must persist the checked DOT change, preserving canvas edits.")
        try expect(!model.dotDraftIsDirty && model.dotSource == DOTTransportFixture.dot(model.diagram!),
                   "Applied DOT must be regenerated from the merged canonical diagram.")
    }

    private static func checkStaleResponse(_ project: DiagramProject) async throws {
        let (model, fixture, session) = try await start(project)
        defer { session.invalidateAndCancel() }
        model.updateDOTDraft(model.dotSource.replacingOccurrences(of: "\"WAF\"", with: "\"DOT label\""))
        let newer = model.dotSource + "\n// newer draft"
        fixture.previewDelay = 0.1
        fixture.onPreviewStarted = { Task { @MainActor in model.updateDOTDraft(newer) } }
        do {
            try await model.previewDOTDraft()
            throw Failure(message: "A delayed response must not validate a superseded DOT draft.")
        } catch ClientError.staleProposal { }
        try expect(model.dotSource == newer && model.dotPreview == nil && model.diagram == project
                   && fixture.writeCount == 0 && !model.isCheckingDOT,
                   "An outdated DOT response must not replace the draft, mutate the graph, or keep validation busy.")
    }

    private struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

private final class DOTTransportFixture {
    private let lock = NSLock()
    private var project: DiagramProject
    private var writes = 0
    private var source: String?
    private var baseline: DiagramProject?
    var previewDelay: TimeInterval = 0
    var onPreviewStarted: (() -> Void)?

    init(_ project: DiagramProject) { self.project = project }
    var snapshot: DiagramProject { lock.lock(); defer { lock.unlock() }; return project }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var checkedSource: String? { lock.lock(); defer { lock.unlock() }; return source }
    var checkedBase: DiagramProject? { lock.lock(); defer { lock.unlock() }; return baseline }

    static func dot(_ project: DiagramProject) -> String {
        let encoder = JSONEncoder()
        func quoted(_ value: String) -> String { String(data: try! encoder.encode(value), encoding: .utf8)! }
        return "digraph G {\n" + project.nodes.map { "  \(quoted($0.id)) [label=\(quoted($0.label))];" }.joined(separator: "\n") + "\n}"
    }

    func respond(to request: URLRequest) throws -> (status: Int, data: Data, delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        func object(_ value: DiagramProject) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let revision = "fixture_\(writes)"
        if let match = request.value(forHTTPHeaderField: "If-Match"), match != revision {
            return (409, try json(["detail": "Stale fixture revision"]), 0)
        }
        let data: Data
        switch path {
        case "/api/diagram":
            if request.httpMethod == "PUT" {
                project = try decoder.decode(DiagramProject.self, from: Self.body(request))
                writes += 1
            }
            data = try json(["diagram": object(project), "revision": "fixture_\(writes)"])
        case "/api/layout": data = try json(layout())
        case "/api/history": data = try json(["can_undo": writes > 0, "can_redo": false])
        case "/api/dot": data = Data(Self.dot(project).utf8)
        case "/api/dot/preview":
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            source = body["dot"] as? String
            baseline = try decoder.decode(DiagramProject.self, from: json(body["base_diagram"]!))
            var candidate = project
            if source?.contains("DOT label") == true, let index = candidate.nodes.firstIndex(where: { $0.id == "waf" }) {
                candidate.nodes[index].label = "DOT label"
            }
            data = try json(["diagram": object(candidate), "layout": layout(), "changes": [
                "containers": [], "nodes": candidate == project ? [] : ["~ waf"], "edges": [], "settings": [],
            ]])
            onPreviewStarted?()
            return (200, data, previewDelay)
        default: return (404, try json(["detail": "Unexpected fixture route \(path)"]), 0)
        }
        return (200, data, 0)
    }

    private func layout() -> [String: Any] {
        ["engine": "neato", "width": 12, "height": 6, "min_x": 0, "min_y": 0, "edges": [],
         "nodes": project.nodes.enumerated().map { index, node -> [String: Any] in
             ["id": node.id, "x": node.x ?? Double(index + 1), "y": node.y ?? 2,
              "width": node.width ?? 1, "height": node.height ?? 1]
         }]
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class DOTFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (status: Int, data: Data, delay: TimeInterval))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graphischema.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler!(request)
            let deliver = {
                let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
            else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
