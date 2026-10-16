import Foundation
import Darwin

@MainActor
final class BackendService: ObservableObject {
    private(set) var status = "Запуск локального backend…"
    private(set) var isReady = false
    private(set) var baseURL: URL?

    private let preferredPort = 8765
    private let lifecycleClientID = UUID().uuidString.lowercased()
    private let keepaliveIntervalSeconds: Int64 = 20
    private let isStartupSmoke = ProcessInfo.processInfo.arguments.contains("--startup-smoke-test")
    private let isIsolatedTest = ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-test") }
    private var process: Process?
    private var keepaliveTask: Task<Void, Never>?
    private var expectedDataDirectory: URL?
    private(set) var projectRoot: URL?

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
        if baseURL != nil { isReady = true; status = "Backend готов" }
    }

    private var startupTask: Task<Void, Never>?
    func start() async {
        if let startupTask { await startupTask.value; return }
        let task = Task { await startBackend() }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func startBackend() async {
        guard !isReady else { return }
        if let process, process.isRunning {
            status = "Запуск локального backend…"
            return
        }
        expectedDataDirectory = SettingsStore.shared.directory.appendingPathComponent("projects", isDirectory: true)
        let preferredAddress = URL(string: "http://127.0.0.1:\(preferredPort)")!

        if !isIsolatedTest, !isStartupSmoke,
           await respondsToHealthCheck(at: preferredAddress),
           await didConnect(to: preferredAddress) {
            return
        }
        guard let port = findFreePort(), let address = URL(string: "http://127.0.0.1:\(port)") else {
            status = "Не удалось выбрать порт для локального backend."
            return
        }
        baseURL = address

        guard let root = findProjectRoot() else {
            status = "Не найден backend GraphiSchema"
            return
        }
        guard let uv = findUV() else {
            status = "Не найден uv. Установите uv и соберите приложение заново."
            return
        }

        projectRoot = root
        do {
            let support = try applicationSupportDirectory()
            let environment = support.appendingPathComponent("backend-venv", isDirectory: true)
            let dataDirectory = isStartupSmoke
                ? FileManager.default.temporaryDirectory.appendingPathComponent("graphischema-startup-\(UUID().uuidString)", isDirectory: true)
                : SettingsStore.shared.directory.appendingPathComponent("projects", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            expectedDataDirectory = dataDirectory

            let server = Process()
            server.executableURL = uv
            server.arguments = [
                "run", "--project", root.path,
                "python", "-m", "graphischema.server",
                "--host", "127.0.0.1", "--port", String(port),
            ]
            server.currentDirectoryURL = root
            var environmentVariables = ProcessInfo.processInfo.environment
            let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
            environmentVariables["PATH"] = (extraPaths + [environmentVariables["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            environmentVariables["UV_PROJECT_ENVIRONMENT"] = environment.path
            environmentVariables["GRAPHI_SCHEMA_DATA_DIR"] = dataDirectory.path
            environmentVariables["GRAPHI_SCHEMA_CONFIG_DIR"] = SettingsStore.shared.directory.path
            let backendPath = root.appendingPathComponent("backend", isDirectory: true).path
            let existingPythonPath = environmentVariables["PYTHONPATH"]
            environmentVariables["PYTHONPATH"] = [backendPath, existingPythonPath]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ":")
            if isIsolatedTest { environmentVariables["GRAPHI_SCHEMA_DISABLE_MIGRATION"] = "1" }
            environmentVariables["PYTHONDONTWRITEBYTECODE"] = "1"
            server.environment = environmentVariables
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            if isStartupSmoke {
                server.terminationHandler = { _ in try? FileManager.default.removeItem(at: dataDirectory) }
            }
            try server.run()
            process = server

            for _ in 0..<60 {
                if await respondsToHealthCheck(at: address), await didConnect(to: address) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                if !server.isRunning { break }
            }
            status = "Backend не запустился. Проверьте uv и доступность Python-зависимостей."
        } catch {
            status = "Ошибка запуска backend: \(error.localizedDescription)"
        }
    }

    private func didConnect(to address: URL) async -> Bool {
        baseURL = address
        guard await sendLifecycleRequest("api/lifecycle/keepalive") != nil else {
            baseURL = nil
            return false
        }
        isReady = true
        status = "Backend готов"
        startKeepalive()
        return true
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.keepaliveIntervalSeconds))
                guard !Task.isCancelled else { return }
                _ = await self.sendLifecycleRequest("api/lifecycle/keepalive")
            }
        }
    }

    private func sendLifecycleRequest(_ path: String) async -> [String: Any]? {
        guard let baseURL else { return nil }
        do {
            var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": lifecycleClientID])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return payload
        } catch {
            return nil
        }
    }

    func shutdown() async {
        if let keepaliveTask {
            keepaliveTask.cancel()
            await keepaliveTask.value
        }
        keepaliveTask = nil

        let release = isReady ? await sendLifecycleRequest("api/lifecycle/release") : nil
        let activeClients = release?["activeClients"] as? Int
        let shouldWaitForServer = activeClients == 0 || release == nil

        if let process {
            if process.isRunning && shouldWaitForServer {
                // Uvicorn is configured to drain active requests for up to ten seconds.
                for _ in 0..<120 {
                    if !process.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if process.isRunning {
                    process.terminate()
                    for _ in 0..<20 {
                        if !process.isRunning { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            // If another frontend still holds a lease, let the backend outlive
            // this app process. It will exit after the final lease is released.
            self.process = nil
        }

        isReady = false
        baseURL = nil
        status = "Backend остановлен"
    }

    func stop() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        isReady = false
    }

    private func respondsToHealthCheck(at address: URL) async -> Bool {
        do {
            let url = address.appending(path: "api/health")
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.7
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return false }
            return payload["app"] == "GraphiSchema"
                && payload["status"] == "ok"
                && payload["diagram_features"] == "container_edges_groups_exports_v3"
                && payload["revision_merge"] == "three_way_v1"
                && payload["edge_routing"] == "graphviz_v1"
                && payload["dot_sync"] == "three_way_v1"
                && payload["canvas_geometry"] == "icon_ports_v1"
                && payload["node_text"] == "fontsize_v1"
                && payload["edge_text"] == "fontsize_v1"
                && payload["label_wrap"] == "renderer_v1"
                && payload["selection_colors"] == "rgba_v1"
                && payload["edge_label_background"] == "project_defaults_v2"
                && payload["outline_styles"] == "nodes_clusters_v1"
                && payload["version_preview"] == "snapshot_layout_v1"
                && payload["container_headers"] == "fixed_11pt_v1"
                && payload["workspaces"] == "projects_branches_v4"
                && payload["prompt_templates"] == "jinja_v1"
                && payload["lifecycle"] == "leases_v1"
                && payload["storage_scope"] == "config"
                && Self.matchesDataDirectory(payload["data_directory"], expected: expectedDataDirectory ?? SettingsStore.shared.directory.appendingPathComponent("projects"))
        } catch {
            return false
        }
    }

    static func matchesDataDirectory(_ reported: String?, expected: URL) -> Bool {
        guard let reported else { return false }
        return URL(fileURLWithPath: reported).standardizedFileURL.resolvingSymlinksInPath().path
            == expected.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func findProjectRoot() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("GraphiSchema", isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        var executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for _ in 0..<7 {
            executable.deleteLastPathComponent()
            candidates.append(executable)
        }
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("pyproject.toml").path),
               FileManager.default.fileExists(atPath: candidate.appendingPathComponent("backend/graphischema/api.py").path) {
                return candidate
            }
        }
        return nil
    }

    private func findUV() -> URL? {
        var candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(NSHomeDirectory())/.local/bin/uv",
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/uv" }
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func findFreePort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = support.appendingPathComponent("GraphiSchema", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
