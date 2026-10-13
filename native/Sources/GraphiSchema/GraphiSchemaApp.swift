import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(model: model)
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await model.bootstrap()
            controller.refreshAll()
            if ProcessInfo.processInfo.arguments.contains("--startup-smoke-test") {
                let passed = model.backend.isReady && model.diagram != nil && model.layout != nil && model.alertMessage == nil
                let message = passed
                    ? "Native startup smoke test passed: bundled backend, compatible health, project decoding, Graphviz layout and native window.\n"
                    : "Native startup smoke test failed: \(model.status), \(model.backend.status), \(model.alertMessage ?? "no details")\n"
                (passed ? FileHandle.standardOutput : FileHandle.standardError).write(Data(message.utf8))
                model.backend.stop()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.backend.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
enum GraphiSchemaApp {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") {
            NativeUISmokeTest.run()
            return
        }
        let application = NSApplication.shared
        let lifecycle = AppLifecycle()
        application.delegate = lifecycle
        application.setActivationPolicy(.regular)
        application.run()
    }
}
