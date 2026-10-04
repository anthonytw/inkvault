import Foundation
import InkVault

/// One output page: a vertical slice of a note page. `yOffset ..< yEnd` is the
/// slice in page coordinates; `height` is `yEnd - yOffset`.
struct PageChunk {
    var yOffset: Double
    var yEnd: Double
    var width: Double
    var height: Double { yEnd - yOffset }
}

/// A note page validated once, with each stroke's page-space bounds computed
/// once, ready to be cut into chunks. Shared by the PDF and SVG writers.
struct PreparedPage {
    let meta: NoteMeta
    let options: RenderOptions
    /// Non-empty strokes with their conservative vertical extent.
    let strokes: [(stroke: Stroke, minY: Double, maxY: Double)]
    /// Total page height: `pageSize.height`, or for infinite pages the larger
    /// of that and the lowest stroke edge (rounded up).
    let extent: Double

    /// Validates `meta`/`page` and computes bounds.
    ///
    /// - Throws: `RenderError.invalidPageSize`, `.invalidGeometry` (non-finite
    ///   stroke data) or `.extentTooLarge` (an infinite page that would
    ///   exceed `RenderLimits.maxExtent`). Strokes far outside a finite page
    ///   are not an error; they are simply culled.
    init(page: Page, meta: NoteMeta, options: RenderOptions) throws {
        let size = meta.pageSize
        let maxE = RenderLimits.maxExtent
        guard size.width.isFinite, size.width > 0, size.width <= maxE,
              size.height.isFinite, size.height >= 0, size.height <= maxE,
              size.infinite || size.height > 0 else { throw RenderError.invalidPageSize }
        self.meta = meta
        self.options = options

        var list: [(stroke: Stroke, minY: Double, maxY: Double)] = []
        var low = 0.0
        for stroke in page.strokes where !stroke.points.isEmpty {
            let xf = stroke.transform ?? .identity
            let radius = stroke.points.reduce(stroke.ink.width.magnitude) { max($0, $1.w.magnitude, $1.h.magnitude) }
            let pad = radius * xf.meanScale / 2 + 1
            var lo = Double.infinity, hi = -Double.infinity
            for p in stroke.points {
                let y = xf.apply(x: p.x, y: p.y).y
                guard y.isFinite, p.x.isFinite, p.w.isFinite, p.h.isFinite, stroke.ink.width.isFinite else { throw RenderError.invalidGeometry }
                lo = min(lo, y); hi = max(hi, y)
            }
            guard lo.isFinite, hi.isFinite, pad.isFinite else { throw RenderError.invalidGeometry }
            list.append((stroke, lo - pad, hi + pad))
            low = max(low, hi + pad)
        }
        if size.infinite {
            guard low <= maxE else { throw RenderError.extentTooLarge(low) }
            extent = max(size.height, low.rounded(.up))
        } else {
            extent = size.height
        }
        strokes = list
    }

    /// Chunk height for infinite pages: the option (clamped), else letter aspect from the width.
    var chunkHeight: Double {
        let base = options.infiniteChunkHeight ?? meta.pageSize.width * 11 / 8.5
        return min(max(base.isFinite ? base : 792, 72), RenderLimits.maxExtent)
    }

    /// Output pages for this note page.
    var chunks: [PageChunk] {
        let w = meta.pageSize.width
        guard meta.pageSize.infinite else { return [PageChunk(yOffset: 0, yEnd: extent, width: w)] }
        let h = chunkHeight
        let count = max(Int((extent / h).rounded(.up)), 1)   // extent <= maxExtent, h >= 72
        return (0..<count).map { PageChunk(yOffset: Double($0) * h, yEnd: Double($0 + 1) * h, width: w) }
    }

    /// Paper (if enabled) and strokes for `chunk`, in chunk-local coordinates.
    /// Strokes that miss the chunk are skipped.
    func layers(for chunk: PageChunk) -> (paper: [DrawCommand], strokes: [DrawCommand]) {
        var paper: [DrawCommand] = []
        if options.paper {
            paper = PaperRenderer.commands(paper: meta.paper, width: chunk.width, height: chunk.height,
                                           yOffset: chunk.yOffset, yEnd: chunk.yEnd)
        }
        var out: [DrawCommand] = []
        for s in strokes where !(s.maxY < chunk.yOffset || s.minY > chunk.yEnd) {
            out += StrokeOutline.commands(for: s.stroke, tolerance: options.tolerance, offsetY: -chunk.yOffset)
        }
        return (paper, out)
    }
}
