import Foundation

/// The same style commands are used by the inspector and canvas context menus.
enum DiagramStyleChange: Equatable {
    case lineStyle(String)
    case penwidth(Double)
    case arrowhead(String)
    case arrowtail(String)
    case direction(String)
    case routing(String?)
    case labelBackgroundTransparent(Bool)
    case fontSize(Double)
    case labelAlignment(String)
    case labelVerticalAlignment(String)
    case labelWrap(Bool)
    case reverse

    var isValid: Bool {
        switch self {
        case .lineStyle(let value): return DiagramStyleOptions.edgeLines.contains { $0.value == value }
        case .penwidth(let value): return value.isFinite && (0.5...10).contains(value)
        case .arrowhead(let value), .arrowtail(let value): return DiagramStyleOptions.arrows.contains { $0.value == value }
        case .direction(let value): return DiagramStyleOptions.directions.contains { $0.value == value }
        case .routing(let value): return DiagramStyleOptions.routes.contains { $0.value == (value ?? "") }
        case .fontSize(let value): return value.isFinite && (1...144).contains(value)
        case .labelAlignment(let value): return DiagramStyleOptions.textAlignment.contains { $0.value == value }
        case .labelVerticalAlignment(let value): return DiagramStyleOptions.textVerticalAlignment.contains { $0.value == value }
        case .labelBackgroundTransparent, .labelWrap, .reverse: return true
        }
    }
}

struct DiagramStyleCommand {
    let selection: DiagramSelection
    let change: DiagramStyleChange
}

enum DiagramStyleOptions {
    static let textAlignment: [(value: String, title: String)] = [
        ("left", "Влево"), ("center", "По центру"), ("right", "Вправо"),
    ]
    static let textVerticalAlignment: [(value: String, title: String)] = [
        ("top", "Сверху"), ("middle", "Посередине"), ("bottom", "Снизу"),
    ]
    static let nodeLines: [(value: String, title: String)] = [
        ("solid", "Сплошная"), ("dashed", "Пунктирная"), ("dotted", "Точечная"),
    ]
    static let edgeLines = nodeLines + [(value: "bold", title: "Жирная (от 3 pt)")]
    static let widths: [Double] = [0.5, 1, 1.2, 1.5, 2, 3, 4, 6, 8, 10]
    static let arrows: [(value: String, title: String)] = [
        ("normal", "Треугольник"), ("vee", "Открытая стрелка"), ("diamond", "Ромб"),
        ("dot", "Круг"), ("box", "Квадрат"), ("crow", "Развилка"),
        ("tee", "Поперечная черта"), ("none", "Без наконечника"),
    ]
    static let directions: [(value: String, title: String)] = [
        ("forward", "От источника к цели"), ("both", "В обе стороны"), ("none", "Без стрелок"),
    ]
    static let routes: [(value: String, title: String)] = [
        ("", "Как у диаграммы"), ("straight", "Прямая"), ("angled", "Косая ломаная"),
        ("orthogonal", "Прямоугольная"), ("curved", "Кривая · Graphviz"),
    ]
}
