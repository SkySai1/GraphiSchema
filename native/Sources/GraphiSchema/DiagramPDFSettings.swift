import AppKit

struct DiagramPDFSettings: Equatable {
    static let formats = [("a4", "A4"), ("a3", "A3"), ("a2", "A2"), ("a5", "A5"),
                          ("letter", "Letter"), ("custom", "Свой размер"), ("content", "По размеру схемы")]
    var format = "a4"
    var landscape = true
    var customWidthMM = 297.0
    var customHeightMM = 210.0
    var marginMM = 10.0
    var occupancy = 0.96
    var includeTitle = true
    var includeBranch = false
    var branchName = ""
    var watermark = true
    var preserveGroups = true
    var showGroups = false
    var includeLegend = true
    var legendOnSeparatePage = false
    var pageNumbers = true
    var nodeStroke = 1.0
    var containerStroke = 1.0
    var edgeStroke = 1.0
    var nodeText = 1.0
    var edgeText = 1.0
    var containerFontSize = 11.0
    var arrowSize = 1.0
    var spacing = 1.0
    var gap = 12.0
    var avoidOverlaps = true
    var fitNodeLabels = true
    var wrapNodeLabels = true
    var placeEdgeLabels = true
    var labelBackground = "opaque"
    var contrastText = true

    var headerHeight: CGFloat { (includeTitle ? 38 : 0)+(includeBranch ? 18 : 0) }
    var footerHeight: CGFloat { pageNumbers || watermark ? 18 : 0 }
    var margin: CGFloat { CGFloat(marginMM)*72/25.4 }
    var containerHeaderHeight: CGFloat { max(28, CGFloat(containerFontSize)*1.3+12) }

    func pageSize(scene: NSSize) -> NSSize {
        if format == "custom" {
            return NSSize(width: customWidthMM*72/25.4, height: customHeightMM*72/25.4)
        }
        if format == "content" {
            let legend: CGFloat = includeLegend && !legendOnSeparatePage ? 204 : 0
            return NSSize(width: min(14_400, max(300, scene.width+margin*2+legend)),
                          height: min(14_400, max(250, scene.height+margin*2+headerHeight+footerHeight)))
        }
        let size: NSSize = switch format {
        case "a3": NSSize(width: 842, height: 1191)
        case "a2": NSSize(width: 1191, height: 1684)
        case "a5": NSSize(width: 420, height: 595)
        case "letter": NSSize(width: 612, height: 792)
        default: NSSize(width: 595, height: 842)
        }
        return landscape ? NSSize(width: size.height, height: size.width) : size
    }
}

/// Metrics in the unscaled vector scene. A single page transform scales all of them.
struct DiagramPDFCanvasStyle {
    var containerFontSize: CGFloat = 11
    var arrowSize: CGFloat = 1
    var containerFrames: [String: NSRect] = [:]
    var edgeLabels: [String: NSPoint] = [:]
    var labelLeaders: [String: NSPoint] = [:]
    var showGroups = false
    var containerHeaderHeight: CGFloat { max(28, containerFontSize*1.3+12) }
}
