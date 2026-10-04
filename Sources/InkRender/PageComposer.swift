import Foundation
import InkVault

/// One output page: a vertical slice of a note page.
struct PageChunk {
    var yOffset: Double
    var width: Double
    var height: Double
}

/// Shared layout logic for the PDF and SVG writers.
enum PageComposer {
    /// Conservative page-space bounding box of a stroke (control hull + pen radius).
    static func bounds(of stroke: Stroke) -> (minY: Double, maxY: Double)? {
        guard !stroke.points.isEmpty else { return nil }
        let xf = stroke.transform ?? .identity
        let r = (stroke.points.map { max($0.w, $0.h) }.max() ?? 0).magnitude
        let pad = max(r, stroke.ink.width) * xf.meanScale / 2 + 1
        let ys = stroke.points.map { xf.apply(x: $0.x, y: $0.y).y }
        guard let lo = ys.min(), let hi = ys.max() else { return nil }
        return (lo - pad, hi + pad)
    }

    /// Total height of the page: `pageSize.height`, or for infinite pages the
    /// larger of that and the lowest stroke edge (rounded up).
    static func extent(page: Page, meta: NoteMeta) -> Double {
        let size = meta.pageSize
        guard size.infinite else { return size.height }
        let low = page.strokes.compactMap { bounds(of: $0)?.maxY }.max() ?? 0
        return max(size.height, low.rounded(.up))
    }

    static func chunks(page: Page, meta: NoteMeta, options: RenderOptions) -> [PageChunk] {
        let size = meta.pageSize
        guard size.infinite else { return [PageChunk(yOffset: 0, width: size.width, height: size.height)] }
        let chunkH = max(options.infiniteChunkHeight ?? size.height, 1)
        let total = extent(page: page, meta: meta)
        let count = max(Int((total / chunkH).rounded(.up)), 1)
        return (0..<count).map { PageChunk(yOffset: Double($0) * chunkH, width: size.width, height: chunkH) }
    }

    /// Paper (if enabled) then strokes, in chunk-local coordinates.
    static func layers(page: Page, meta: NoteMeta, chunk: PageChunk, options: RenderOptions)
        -> (paper: [DrawCommand], strokes: [DrawCommand]) {
        var paper: [DrawCommand] = []
        var out: [DrawCommand] = []
        if options.paper {
            paper = PaperRenderer.commands(paper: meta.paper, width: chunk.width, height: chunk.height, yOffset: chunk.yOffset)
        }
        let finite = !meta.pageSize.infinite
        for stroke in page.strokes {
            if !finite, let b = bounds(of: stroke), b.maxY < chunk.yOffset || b.minY > chunk.yOffset + chunk.height {
                continue
            }
            out += StrokeOutline.commands(for: stroke, tolerance: options.tolerance, offsetY: -chunk.yOffset)
        }
        return (paper, out)
    }
}
