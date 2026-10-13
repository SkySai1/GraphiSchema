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
