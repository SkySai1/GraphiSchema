import Foundation

@MainActor
final class AppModel: ObservableObject {
    var diagram: DiagramProject?
    var revision = ""
    var selection: DiagramSelection = .project
    var workspaceTab: WorkspaceTab = .canvas
    var layout: DiagramLayout?
    var dotSource = ""
    var dotPreview: DOTPreviewResponse?
    var ollamaProposal: DiagramProposal?
    var ollamaPreferences = OllamaPreferences()
    var jsonDraft = ""
    var issues: [ValidationIssue] = []
    var history = HistoryState(canUndo: false, canRedo: false)
    var status = "Подключение…"
    var alertMessage: String?
    var onModelChange: (() -> Void)?
    var onPreviewChange: (() -> Void)?
    var onAlert: ((String) -> Void)?

    let backend = BackendService()
    private var saveTask: Task<Void, Never>?
    private var isSaving = false
    private var saveQueued = false
    private var lastSerializedJSON = ""
    private var lastSerializedDOT = ""
    private var dotPreviewSource: String?
    private var proposalBaseRevision: String?
    private var proposalBaseDiagram: DiagramProject?

    var nodes: [DiagramNode] { diagram?.nodes ?? [] }
    var containers: [DiagramContainer] { diagram?.containers ?? [] }
    var edges: [DiagramEdge] { diagram?.edges ?? [] }
    var activeProposal: DiagramProposal? { dotPreview ?? ollamaProposal }

    init() {
        if let data = UserDefaults.standard.data(forKey: "GraphiSchema.ollama.preferences"),
           let saved = try? JSONDecoder().decode(OllamaPreferences.self, from: data) {
            ollamaPreferences = saved
        }
    }

    func bootstrap() async {
        await backend.start()
        guard backend.isReady else {
            status = backend.status
            return
        }
        do {
            let envelope: DiagramResponse = try await request("api/diagram")
            diagram = envelope.diagram
            revision = envelope.revision
            jsonDraft = prettyJSON(envelope.diagram)
            lastSerializedJSON = jsonDraft
            status = "Сохранено"
            await refreshLayout()
            await refreshHistoryState()
            onModelChange?()
        } catch {
            status = "Ошибка загрузки"
            alertMessage = error.localizedDescription
            onAlert?(error.localizedDescription)
        }
    }

    func updateTitle(_ value: String) {
        guard var current = diagram else { return }
        current.project.title = value
        diagram = current
        changed()
    }

    func updateDirection(_ value: String) {
        guard var current = diagram else { return }
        current.diagram.direction = value
        diagram = current
        changed()
    }

    func updateLayoutMode(_ value: String) {
        guard var current = diagram, ["auto", "manual"].contains(value) else { return }
        guard current.diagram.layoutMode != value else { return }
        if value == "manual", current.diagram.layoutMode != "manual" {
            let positions = Dictionary(uniqueKeysWithValues: (layout?.nodes ?? []).map { ($0.id, $0) })
            for index in current.nodes.indices {
                guard let position = positions[current.nodes[index].id] else { continue }
                current.nodes[index].x = position.x
                current.nodes[index].y = position.y
            }
        }
        current.diagram.layoutMode = value
        diagram = current
        changed()
    }

    func editNode(_ id: String, _ update: (inout DiagramNode) -> Void) {
        guard var current = diagram, let index = current.nodes.firstIndex(where: { $0.id == id }) else { return }
        update(&current.nodes[index])
        diagram = current
        changed()
    }

    func editContainer(_ id: String, _ update: (inout DiagramContainer) -> Void) {
        guard var current = diagram, let index = current.containers.firstIndex(where: { $0.id == id }) else { return }
        update(&current.containers[index])
        diagram = current
        changed()
    }

    func editEdge(_ id: String, _ update: (inout DiagramEdge) -> Void) {
        guard var current = diagram, let index = current.edges.firstIndex(where: { $0.id == id }) else { return }
        update(&current.edges[index])
        diagram = current
        changed()
    }

