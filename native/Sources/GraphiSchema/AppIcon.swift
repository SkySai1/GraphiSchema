import AppKit

@MainActor
enum AppIcon {
    /// Both the application and workspace header use the same full-color master.
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "GraphiSchema", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return ProjectResources.data("resources/app-icon/GraphiSchema.png").flatMap { NSImage(data: $0) }
    }()

    static func install(on application: NSApplication) {
        if let image { application.applicationIconImage = image }
    }
}
