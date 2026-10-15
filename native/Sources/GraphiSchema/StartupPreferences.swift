import Foundation

enum StartupWindowMode: String, CaseIterable {
    case lastProject = "last_project"
    case emptyCanvas = "empty_canvas"

    var title: String {
        switch self {
        case .lastProject: "Последний проект"
        case .emptyCanvas: "Пустой холст"
        }
    }
}

@MainActor
enum StartupPreferences {
    static let modeKey = "GraphiSchema.startupWindow"
    static let lastWorkspaceKey = "GraphiSchema.lastWorkspace"

    static func mode(in settings: SettingsStore? = nil) -> StartupWindowMode {
        (settings ?? .shared).string(forKey: modeKey).flatMap(StartupWindowMode.init(rawValue:)) ?? .lastProject
    }

    static func workspaceToRestore(in settings: SettingsStore? = nil) -> ProjectWorkspace? {
        let settings = settings ?? .shared
        guard mode(in: settings) == .lastProject,
              let data = settings.data(forKey: lastWorkspaceKey),
              let workspace = try? JSONDecoder().decode(ProjectWorkspace.self, from: data),
              !workspace.projectId.isEmpty, !workspace.branchId.isEmpty else { return nil }
        return workspace
    }
}
