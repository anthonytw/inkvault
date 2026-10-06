import Foundation
import Sempere

/// Raster export options.
public struct PNGOptions: Sendable {
    /// Default ceiling on pixels per output image (about 160 MB of RGBA).
    public static let defaultMaxPixels = 40_000_000
    /// Pixels per point. `2` (the default) is 144 dpi; `dpi / 72` for other densities.
    public var scale: Double
    /// Most pixels one output image may have; larger pages throw `RenderError.imageTooLarge`.
    public var maxPixels: Int

    /// Creates options; the defaults are 2x and `defaultMaxPixels`.
    public init(scale: Double = 2, maxPixels: Int = defaultMaxPixels) {
        self.scale = scale; self.maxPixels = maxPixels
    }

    /// Options for `dpi` dots per inch (a point is 1/72 inch).
    public init(dpi: Double, maxPixels: Int = defaultMaxPixels) {
        self.init(scale: dpi / 72, maxPixels: maxPixels)
    }
}

/// Renders note pages to PNG images (RGBA8) with the same geometry, paper and
/// opacity as `PDFWriter`: every page becomes one image; an `infinite` page is
/// split into images of `infiniteChunkHeight`, else the page's
/// `pageSize.breakHeight`, else page width x 11 / 8.5, like the PDF pages.
/// With `RenderOptions.paper == false` the background is transparent.
public enum PNGWriter {
    /// One PNG per output page of `note`, in order. A note without pages
    /// yields one blank image, as `PDFWriter` yields one blank page.
    ///
    /// - Throws: `RenderError` for invalid page sizes, non-finite stroke data,
    ///   extents beyond `RenderLimits.maxExtent`, `.invalidScale`, or
    ///   `.imageTooLarge` when an output image would exceed `png.maxPixels`
    ///   (checked before any pixel memory is allocated).
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions()) throws -> [Data] {
        var report = ExportReport()
        return try render(note: note, options: options, png: png, report: &report)
    }

    /// One PNG per output page of `note`, reporting placeholders and warnings.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions(), report: inout ExportReport) throws -> [Data] {
        guard png.scale.isFinite, png.scale > 0 else { throw RenderError.invalidScale }
        let store = ImageStore(options: options)
        var images: [Data] = []
        for (i, page) in note.pages.enumerated() {
            var pageReport = ExportReport()
            images += try render(page: page, meta: note.meta, options: options, png: png, store: store,
                                 report: &pageReport)
            for var issue in pageReport.issues {
                issue.page = i + 1
                report.add(issue)
            }
        }
        if images.isEmpty {
            var ignored = ExportReport()
            images = try render(page: Page(order: "a"), meta: note.meta, options: options, png: png, store: store,
                                report: &ignored)
            images = Array(images.prefix(1))
        }
        return images
    }

    /// One PNG per output page of a single note page (several for an infinite page).
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions(),
                              png: PNGOptions = PNGOptions()) throws -> [Data] {
        var report = ExportReport()
        return try render(page: page, meta: meta, options: options, png: png, store: ImageStore(options: options),
                          report: &report)
    }

    static func render(page: Page, meta: NoteMeta, options: RenderOptions, png: PNGOptions, store: ImageStore,
                       report: inout ExportReport) throws -> [Data] {
        guard png.scale.isFinite, png.scale > 0 else { throw RenderError.invalidScale }
        let prepared = try PreparedPage(page: page, meta: meta, options: options, images: store)
        report = prepared.report
        var glyphs = GlyphRasterizer()
        let chunks = prepared.chunks
        // Validate every image's size before rasterizing any of them.
        let sizes = try chunks.map { try pixelSize(of: $0, png: png) }
        var out: [Data] = []
        for (chunk, size) in zip(chunks, sizes) {
            let layers = prepared.layers(for: chunk)
            var raster = Raster(width: size.width, height: size.height)
            let sx = Double(size.width) / chunk.width, sy = Double(size.height) / chunk.height
            for c in layers.paper { paint(c, into: &raster, sx: sx, sy: sy) }
            for item in prepared.items(for: chunk) {
                for c in item.commands(paper: prepared.fillPaper) {
                    paint(c.translated(dy: -chunk.yOffset), into: &raster, sx: sx, sy: sy)
                }
                if case let .text(shaped, rotation) = item.content {
                    let device = Affine.scale(sx, sy).after(.translation(0, -chunk.yOffset)).after(rotation)
                    for c in shaped.decorationCommands(rotation) {
                        paint(c.translated(dy: -chunk.yOffset), into: &raster, sx: sx, sy: sy)
                    }
                    for line in shaped.lines {
                        for run in line.runs {
                            let (fill, stroke) = glyphs.polygons(run, transform: device)
                            raster.fill(fill, paint: quantized(Paint(run.color)))
                            if !stroke.isEmpty { raster.fill(stroke, paint: quantized(Paint(run.color))) }
                        }
                    }
                    continue
                }
                guard case let .image(ref, image, transform, clip) = item.content else { continue }
                // Stored image pixels → device pixels.
                let device = Affine.scale(sx, sy).after(.translation(0, -chunk.yOffset)).after(transform)
                let det = abs(device.determinant)
                let reduction = det > 0 ? 1 / det.squareRoot() : 1
                switch store.forRaster(ref, image, reduction: reduction) {
                case .success(let working):
                    guard let inverse = device.inverse else { continue }
                    let toWorking = Affine.scale(Double(working.width) / Double(image.width),
                                                 Double(working.height) / Double(image.height))
                    let toDevice = Affine.scale(sx, sy).after(.translation(0, -chunk.yOffset))
                    raster.fill([clip.map(toDevice.apply)],
                                shader: ImageShader(image: working, inverse: toWorking.after(inverse)))
                case .failure(let why):
                    report.add(ExportIssue(kind: .placeholder, item: item.item.id, message: why.message))
                    for c in item.asPlaceholder.commands(paper: nil) {
                        paint(c.translated(dy: -chunk.yOffset), into: &raster, sx: sx, sy: sy)
                    }
                }
            }
            for c in layers.strokes { paint(c, into: &raster, sx: sx, sy: sy) }
            out.append(try PNGEncoder.encode(width: size.width, height: size.height, rgba: raster.pixels))
        }
        return out
    }

    /// Pixel dimensions of a chunk at `png.scale` (rounded, at least 1), or
    /// `.imageTooLarge` when they exceed the cap.
    static func pixelSize(of chunk: PageChunk, png: PNGOptions) throws -> (width: Int, height: Int) {
        let w = max((chunk.width * png.scale).rounded(), 1), h = max((chunk.height * png.scale).rounded(), 1)
        let pixels = w * h   // Doubles: no integer overflow for hostile scales
        guard w.isFinite, h.isFinite, pixels <= Double(max(png.maxPixels, 0)), w <= Double(Int32.max),
              h <= Double(Int32.max) else {
            throw RenderError.imageTooLarge(pixels: pixels.isFinite ? pixels : .greatestFiniteMagnitude,
                                            limit: png.maxPixels)
        }
        return (Int(w), Int(h))
    }

    /// Alpha as the PDF writer applies it (an `ExtGState` in thousandths).
    private static func quantized(_ p: Paint) -> Paint {
        var q = p
        q.alpha = (p.alpha * 1000).rounded() / 1000
        return q
    }

    private static func paint(_ c: DrawCommand, into raster: inout Raster, sx: Double, sy: Double) {
        func device(_ p: Point) -> Point { Point(x: p.x * sx, y: p.y * sy) }
        func positive(_ points: [Point]) -> [Point] {
            Subpath(points: points, closed: true).signedArea < 0 ? points.reversed() : points
        }
        /// The primitive as closed outlines (page coordinates) plus open/closed polylines for stroking.
        var fills: [[Point]] = []
        var lines: [Subpath] = []
        switch c.primitive {
        case let .rect(x, y, w, h):
            let ring = [Point(x: x, y: y), Point(x: x + w, y: y), Point(x: x + w, y: y + h), Point(x: x, y: y + h)]
            fills = [positive(ring)]
            lines = [Subpath(points: ring, closed: true)]
        case let .line(a, b):
            lines = [Subpath(points: [a, b], closed: false)]
        case let .circle(center, r):
            let ring = StrokeOutline.circle(center, radius: r).points
            fills = [ring]
            lines = [Subpath(points: ring, closed: true)]
        case let .path(subs):
            fills = subs.map(\.points)
            lines = subs
        }
        if let f = c.fill {
            raster.fill(fills.map { $0.map(device) }, paint: quantized(f))
        }
        if let s = c.stroke {
            let polys = lines.flatMap { strokePolygons($0, width: c.lineWidth) }
            raster.fill(polys.map { $0.map(device) }, paint: quantized(s))
        }
    }

    /// Round-capped, round-joined stroke of a polyline as same-orientation
    /// polygons whose non-zero union is the stroke (page coordinates).
    static func strokePolygons(_ sp: Subpath, width: Double) -> [[Point]] {
        guard width.isFinite, width > 0, let first = sp.points.first else { return [] }
        let r = width / 2
        var pts = sp.points
        if sp.closed, pts.count > 1 { pts.append(first) }
        if pts.count == 1 || pts.allSatisfy({ $0.distance(to: first) < 1e-9 }) {
            return [StrokeOutline.circle(first, radius: r).points]
        }
        var polys: [[Point]] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let nx = -(b.y - a.y) / len * r, ny = (b.x - a.x) / len * r
            // a-n, b-n, b+n, a+n has positive signed area for every direction,
            // like the cap and join circles: under the non-zero rule a quad of
            // the opposite orientation cancels a circle where only the two
            // overlap and leaves a hole in the stroke.
            polys.append([Point(x: a.x - nx, y: a.y - ny), Point(x: b.x - nx, y: b.y - ny),
                          Point(x: b.x + nx, y: b.y + ny), Point(x: a.x + nx, y: a.y + ny)])
        }
        if !sp.closed {
            polys.append(StrokeOutline.circle(pts[0], radius: r).points)
            polys.append(StrokeOutline.circle(pts[pts.count - 1], radius: r).points)
        }
        let joins = sp.closed ? Array(0..<(pts.count - 1)) : (pts.count > 2 ? Array(1..<(pts.count - 1)) : [])
        for i in joins {
            let p = i == 0 ? pts[pts.count - 2] : pts[i - 1], q = pts[i], n = pts[i + 1]
            let l1 = p.distance(to: q), l2 = q.distance(to: n)
            guard l1 > 1e-9, l2 > 1e-9 else { continue }
            let cosT = ((q.x - p.x) * (n.x - q.x) + (q.y - p.y) * (n.y - q.y)) / (l1 * l2)
            if cosT < 0.97 { polys.append(StrokeOutline.circle(q, radius: r).points) }
        }
        return polys
    }
}
