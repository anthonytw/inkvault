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

/// A note page validated once, with every stroke sampled and outlined once in
/// page coordinates, ready to be cut into chunks. Shared by the PDF and SVG
/// writers.
struct PreparedPage {
    struct PreparedStroke {
        /// Geometry in page coordinates.
        var commands: [DrawCommand]
        var minY: Double
        var maxY: Double
    }

    let meta: NoteMeta
    /// The page's own paper, else the note's.
    let paper: Paper
    let options: RenderOptions
    let strokes: [PreparedStroke]
    /// Total page height: `pageSize.height`, or for infinite pages the largest
    /// of that, the lowest stroke edge (rounded up) and one chunk height.
    let extent: Double
    /// The paper as drawn: `paper`, or its plain background when ruling
    /// every band would take more than `RenderLimits.maxPaperCommandsPerPage`
    /// commands.
    let drawnPaper: Paper

    /// Validates `meta`/`page` and builds stroke geometry.
    ///
    /// - Throws: `RenderError.invalidPageSize`; `.invalidGeometry` for a stroke
    ///   with non-finite coordinates, size, opacity, force, width or
    ///   transform; `.extentTooLarge` for a transformed coordinate (either
    ///   axis) beyond `RenderLimits.maxExtent` in magnitude. Finite coordinates
    ///   within the limit that fall outside a finite page are not an error; the
    ///   stroke is simply culled.
    init(page: Page, meta: NoteMeta, options: RenderOptions,
         maxOutlinePoints: Int = RenderLimits.maxOutlinePoints) throws {
        let size = meta.pageSize
        let maxE = RenderLimits.maxExtent
        guard size.width.isFinite, size.width > 0, size.width <= maxE,
              size.height.isFinite, size.height >= 0, size.height <= maxE,
              size.infinite || size.height > 0 else { throw RenderError.invalidPageSize }
        self.meta = meta
        self.paper = page.paper ?? meta.paper
        self.options = options

        var list: [PreparedStroke] = []
        var low = 0.0
        var outlinePoints = 0
        for stroke in page.strokes where !stroke.points.isEmpty {
            let xf = stroke.transform ?? .identity
            guard [xf.a, xf.b, xf.c, xf.d, xf.tx, xf.ty, stroke.ink.width].allSatisfy(\.isFinite) else {
                throw RenderError.invalidGeometry
            }
            var radius = stroke.ink.width.magnitude
            var lo = Double.infinity, hi = -Double.infinity
            for p in stroke.points {
                guard [p.x, p.y, p.w, p.h, p.o, p.f].allSatisfy(\.isFinite) else { throw RenderError.invalidGeometry }
                let q = xf.apply(x: p.x, y: p.y)
                guard q.x.isFinite, q.y.isFinite else { throw RenderError.invalidGeometry }
                guard abs(q.x) <= maxE, abs(q.y) <= maxE else {
                    throw RenderError.extentTooLarge(max(abs(q.x), abs(q.y)))
                }
                lo = min(lo, q.y); hi = max(hi, q.y)
                radius = max(radius, p.w.magnitude, p.h.magnitude)
            }
            let pad = min(radius * xf.meanScale, RenderLimits.maxNibWidth) / 2 + 1   // drawn no wider (StrokeOutline)
            guard pad.isFinite, pad <= maxE else { throw RenderError.extentTooLarge(pad) }
            let commands = StrokeOutline.commands(for: stroke, tolerance: options.tolerance)
            outlinePoints += commands.reduce(0) { $0 + $1.pointCount }
            guard outlinePoints <= maxOutlinePoints else { throw RenderError.tooComplex }
            list.append(PreparedStroke(commands: commands, minY: lo - pad, maxY: hi + pad))
            low = max(low, hi + pad)
        }
        strokes = list
        if size.infinite {
            guard low <= maxE else { throw RenderError.extentTooLarge(low) }
            let chunk = Self.chunkHeight(options: options, size: size)
            extent = max(size.height, low.rounded(.up), chunk)
        } else {
            extent = size.height
        }
        // Bands over the per-band cap draw no ruling anyway; the rest must fit the page budget.
        var ruling = 0.0
        for c in Self.chunks(meta: meta, extent: extent, chunkHeight: Self.chunkHeight(options: options, size: size)) {
            let n = PaperRenderer.rulingCount(paper: paper, width: c.width, yOffset: c.yOffset, yEnd: c.yEnd,
                                              sheetHeight: PaperRenderer.sheetHeight(for: size)) ?? 0
            if n <= RenderLimits.maxPaperCommands { ruling += n }
        }
        drawnPaper = ruling <= RenderLimits.maxPaperCommandsPerPage ? paper
            : Paper(kind: .blank, spacing: paper.spacing, background: paper.background, lineColor: paper.lineColor)
    }

