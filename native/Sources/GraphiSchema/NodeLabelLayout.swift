import AppKit
import CoreText

/// Shared text frames for painting and pointer interaction, including clipping.
struct NodeLabelLayout {
    private struct Run { let text: String; let rect: NSRect }
    private let runs: [Run]
    private let clipRect: NSRect
    private let font: NSFont
    private let paragraph: NSMutableParagraphStyle

    init(node: DiagramNode, in rect: NSRect, scale: CGFloat) {
        let fontSize = CGFloat(node.style.effectiveFontSize)*scale/72
        font = .systemFont(ofSize: fontSize, weight: .semibold)
        clipRect = rect.insetBy(dx: min(8*scale/72, rect.width*0.08),
                               dy: min(6*scale/72, rect.height*0.08))
        paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch node.effectiveLabelAlignment {
        case "left": .left
        case "right": .right
        default: .center
        }
        let multiline = node.effectiveLabelWrap || node.label.contains("\n") || node.label.contains("\r")
        paragraph.lineBreakMode = multiline ? .byClipping : .byTruncatingTail
        if multiline {
            let lines = DiagramTextLayout.lines(node.label, width: Double(clipRect.width*72/scale),
                                                fontSize: node.style.effectiveFontSize, wrap: node.effectiveLabelWrap)
            let lineHeight = fontSize*1.25
            let blockHeight = CGFloat(lines.count)*lineHeight
            let top: CGFloat = switch node.effectiveLabelVerticalAlignment {
            case "top": clipRect.maxY
            case "bottom": clipRect.minY+blockHeight
            default: clipRect.midY+blockHeight/2
            }
            let contentRect = clipRect
            runs = lines.enumerated().map { index, text in
                Run(text: text, rect: NSRect(x: contentRect.minX, y: top-CGFloat(index+1)*lineHeight,
                                            width: contentRect.width, height: lineHeight))
            }
        } else {
            let measured = (node.label as NSString).boundingRect(with: clipRect.size, options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .paragraphStyle: paragraph])
            let height = min(clipRect.height, max(font.ascender-font.descender, measured.height))
            let y: CGFloat = switch node.effectiveLabelVerticalAlignment {
            case "top": clipRect.maxY-height
            case "bottom": clipRect.minY
            default: clipRect.midY-height/2
            }
            runs = [Run(text: node.label, rect: NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: height))]
        }
    }

    func draw(color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clipRect).addClip()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        for run in runs { (run.text as NSString).draw(in: run.rect, withAttributes: attributes) }
    }

    var visibleGlyphBounds: [NSRect] {
        var result: [NSRect] = []
        for run in runs where !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let storage = NSTextStorage(string: run.text, attributes: [.font: font, .paragraphStyle: paragraph])
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: run.rect.width, height: max(run.rect.height, font.ascender-font.descender+font.leading)))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 1
            container.lineBreakMode = paragraph.lineBreakMode
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { continue }
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: [.font: font]) as CFAttributedString)
            if paragraph.lineBreakMode == .byTruncatingTail, CTLineGetTypographicBounds(line, nil, nil, nil) > run.rect.width {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font]) as CFAttributedString)
                line = CTLineCreateTruncatedLine(line, Double(run.rect.width), .end, token) ?? line
            }
            let flush: CGFloat = paragraph.alignment == .left ? 0 : paragraph.alignment == .right ? 1 : 0.5
            let x = run.rect.minX+CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(run.rect.width)))
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let baseline = run.rect.maxY-fragment.minY-manager.location(forGlyphAt: glyphs.location).y
            var ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            // Color emoji can be bitmap glyphs without an outline path.
            if ink.isNull || ink.isEmpty { ink = CTLineGetImageBounds(line, nil) }
            // Glyphs such as j can overhang their typographic advance. Include
            // their actual paths and subpixel coverage, rather than a text cell.
            let visible = NSRect(x: x+ink.minX, y: baseline+ink.minY, width: ink.width, height: ink.height)
                .insetBy(dx: -0.75, dy: -0.75).intersection(clipRect)
            if !visible.isEmpty { result.append(visible) }
        }
        return result
    }

    func contains(_ point: NSPoint) -> Bool { visibleGlyphBounds.contains { $0.contains(point) } }
}
