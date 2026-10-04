import Foundation
import InkVault

/// Paper background and ruling as draw commands.
public enum PaperRenderer {
    /// Line width of ruled and grid lines, points.
    public static let ruleWidth = 0.5
    /// Dot radius for `dot` paper, points.
    public static let dotRadius = 0.9

    /// Commands for a `width` x `height` region whose top edge is at global
    /// page y = `yOffset` and whose bottom edge is at `yEnd` (default
    /// `yOffset + height`). Non-zero `yOffset` is used for infinite-page chunks.
    ///
    /// Ruling is laid out in global coordinates, so it continues across chunks.
    /// A rule at global `y = k * spacing` (k >= 1) belongs to exactly the one
    /// chunk with `yOffset <= y < yEnd` (half-open), so a rule exactly on a
    /// boundary is drawn once, at local y = 0, in the lower chunk.
    ///
    /// Paper whose spacing is below `RenderLimits.minPaperSpacing` (or not
    /// finite), or that would need more than `RenderLimits.maxPaperCommands`
    /// commands, renders as the plain background.
    public static func commands(paper: Paper, width: Double, height: Double,
                                yOffset: Double = 0, yEnd: Double? = nil) -> [DrawCommand] {
        var out = [DrawCommand(.rect(x: 0, y: 0, width: width, height: height), fill: Paint(paper.background))]
        let s = paper.spacing
        let bottom = yEnd ?? (yOffset + height)
        guard paper.kind != .blank, s.isFinite, s >= RenderLimits.minPaperSpacing,
              width.isFinite, bottom.isFinite, yOffset.isFinite,
              width <= RenderLimits.maxExtent, abs(bottom) <= RenderLimits.maxExtent * 2 else { return out }

        // Half-open index ranges: rows k in [rowStart, rowEnd), cols k in [1, colEnd).
        let rowStartD = max((yOffset / s).rounded(.up), 1)
        let rowEndD = (bottom / s).rounded(.up)
        let colEndD = (width / s).rounded(.up)
        let rowCountD = max(rowEndD - rowStartD, 0), colCountD = max(colEndD - 1, 0)
        let estimate: Double
        switch paper.kind {
        case .blank: estimate = 0
        case .ruled: estimate = rowCountD
        case .grid: estimate = rowCountD + colCountD
        case .dot: estimate = rowCountD * colCountD
        }
        guard estimate <= RenderLimits.maxPaperCommands else { return out }
        let rows = rowCountD > 0 ? Array(Int(rowStartD)..<Int(rowEndD)) : []
        let cols = colCountD > 0 ? Array(1..<Int(colEndD)) : []

        let line = Paint(paper.lineColor)
        switch paper.kind {
        case .blank:
            break
        case .ruled:
            for k in rows { out.append(hline(Double(k) * s - yOffset, width, line)) }
        case .grid:
            for k in rows { out.append(hline(Double(k) * s - yOffset, width, line)) }
            for k in cols {
                let x = Double(k) * s
                out.append(DrawCommand(.line(from: Point(x: x, y: 0), to: Point(x: x, y: height)),
                                       stroke: line, lineWidth: ruleWidth))
            }
        case .dot:
            for r in rows {
                for k in cols {
                    out.append(DrawCommand(.circle(center: Point(x: Double(k) * s, y: Double(r) * s - yOffset),
                                                   radius: dotRadius), fill: line))
                }
            }
        }
        return out
    }

    private static func hline(_ y: Double, _ width: Double, _ p: Paint) -> DrawCommand {
        DrawCommand(.line(from: Point(x: 0, y: y), to: Point(x: width, y: y)), stroke: p, lineWidth: ruleWidth)
    }
}