    /// The option, else the page's `breakHeight`, else letter aspect from the width.
    static func chunkHeight(options: RenderOptions, size: PageSize) -> Double {
        let base = options.infiniteChunkHeight ?? size.breakHeight ?? size.width * 11 / 8.5
        return min(max(base.isFinite ? base : 792, 72), RenderLimits.maxExtent)
    }

    /// Chunk height for infinite pages: the option (clamped), else letter aspect from the width.
    var chunkHeight: Double { Self.chunkHeight(options: options, size: meta.pageSize) }

    /// Output pages for this note page.
    var chunks: [PageChunk] { Self.chunks(meta: meta, extent: extent, chunkHeight: chunkHeight) }

    static func chunks(meta: NoteMeta, extent: Double, chunkHeight h: Double) -> [PageChunk] {
        let w = meta.pageSize.width
        guard meta.pageSize.infinite else { return [PageChunk(yOffset: 0, yEnd: extent, width: w)] }
        let count = max(Int((extent / h).rounded(.up)), 1)   // extent <= maxExtent, h >= 72
        return (0..<count).map { PageChunk(yOffset: Double($0) * h, yEnd: Double($0 + 1) * h, width: w) }
    }

    /// Paper (if enabled) and strokes for `chunk`, in chunk-local coordinates.
    /// Strokes that miss the chunk are skipped, and within the rest only the
    /// subpaths that can touch the chunk are kept (long open polylines are cut
    /// to the runs that do).
    func layers(for chunk: PageChunk) -> (paper: [DrawCommand], strokes: [DrawCommand]) {
        var paperCommands: [DrawCommand] = []
        if options.paper {
            paperCommands = PaperRenderer.commands(paper: drawnPaper, width: chunk.width, height: chunk.height,
                                                   yOffset: chunk.yOffset, yEnd: chunk.yEnd,
                                                   sheetHeight: PaperRenderer.sheetHeight(for: meta.pageSize))
        }
        var out: [DrawCommand] = []
        for s in strokes where !(s.maxY < chunk.yOffset || s.minY > chunk.yEnd) {
            for c in s.commands {
                if let clipped = Self.clip(c, to: chunk.yOffset, chunk.yEnd) {
                    out.append(clipped.translated(dy: -chunk.yOffset))
                }
            }
        }
        return (paperCommands, out)
    }

    /// Paper for the whole page in one coordinate space (the SVG layout). The
    /// ruling cap applies per chunk-sized band, so tall infinite pages keep
    /// their ruling.
    func fullPagePaper() -> [DrawCommand] {
        guard options.paper else { return [] }
        let w = meta.pageSize.width
        var out = [DrawCommand(.rect(x: 0, y: 0, width: w, height: extent), fill: Paint(paper.background))]
        let h = meta.pageSize.infinite ? chunkHeight : extent
        let count = max(Int((extent / h).rounded(.up)), 1)
        for i in 0..<count {
            let top = Double(i) * h
            let bottom = i == count - 1 ? extent : Double(i + 1) * h
            out += PaperRenderer.commands(paper: drawnPaper, width: w, height: bottom - top, yOffset: top,
                                          yEnd: bottom, originY: 0, includeBackground: false,
                                          sheetHeight: PaperRenderer.sheetHeight(for: meta.pageSize))
        }
        return out
    }

    /// Geometry of every stroke in page coordinates (no chunking).
    func allStrokeCommands() -> [DrawCommand] { strokes.flatMap(\.commands) }

    private static func clip(_ c: DrawCommand, to top: Double, _ bottom: Double) -> DrawCommand? {
        guard case let .path(subs) = c.primitive else { return c }
        let pad = c.stroke != nil ? c.lineWidth / 2 : 0
        var kept: [Subpath] = []
        for sp in subs {
            if sp.closed || c.stroke == nil || sp.points.count < 2 {
                guard let lo = sp.points.map(\.y).min(), let hi = sp.points.map(\.y).max() else { continue }
                if hi + pad >= top && lo - pad <= bottom { kept.append(sp) }
                continue
            }
            // Open polyline: keep maximal runs of segments that overlap the chunk.
            var run: [Point] = []
            for i in 0..<(sp.points.count - 1) {
                let a = sp.points[i], b = sp.points[i + 1]
                if max(a.y, b.y) + pad >= top && min(a.y, b.y) - pad <= bottom {
                    if run.isEmpty { run.append(a) }
                    run.append(b)
                } else if !run.isEmpty {
                    kept.append(Subpath(points: run, closed: false)); run = []
                }
            }
            if !run.isEmpty { kept.append(Subpath(points: run, closed: false)) }
        }
        if kept.isEmpty { return nil }
        var out = c
        out.primitive = .path(kept)
        return out
    }
}
