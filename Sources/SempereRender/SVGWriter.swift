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
        let prepared = try PreparedPage(page: page, meta: meta, options: options)
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
        s += "</g>\n<g id=\"strokes\">\n"
        for c in strokeCommands { s += element(c) + "\n" }
        s += "</g>\n</svg>\n"
        return s
    }

    /// One SVG string per page of the note, in order. Throws like `render(page:meta:options:)`.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> [String] {
        try note.pages.map { try render(page: $0, meta: note.meta, options: options) }
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