    func moveNode(_ id: String, x: Double, y: Double) {
        guard var current = diagram, let index = current.nodes.firstIndex(where: { $0.id == id }) else { return }
        current.diagram.layoutMode = "manual"
        let positions = Dictionary(uniqueKeysWithValues: (layout?.nodes ?? []).map { ($0.id, $0) })
        for nodeIndex in current.nodes.indices where current.nodes[nodeIndex].x == nil || current.nodes[nodeIndex].y == nil {
            guard let position = positions[current.nodes[nodeIndex].id] else { continue }
            current.nodes[nodeIndex].x = position.x
            current.nodes[nodeIndex].y = position.y
        }
        current.nodes[index].x = min(1000, max(-1000, x))
        current.nodes[index].y = min(1000, max(-1000, y))
        diagram = current
        selection = .node(id)
        changed()
    }

    func moveContainer(_ id: String, deltaX: Double, deltaY: Double) {
        guard var current = diagram, current.containers.contains(where: { $0.id == id }) else { return }
        current.diagram.layoutMode = "manual"
        let positions = Dictionary(uniqueKeysWithValues: (layout?.nodes ?? []).map { ($0.id, $0) })
        for index in current.nodes.indices where current.nodes[index].x == nil || current.nodes[index].y == nil {
            guard let position = positions[current.nodes[index].id] else { continue }
            current.nodes[index].x = position.x
            current.nodes[index].y = position.y
        }
        var containerIDs: Set<String> = [id]
        var expanded = true
        while expanded {
            expanded = false
            for container in current.containers where container.parentId.map(containerIDs.contains) == true {
                if containerIDs.insert(container.id).inserted { expanded = true }
            }
        }
        for index in current.nodes.indices where current.nodes[index].containerId.map(containerIDs.contains) == true {
            current.nodes[index].x = min(1000, max(-1000, (current.nodes[index].x ?? 0) + deltaX))
            current.nodes[index].y = min(1000, max(-1000, (current.nodes[index].y ?? 0) + deltaY))
        }
        diagram = current
        selection = .container(id)
        changed()
    }

    func addNode() {
        guard var current = diagram else { return }
        let id = makeID("node")
        let manualX = current.diagram.layoutMode == "manual"
            ? (current.nodes.compactMap(\.x).max() ?? layout?.width ?? 0) + 1.6
            : nil
        let manualY = current.diagram.layoutMode == "manual" ? (layout?.height ?? 1) / 2 : nil
        current.nodes.append(DiagramNode(
            id: id,
            label: "Новый компонент",
            description: "",
            kind: "service",
            shape: "box",
            containerId: nil,
            style: NodeStyle(fill: "#FFFFFF", stroke: "#3867E8", text: "#172238", penwidth: 1.5),
            x: manualX,
            y: manualY
        ))
        diagram = current
        selection = .node(id)
        changed()
    }

    func addContainer() {
        guard var current = diagram else { return }
        let id = makeID("zone")
        current.containers.append(DiagramContainer(
            id: id,
            label: "Новая зона",
            parentId: nil,
            style: ContainerStyle(fill: "#EEF3FF", stroke: "#9CB4F5", text: "#3554A5")
        ))
        diagram = current
        selection = .container(id)
        changed()
    }

    func addEdge() {
        guard var current = diagram else { return }
        guard current.nodes.count >= 2 else {
            alertMessage = "Добавьте минимум два компонента для создания связи."
            onAlert?(alertMessage ?? "Добавьте компоненты для связи.")
            return
        }
        let first = current.nodes[current.nodes.count - 2]
        let second = current.nodes[current.nodes.count - 1]
        let id = makeID("edge")
        current.edges.append(DiagramEdge(
            id: id,
            source: first.id,
            target: second.id,
            label: "Новая связь",
            direction: "forward",
            style: EdgeStyle(lineStyle: "solid", color: "#64748B", penwidth: 1.5, arrowhead: "normal", arrowtail: "none", constraint: true, weight: 1, minlen: 1)
        ))
        diagram = current
        selection = .edge(id)
        changed()
    }

    func deleteSelection() {
        guard var current = diagram else { return }
        switch selection {
        case .project:
            return
        case .node(let id):
            current.nodes.removeAll { $0.id == id }
            current.edges.removeAll { $0.source == id || $0.target == id }
        case .edge(let id):
            current.edges.removeAll { $0.id == id }
        case .container(let id):
            let parent = current.containers.first(where: { $0.id == id })?.parentId
            current.containers.removeAll { $0.id == id }
            for index in current.containers.indices where current.containers[index].parentId == id {
                current.containers[index].parentId = parent
            }
            for index in current.nodes.indices where current.nodes[index].containerId == id {
                current.nodes[index].containerId = parent
            }
        }
        selection = .project
        diagram = current
        changed()
    }

