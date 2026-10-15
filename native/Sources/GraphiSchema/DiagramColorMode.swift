import AppKit

enum DiagramColorMode {
    static func resolve(_ value: String, mode: String?, parameter: DiagramColorParameter, theme: String) -> String {
        guard mode == "theme" || mode == "inverse" else { return value }
        var white = parameter == .fill ? theme == "light" : theme == "dark"
        if mode == "inverse" { white.toggle() }
        return white ? "#FFFFFF" : "#000000"
    }
}

protocol ThemedObjectStyle {
    var fill: String { get }; var stroke: String { get }; var text: String { get }
    var fillMode: String? { get set }; var strokeMode: String? { get set }; var textMode: String? { get set }
}
extension ThemedObjectStyle {
    func mode(_ parameter: DiagramColorParameter) -> String {
        switch parameter { case .fill: fillMode ?? "custom"; case .stroke: strokeMode ?? "custom"; case .text: textMode ?? "custom" }
    }
    func resolved(_ parameter: DiagramColorParameter, theme: String) -> String {
        let value: String
        switch parameter { case .fill: value = fill; case .stroke: value = stroke; case .text: value = text }
        return DiagramColorMode.resolve(value, mode: mode(parameter), parameter: parameter, theme: theme)
    }
    mutating func setMode(_ parameter: DiagramColorParameter, _ value: String) {
        switch parameter { case .fill: fillMode = value; case .stroke: strokeMode = value; case .text: textMode = value }
    }
}
extension NodeStyle: ThemedObjectStyle {}
extension ContainerStyle: ThemedObjectStyle {}
extension EdgeStyle {
    func mode(_ parameter: DiagramColorParameter) -> String { (parameter == .text ? textMode : colorMode) ?? "custom" }
    func resolved(_ parameter: DiagramColorParameter, theme: String) -> String {
        DiagramColorMode.resolve(parameter == .text ? (text ?? (theme == "dark" ? "#FFFFFF" : "#172238")) : color,
                                 mode: mode(parameter), parameter: parameter, theme: theme)
    }
    mutating func setMode(_ parameter: DiagramColorParameter, _ value: String) {
        if parameter == .text { textMode = value } else if parameter == .stroke { colorMode = value }
    }
}
