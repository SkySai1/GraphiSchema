import Foundation
import Darwin

@MainActor
final class BackendService: ObservableObject {
    private(set) var status = "Запуск локального backend…"
    private(set) var isReady = false
    private(set) var baseURL: URL?

    private let preferredPort = 8765
    private var process: Process?
    private(set) var projectRoot: URL?

    func start() async {
        guard !isReady else { return }
        if let process, process.isRunning {
            status = "Запуск локального backend…"
            return
        }
        let preferredAddress = URL(string: "http://127.0.0.1:\(preferredPort)")!

        if await respondsToHealthCheck(at: preferredAddress) {
            baseURL = preferredAddress
            isReady = true
            status = "Backend готов"
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
            let dataDirectory = support.appendingPathComponent("projects", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

            let server = Process()
            server.executableURL = uv
            server.arguments = [
                "run", "--project", root.path,
                "python", "-m", "uvicorn", "graphischema.api:app",
                "--app-dir", "backend", "--host", "127.0.0.1", "--port", String(port),
            ]
            server.currentDirectoryURL = root
            var environmentVariables = ProcessInfo.processInfo.environment
            let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
            environmentVariables["PATH"] = (extraPaths + [environmentVariables["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            environmentVariables["UV_PROJECT_ENVIRONMENT"] = environment.path
            environmentVariables["GRAPHI_SCHEMA_DATA_DIR"] = dataDirectory.path
            environmentVariables["PYTHONDONTWRITEBYTECODE"] = "1"
            server.environment = environmentVariables
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            process = server

            for _ in 0..<60 {
                if await respondsToHealthCheck(at: address) {
                    isReady = true
                    status = "Backend готов"
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

    func stop() {
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
                && payload["revision_merge"] == "three_way_v1"
                && payload["edge_routing"] == "graphviz_v1"
                && payload["storage_scope"] == "application-support"
        } catch {
            return false
        }
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
