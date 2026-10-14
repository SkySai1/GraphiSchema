import Foundation

/// Uses the same conservative glyph advances as backend/graphischema/text_layout.py.
enum DiagramTextLayout {
    private static func units(_ character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let character = Character(String(scalar))
        if character.isWhitespace { return 0.35 }
        if scalar.value >= 0x2E80 { return 1.1 }
        if "mwMW@#%&ÆæЖШЩЮЫжшщюы".contains(character) { return 1.05 }
        if "ilIjtf.,:;!'|`".contains(character) { return 0.4 }
        if "r()[]{}".contains(character) { return 0.45 }
        return character.isUppercase ? 0.78 : 0.63
    }

    static func lines(_ text: String, width: Double, fontSize: Double, wrap: Bool) -> [String] {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard wrap else { return paragraphs }
        let limit = max(0.01, width / max(1, fontSize))
        func fits(_ value: String) -> Bool { value.reduce(0) { $0 + units($1) } <= limit + 1e-8 }
        var lines: [String] = []
        for paragraph in paragraphs {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.isEmpty { lines.append(""); continue }
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if fits(candidate) { current = candidate; continue }
                if !current.isEmpty { lines.append(current); current = "" }
                for character in word {
                    if !current.isEmpty && !fits(current + String(character)) { lines.append(current); current = "" }
                    current.append(character)
                }
            }
            lines.append(current)
        }
        return lines
    }
}