    func saveNow() async {
        guard let snapshot = diagram else { return }
        saveTask?.cancel()
        if isSaving {
            saveQueued = true
            return
        }
        isSaving = true
        status = "Сохранение…"
        onModelChange?()
        defer {
            isSaving = false
            if saveQueued && diagram != nil {
                saveQueued = false
                scheduleSave()
            }
        }

        do {
            let envelope = try await persist(snapshot)
            revision = envelope.revision
            if diagram == snapshot {
                diagram = envelope.diagram
                jsonDraft = prettyJSON(envelope.diagram)
                lastSerializedJSON = jsonDraft
                status = "Сохранено"
                await refreshLayout()
                await refreshHistoryState()
                onModelChange?()
            } else {
                status = "Есть изменения"
                saveQueued = true
            }
        } catch {
            status = "Ошибка сохранения"
            alertMessage = error.localizedDescription
            onAlert?(error.localizedDescription)
        }
    }

    func validate() async {
        guard let diagram else { return }
        do {
            let data: Data
            if workspaceTab == .json, let draft = jsonDraft.data(using: .utf8) {
                data = draft
            } else {
                data = try encode(diagram)
            }
            let result: ValidationResponse = try await request("api/validate", method: "POST", body: data)
            issues = result.issues
            if issues.isEmpty { status = "Модель корректна" }
            onModelChange?()
        } catch {
            alertMessage = error.localizedDescription
            onAlert?(error.localizedDescription)
        }
    }

    func selectTab(_ tab: WorkspaceTab) async {
        workspaceTab = tab
        if tab == .json {
            if jsonDraft.isEmpty || jsonDraft == lastSerializedJSON {
                jsonDraft = prettyJSON(diagram)
            }
            lastSerializedJSON = prettyJSON(diagram)
        } else if tab == .dot {
            if dotSource.isEmpty || dotSource == lastSerializedDOT {
                do {
                    dotSource = try await requestText("api/dot")
                    lastSerializedDOT = dotSource
                } catch { alertMessage = error.localizedDescription; onAlert?(error.localizedDescription) }
            }
        }
        onModelChange?()
    }

    func updateDOTDraft(_ value: String) {
        dotSource = value
        dotPreview = nil
        ollamaProposal = nil
        dotPreviewSource = nil
        proposalBaseRevision = nil
        proposalBaseDiagram = nil
        if workspaceTab == .dot { status = "DOT изменён" }
        onModelChange?()
        onPreviewChange?()
    }

    func previewDOTDraft() async throws {
        try await flushPendingSave()
        let source = dotSource
        let baseDiagram = diagram
        let baseRevision = revision
        let response: DOTPreviewResponse = try await request(
            "api/dot/preview",
            method: "POST",
            body: try encode(DOTPreviewRequest(dot: source)),
            ifMatch: baseRevision
        )
        guard source == dotSource, baseRevision == revision, baseDiagram == diagram else { throw ClientError.staleProposal }
        ollamaProposal = nil
        dotPreview = response
        dotPreviewSource = source
        proposalBaseRevision = baseRevision
        proposalBaseDiagram = baseDiagram
        let count = response.changes.entries.count
        status = count == 0 ? "DOT корректен · изменений нет" : "Предпросмотр · изменений: \(count)"
        onModelChange?()
        onPreviewChange?()
    }

