import Foundation
import InkVault

/// Paper background and ruling as draw commands.
public enum PaperRenderer {
    /// Line width of ruled and grid lines, points.
    public static let ruleWidth = 0.5
    /// Dot radius for `dot` paper, points.
    public static let dotRadius = 0.9

    /// Commands for a `width` x `height` region whose top edge is at global
    /// page y = `yOffset` (non-zero for infinite-page chunks). Ruling is laid
    /// out in global coordinates so it continues across chunks.
    public static func commands(paper: Paper, width: Double, height: Double, yOffset: Double = 0) -> [DrawCommand] {
        var out = [DrawCommand(.rect(x: 0, y: 0, width: width, height: height), fill: Paint(paper.background))]
        let s = paper.spacing
        guard s > 0, paper.kind != .blank else { return out }
        let line = Paint(paper.lineColor)
        let firstRow = max(Int((yOffset / s).rounded(.up)), 1)
        let endY = yOffset + height
        var rows: [Double] = []
        var k = firstRow
        while Double(k) * s < endY - 1e-9 { rows.append(Double(k) * s); k += 1 }
        var cols: [Double] = []
        k = 1
        while Double(k) * s < width - 1e-9 { cols.append(Double(k) * s); k += 1 }

        switch paper.kind {
        case .blank:
            break
        case .ruled:
            for y in rows { out.append(hline(y - yOffset, width, line)) }
        case .grid:
            for y in rows { out.append(hline(y - yOffset, width, line)) }
            for x in cols {
                out.append(DrawCommand(.line(from: Point(x: x, y: 0), to: Point(x: x, y: height)),
                                       stroke: line, lineWidth: ruleWidth))
            }
        case .dot:
            for y in rows {
                for x in cols {
                    out.append(DrawCommand(.circle(center: Point(x: x, y: y - yOffset), radius: dotRadius), fill: line))
                }
            }
        }
        return out
    }

    private static func hline(_ y: Double, _ width: Double, _ p: Paint) -> DrawCommand {
        DrawCommand(.line(from: Point(x: 0, y: y), to: Point(x: width, y: y)), stroke: p, lineWidth: ruleWidth)
    }
}
