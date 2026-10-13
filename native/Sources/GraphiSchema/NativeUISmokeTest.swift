import AppKit

@MainActor
enum NativeUISmokeTest {
    static func run() {
        _ = NSApplication.shared
        let model = AppModel()
        let starterURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("examples/starter.json")
        guard let starterData = try? Data(contentsOf: starterURL) else {
            fatalError("Native UI smoke test cannot load examples/starter.json.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let starter = try? decoder.decode(DiagramProject.self, from: starterData) else {
            fatalError("Native UI smoke test cannot decode the starter project.")
        }
        model.diagram = starter
        let mainWindow = MainWindowController(model: model)
        model.selection = .node("waf")
        mainWindow.refreshAll()
        model.selection = .container("dmz")
        mainWindow.refreshAll()
        model.selection = .edge(starter.edges.first?.id ?? "")
        mainWindow.refreshAll()
        let assistantWindow = OllamaAssistantWindowController(model: model)

        guard mainWindow.window?.title == "GraphiSchema",
              mainWindow.window?.contentView?.subviews.isEmpty == false,
              assistantWindow.window?.title == "GraphiSchema · Ollama",
              assistantWindow.window?.contentView?.subviews.isEmpty == false
        else {
            fatalError("Native UI smoke test failed: expected AppKit windows and controls.")
        }
        print("Native UI smoke test passed: editor and Ollama AppKit windows are constructed.")
    }
}
