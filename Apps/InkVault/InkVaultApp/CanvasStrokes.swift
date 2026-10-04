import Foundation
import InkVault
import PencilKit

extension CanvasStrokeInfo {
    /// Fingerprints a PencilKit stroke in O(1) of its length: no conversion,
    /// only a handful of control points.
    init(_ pk: PKStroke) {
        let path = pk.path
        let n = path.count
        let color = InkVault.Color(pk.ink.color)
        let t = pk.transform
        let ink = pk.ink.inkType.rawValue
        var family: [Double] = [Double(color.r), Double(color.g), Double(color.b), Double(color.a)]
        family += [Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)]
        family.append(path.creationDate.timeIntervalSinceReferenceDate)

        var signature: [Double] = [Double(n)]
        var key = family
        key.append(Double(n))
        key.append(Double(pk.randomSeed))
        if n > 0 {
            for i in Set([0, n / 3, n / 2, (2 * n) / 3, n - 1]).sorted() {
                let p = path[i]
                key += [Double(p.location.x), Double(p.location.y), Double(p.size.width), p.timeOffset, Double(p.force)]
            }
            let first = path[0].location, last = path[n - 1].location
            signature += [Double(first.x), Double(first.y), Double(last.x), Double(last.y)]
        }
        if pk.mask != nil {
            key.append(-1)
            for r in pk.maskedPathRanges { key += [Double(r.lowerBound), Double(r.upperBound)] }
        }
        let b = pk.renderBounds
        self.init(key: Key(ink: ink, values: key), family: Family(ink: ink, values: family),
                  pathSignature: signature,
                  bounds: Bounds(minX: Double(b.minX), minY: Double(b.minY), maxX: Double(b.maxX), maxY: Double(b.maxY)))
    }

    /// The fingerprint of the canvas stroke a stored stroke is shown as.
    init(stored: Stroke) {
        self.init(StrokeConversion.pkStroke(stored))
    }
}

extension StrokeLedger {
    /// Ledger items for a canvas drawing. New strokes record the inking
    /// tool's width as `Ink.width` when the tool still has their ink type.
    static func items(for drawing: PKDrawing, tool: PKTool?) -> [Item] {
        let inking = tool as? PKInkingTool
        return drawing.strokes.map { pk in
            let width: Double? = inking.flatMap { $0.inkType == pk.ink.inkType ? Double($0.width) : nil }
            return Item(info: CanvasStrokeInfo(pk), make: { StrokeConversion.strokes(from: pk, nominalWidth: width) })
        }
    }

    /// The canvas drawing for the ledger's live strokes, one canvas stroke
    /// per stored stroke. Call `rebase(info:)` with `CanvasStrokeInfo.init(stored:)`
    /// when showing it.
    var drawing: PKDrawing {
        PKDrawing(strokes: live.map(StrokeConversion.pkStroke))
    }
}