    func updateOllamaPreferences(_ value: OllamaPreferences) {
        ollamaPreferences = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "GraphiSchema.ollama.preferences")
        }
    }

    func fetchOllamaModels() async throws -> [OllamaModel] {
        let request = OllamaConnectionRequest(endpoint: ollamaPreferences.endpoint, timeout: min(30, max(1, ollamaPreferences.timeout)))
        let response: OllamaModelsResponse = try await self.request("api/ollama/check", method: "POST", body: try encode(request), timeout: request.timeout + 5)
        return response.models
    }

    func generateWithOllama(_ prompt: String, editing: Bool) async throws -> DiagramProposal {
        try await flushPendingSave()
        let baseDiagram = diagram
        let baseRevision = revision
        let body = try encode(OllamaTaskRequest(settings: ollamaPreferences, prompt: prompt))
        let path = editing ? "api/ollama/edit" : "api/ollama/generate"
        let proposal: DiagramProposal = try await request(path, method: "POST", body: body, ifMatch: baseRevision, timeout: ollamaPreferences.timeout + 5)
        guard baseRevision == revision, baseDiagram == diagram else { throw ClientError.staleProposal }
        ollamaProposal = proposal
        dotPreview = nil
        dotPreviewSource = nil
        proposalBaseRevision = baseRevision
        proposalBaseDiagram = baseDiagram
        selection = .project
        workspaceTab = .canvas
        status = editing ? "Предложение Ollama · \(proposal.changes.entries.count) изменений" : "Диаграмма Ollama готова к проверке"
        onModelChange?()
        onPreviewChange?()
        return proposal
    }

    func reviewWithOllama(_ prompt: String) async throws -> OllamaReviewResponse {
        try await flushPendingSave()
        let baseDiagram = diagram
        let baseRevision = revision
        let body = try encode(OllamaTaskRequest(settings: ollamaPreferences, prompt: prompt))
        let report: OllamaReviewResponse = try await request("api/ollama/review", method: "POST", body: body, ifMatch: baseRevision, timeout: ollamaPreferences.timeout + 5)
        guard baseRevision == revision, baseDiagram == diagram else { throw ClientError.staleProposal }
        return report
    }

    func applyCurrentProposal() async throws {
        guard let candidate = activeProposal?.diagram else { return }
        guard proposalBaseRevision == revision, proposalBaseDiagram == diagram else {
            cancelCurrentProposal()
            throw ClientError.staleProposal
        }
        let envelope = try await persist(candidate)
        diagram = envelope.diagram
        revision = envelope.revision
        dotPreview = nil
        ollamaProposal = nil
        dotPreviewSource = nil
        proposalBaseRevision = nil
        proposalBaseDiagram = nil
        jsonDraft = prettyJSON(envelope.diagram)
        lastSerializedJSON = jsonDraft
        dotSource = try await requestText("api/dot")
        lastSerializedDOT = dotSource
        selection = .project
        status = "Предложение применено"
        await refreshLayout()
        await refreshHistoryState()
        onModelChange?()
    }

    func cancelCurrentProposal() {
        dotPreview = nil
        ollamaProposal = nil
        dotPreviewSource = nil
        proposalBaseRevision = nil
        proposalBaseDiagram = nil
        status = "Предложение отменено"
        onModelChange?()
        onPreviewChange?()
    }

    func applyJSONDraft() async throws {
        guard let data = jsonDraft.data(using: .utf8) else { throw ClientError.invalidJSON }
        let _: ValidationResponse = try await request("api/validate", method: "POST", body: data)
        let candidate = try decode(DiagramProject.self, from: data)
        let envelope = try await persist(candidate)
        diagram = envelope.diagram
        revision = envelope.revision
        jsonDraft = prettyJSON(envelope.diagram)
        lastSerializedJSON = jsonDraft
        status = "Сохранено"
        await refreshLayout()
        await refreshHistoryState()
        onModelChange?()
    }

    func importJSON(_ data: Data) async {
        do {
            let _: ValidationResponse = try await request("api/validate", method: "POST", body: data)
            let candidate = try decode(DiagramProject.self, from: data)
            let envelope = try await persist(candidate)
            diagram = envelope.diagram
            revision = envelope.revision
            jsonDraft = prettyJSON(envelope.diagram)
            lastSerializedJSON = jsonDraft
            selection = .project
            status = "Импортировано"
            await refreshLayout()
            await refreshHistoryState()
            onModelChange?()
        } catch {
            alertMessage = "Импорт не выполнен: \(error.localizedDescription)"
            onAlert?(alertMessage ?? "Ошибка импорта")
        }
    }

    func exportData() -> Data {
        guard let diagram else { return Data() }
        return (try? encode(diagram)) ?? Data()
    }

    func exportPNG(scale: Double, background: String) async throws -> Data {
        guard let baseURL = backend.baseURL,
              var components = URLComponents(url: baseURL.appending(path: "api/export.png"), resolvingAgainstBaseURL: false)
        else { throw ClientError.backendUnavailable }
        components.queryItems = [
            URLQueryItem(name: "scale", value: String(scale)),
            URLQueryItem(name: "background", value: background),
        ]
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)
        guard (response as? HTTPURLResponse)?.mimeType == "image/png" else { throw ClientError.invalidResponse }
        return data
    }

    func fetchVersions() async throws -> [ProjectVersion] {
        let response: VersionsResponse = try await request("api/versions")
        return response.versions
    }

    func fetchVersionDiff(_ id: Int) async throws -> VersionDiff {
        try await request("api/versions/\(id)/diff")
    }

    func restoreVersion(_ id: Int) async throws {
        let envelope: DiagramResponse = try await request("api/versions/\(id)/restore", method: "POST", ifMatch: revision)
        diagram = envelope.diagram
        revision = envelope.revision
        jsonDraft = prettyJSON(envelope.diagram)
        lastSerializedJSON = jsonDraft
        selection = .project
        status = "Версия восстановлена"
        await refreshLayout()
        await refreshHistoryState()
        onModelChange?()
    }

    func undo() async throws { try await applyHistoryCommand("api/undo", status: "Отменено") }

    func redo() async throws { try await applyHistoryCommand("api/redo", status: "Повторено") }

    private func applyHistoryCommand(_ path: String, status newStatus: String) async throws {
        let envelope: DiagramResponse = try await request(path, method: "POST", ifMatch: revision)
        diagram = envelope.diagram
        revision = envelope.revision
        jsonDraft = prettyJSON(envelope.diagram)
        lastSerializedJSON = jsonDraft
        selection = .project
        status = newStatus
        await refreshLayout()
        await refreshHistoryState()
        onModelChange?()
    }

    func selectProject() { selection = .project }

    func descendantContainerIDs(of id: String) -> Set<String> {
        var descendants = Set<String>()
        var changed = true
        while changed {
            changed = false
            for container in containers where container.parentId == id || container.parentId.map(descendants.contains) == true {
                if descendants.insert(container.id).inserted { changed = true }
            }
        }
        return descendants
    }

    private func changed() {
        status = "Есть изменения"
        onModelChange?()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func persist(_ project: DiagramProject) async throws -> DiagramResponse {
        let data = try encode(project)
        return try await request("api/diagram", method: "PUT", body: data, ifMatch: revision)
    }

    private func flushPendingSave() async throws {
        saveTask?.cancel()
        while isSaving {
            try await Task.sleep(for: .milliseconds(40))
        }
        for _ in 0..<5 {
            saveTask?.cancel()
            guard let snapshot = diagram else { return }
            let serialized = prettyJSON(snapshot)
            guard serialized != lastSerializedJSON else { return }
            let envelope = try await persist(snapshot)
            revision = envelope.revision
            lastSerializedJSON = prettyJSON(envelope.diagram)
            if diagram == snapshot {
                diagram = envelope.diagram
                jsonDraft = lastSerializedJSON
                status = "Сохранено"
                await refreshLayout()
                await refreshHistoryState()
            }
        }
        if prettyJSON(diagram) != lastSerializedJSON { throw ClientError.pendingChanges }
    }

    private func refreshLayout() async {
        do { layout = try await request("api/layout") }
        catch {
            alertMessage = "Не удалось получить геометрию диаграммы: \(error.localizedDescription)"
            onAlert?(alertMessage ?? "Ошибка компоновки")
        }
        onPreviewChange?()
    }

    private func refreshHistoryState() async {
        do { history = try await request("api/history") }
        catch { history = HistoryState(canUndo: false, canRedo: false) }
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        ifMatch: String? = nil,
        timeout: Double = 10
    ) async throws -> T {
        guard let baseURL = backend.baseURL else { throw ClientError.backendUnavailable }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)
        return try decode(T.self, from: data)
    }

    private func requestText(_ path: String) async throws -> String {
        guard let baseURL = backend.baseURL else { throw ClientError.backendUnavailable }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.invalidResponse }
        return text
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw ClientError.server(String(describing: detail ?? String(data: data, encoding: .utf8) ?? "HTTP \(response.statusCode)"))
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private func prettyJSON(_ value: DiagramProject?) -> String {
        guard let value, let data = try? encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeID(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))"
    }
}

enum ClientError: LocalizedError {
    case backendUnavailable
    case invalidJSON
    case invalidResponse
    case staleProposal
    case pendingChanges
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendUnavailable: "Локальный backend недоступен."
        case .invalidJSON: "Не удалось прочитать JSON."
        case .invalidResponse: "Backend вернул некорректный ответ."
        case .staleProposal: "Проект изменился во время анализа. Запустите проверку или генерацию повторно."
        case .pendingChanges: "Не удалось зафиксировать изменения перед запуском Ollama."
        case .server(let message): message
        }
    }
}
