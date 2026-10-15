import Foundation
import Darwin

/// JSON settings in ~/.config; mutations merge under a process-independent lock.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    let directory: URL
    let fileURL: URL
    private(set) var lastError: String?
    var onError: ((String) -> Void)?

    init(directory: URL? = nil, migrateLegacy: Bool = true) {
        let arguments = ProcessInfo.processInfo.arguments
        let isolated = arguments.contains { $0.hasSuffix("-test") }
        let override = ProcessInfo.processInfo.environment["GRAPHI_SCHEMA_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? override ?? (isolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("graphischema-settings-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/graphischema", isDirectory: true))
        fileURL = self.directory.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            var migrated: [String: Any] = [:]
            if migrateLegacy && !isolated && directory == nil && override == nil {
                for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix("GraphiSchema.") {
                    if let encoded = Self.jsonValue(value) { migrated[key] = encoded }
                }
            }
            mutate { current in for (key, value) in migrated where current[key] == nil { current[key] = value } }
        }
    }

    private static func jsonValue(_ value: Any) -> Any? {
        if let data = value as? Data { return ["$data": data.base64EncodedString()] }
        return JSONSerialization.isValidJSONObject(["value": value]) ? value : nil
    }

    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }

    func object(forKey key: String) -> Any? {
        let value: Any?
        do { value = try read()[key] }
        catch { lastError = "Не удалось прочитать настройки: \(error.localizedDescription)"; return nil }
        if let wrapper = value as? [String: String], let base64 = wrapper["$data"] { return Data(base64Encoded: base64) }
        return value
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func set(_ value: Any?, forKey key: String) {
        mutate { values in values[key] = value.flatMap(Self.jsonValue) }
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }

    private func mutate(_ change: (inout [String: Any]) -> Void) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let descriptor = open(directory.appendingPathComponent("settings.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(descriptor, LOCK_UN); close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
            var values = try read()
            let previous = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            change(&values)
            if previous == (try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])), FileManager.default.fileExists(atPath: fileURL.path) {
                lastError = nil
                return
            }
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "Не удалось сохранить настройки: \(error.localizedDescription)"
            onError?(lastError!)
        }
    }
}
