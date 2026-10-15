import AppKit
import Darwin

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private let backend = BackendService()
    private var editors: [(AppModel, MainWindowController)] = []
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.onError = { message in
            let alert = NSAlert(); alert.messageText = message; alert.runModal()
        }
        let saved = SettingsStore.shared.data(forKey: "GraphiSchema.lastWorkspace").flatMap { try? JSONDecoder().decode(ProjectWorkspace.self, from: $0) }
        openProjectWindow(saved)
    }

    func openProjectWindow(_ target: ProjectWorkspace? = nil) {
        let model = AppModel(backend: backend, workspace: target)
        let controller = MainWindowController(model: model)
        editors.append((model, controller))
        controller.onOpenWorkspace = { [weak self, weak controller, weak model] workspace, newWindow in
            guard let self else { return }
            if newWindow { self.openProjectWindow(workspace) }
            else if let model, let controller {
                Task {
                    do { try await model.openWorkspace(workspace); controller.refreshAll() }
                    catch { model.onAlert?(error.localizedDescription) }
                }
            }
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await model.bootstrap()
            controller.refreshAll()
            await controller.loadStarterTemplateIfNeeded()
            if ProcessInfo.processInfo.arguments.contains("--startup-smoke-test") {
                let passed = model.backend.isReady && model.diagram != nil && model.layout != nil && model.alertMessage == nil
                let message = passed
                    ? "Native startup smoke test passed: bundled backend, compatible health, project decoding, Graphviz layout and native window.\n"
                    : "Native startup smoke test failed: \(model.status), \(model.backend.status), \(model.alertMessage ?? "no details")\n"
                (passed ? FileHandle.standardOutput : FileHandle.standardError).write(Data(message.utf8))
                try? await model.saveNow()
                backend.stop()
                if !passed { exit(EXIT_FAILURE) }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.arguments.contains("--startup-smoke-test") { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        for (model, controller) in editors where model.jsonDraftIsDirty || model.dotDraftIsDirty {
            controller.showWindow(nil)
            let alert = NSAlert()
            alert.messageText = "В проекте есть неприменённый код"
            alert.informativeText = "Примените черновик перед выходом или выйдите, сохранив только последнюю применённую диаграмму."
            alert.addButton(withTitle: "Вернуться к редактированию")
            alert.addButton(withTitle: "Выйти без применения")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        isTerminating = true
        Task {
            do {
                for (model, _) in editors { try await model.saveNow() }
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                isTerminating = false
                let alert = NSAlert(); alert.messageText = "Не удалось сохранить проекты: \(error.localizedDescription)"; alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openProjectWindow() }
        return true
    }
}

@main
enum GraphiSchemaApp {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--project-regression-test") {
            NativeProjectRegressionTests.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--interaction-regression-test") {
            NativeInteractionRegressionTests.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--arrow-regression-test") {
            NativeArrowRegressionTests.run()
            return
        }
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
