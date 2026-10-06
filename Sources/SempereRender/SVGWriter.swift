import Foundation
import Sempere

/// Renders note pages to standalone SVG documents (units = points).
///
/// Layout: `<g id="paper">` holds the background `<rect>` and `<line>` /
/// `<circle>` ruling; `<g id="strokes">` holds exactly one `<path>` (filled
/// ribbon, marker) or `<polyline>` (monoline) per non-empty stroke, in order.
/// Infinite pages become a single tall SVG (no chunking).
public enum SVGWriter {
    /// Renders one page. Width and height carry a `pt` unit so viewers show the
    /// page at its real size; the `viewBox` is unitless points.
    ///
    /// - Throws: `RenderError` for invalid page sizes, non-finite stroke data
    ///   or an infinite page beyond `RenderLimits.maxExtent`.
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions()) throws -> String {
        var report = RenderReport()
        return try render(page: page, meta: meta, options: options, report: &report)
    }

    /// Renders one page and reports placeholders. Items are drawn between the
    /// paper and the strokes in `<g id="items">`: a PDF page as a PNG from
    /// `options.pdfRasterizer` (a data URI, clipped to the frame), anything
    /// else as a placeholder.
    public static func render(page: Page, meta: NoteMeta, options: RenderOptions = RenderOptions(),
                              pageNumber: Int = 1, report: inout RenderReport) throws -> String {
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        return try render(page: page, meta: meta, options: options, pageNumber: pageNumber, backgrounds: backgrounds,
                          report: &report)
    }

    static func render(page: Page, meta: NoteMeta, options: RenderOptions, pageNumber: Int,
                       backgrounds: PDFBackgrounds, report: inout RenderReport) throws -> String {
        let prepared = try PreparedPage(page: page, meta: meta, options: options, pageNumber: pageNumber)
        let draws = RasterItems.resolve(prepared.items, backgrounds: backgrounds, scale: options.rasterScale,
                                        report: &report)
        let width = meta.pageSize.width
        let height = prepared.extent
        let paperCommands = prepared.fullPagePaper()
        let strokeCommands = prepared.allStrokeCommands()

        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fmt(width))pt\" height=\"\(fmt(height))pt\" "
        s += "viewBox=\"0 0 \(fmt(width)) \(fmt(height))\">\n"
        if !meta.title.isEmpty { s += "<title>\(escape(meta.title))</title>\n" }
        s += "<g id=\"paper\">\n"
        for c in paperCommands { s += element(c) + "\n" }
        s += "</g>\n"
        if !prepared.items.isEmpty {
            s += "<g id=\"items\">\n"
            for (i, it) in prepared.items.enumerated() {
                if it.fillsBackground, options.paper { s += element(it.backgroundFill(prepared.drawnPaper)) + "\n" }
                switch draws[it.item.id] {
                case .raster(let r)?:
                    let png = try PNGEncoder.encode(width: r.image.width, height: r.image.height, rgba: r.image.pixels)
                    let m = r.placement.after(Affine(a: r.width, d: r.height))   // unit square (y down) → page
                    let clip = it.corners.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                    s += "<clipPath id=\"item\(i)\"><polygon points=\"\(clip)\"/></clipPath>\n"
                    s += "<g clip-path=\"url(#item\(i))\"><image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" "
                    s += "transform=\"matrix(\([m.a, m.b, m.c, m.d, m.tx, m.ty].map(fmt6).joined(separator: " ")))\" "
                    s += "xmlns:xlink=\"http://www.w3.org/1999/xlink\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/></g>\n"
                default:
                    for c in it.placeholder { s += element(c) + "\n" }
                }
            }
            s += "</g>\n"
        }
        s += "<g id=\"strokes\">\n"
        for c in strokeCommands { s += element(c) + "\n" }
        s += "</g>\n</svg>\n"
        return s
    }

    /// One SVG string per page of the note, in order. Throws like `render(page:meta:options:)`.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> [String] {
        var report = RenderReport()
        return try render(note: note, options: options, report: &report)
    }

    /// One SVG string per page of the note, reporting placeholders.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              report: inout RenderReport) throws -> [String] {
        let backgrounds = PDFBackgrounds(blobs: options.blobs, rasterizer: options.pdfRasterizer)
        return try note.pages.enumerated().map { i, page in
            try render(page: page, meta: note.meta, options: options, pageNumber: i + 1, backgrounds: backgrounds,
                       report: &report)
        }
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            default:
                // Drop characters XML 1.0 forbids.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                if ch.value == 0xFFFE || ch.value == 0xFFFF { continue }
                o.unicodeScalars.append(ch)
            }
        }
        return o
    }

    private static func paintAttrs(_ name: String, _ p: Paint) -> String {
        var s = "\(name)=\"\(p.hex)\""
        if p.alpha < 0.9995 { s += " \(name)-opacity=\"\(fmt(p.alpha))\"" }
        return s
    }

    private static func attrs(_ c: DrawCommand) -> String {
        var parts: [String] = []
        if let f = c.fill { parts.append(paintAttrs("fill", f)) } else { parts.append("fill=\"none\"") }
        if let st = c.stroke {
            parts.append(paintAttrs("stroke", st))
            parts.append("stroke-width=\"\(fmt(c.lineWidth))\"")
            parts.append("stroke-linecap=\"round\" stroke-linejoin=\"round\"")
        }
        return parts.joined(separator: " ")
    }

    static func element(_ c: DrawCommand) -> String {
        switch c.primitive {
        case let .rect(x, y, w, h):
            return "<rect x=\"\(fmt(x))\" y=\"\(fmt(y))\" width=\"\(fmt(w))\" height=\"\(fmt(h))\" \(attrs(c))/>"
        case let .line(a, b):
            return "<line x1=\"\(fmt(a.x))\" y1=\"\(fmt(a.y))\" x2=\"\(fmt(b.x))\" y2=\"\(fmt(b.y))\" \(attrs(c))/>"
        case let .circle(center, r):
            return "<circle cx=\"\(fmt(center.x))\" cy=\"\(fmt(center.y))\" r=\"\(fmt(r))\" \(attrs(c))/>"
        case let .path(subs):
            if subs.count == 1, !subs[0].closed, c.fill == nil {
                let pts = subs[0].points.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                return "<polyline points=\"\(pts)\" \(attrs(c))/>"
            }
            var d = ""
            for sp in subs where !sp.points.isEmpty {
                for (i, p) in sp.points.enumerated() {
                    d += (i == 0 ? "M" : "L") + "\(fmt(p.x)) \(fmt(p.y))"
                }
                if sp.closed { d += "Z" }
            }
            return "<path d=\"\(d)\" \(attrs(c))/>"
        }
    }
}
