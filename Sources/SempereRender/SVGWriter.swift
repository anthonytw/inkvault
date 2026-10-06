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
        var report = ExportReport()
        var assets = SVGAssets(prefix: nil)
        return try render(page: page, meta: meta, options: options, store: ImageStore(options: options),
                          assets: &assets, report: &report)
    }

    /// One SVG string per page of the note, in order. Throws like `render(page:meta:options:)`.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> [String] {
        var report = ExportReport()
        return try export(note: note, options: options, report: &report).pages
    }

    /// One SVG per page of the note, plus the image files they link to.
    ///
    /// Images (format.md §8.2.5) are `<image>` elements in a clip to their
    /// rotated frame, placed with one `matrix(...)`. They carry the stored
    /// JPEG or PNG (metadata stripped unless `options.keepImageMetadata`;
    /// HEIC decoded by `options.imageDecoder` becomes PNG) as a `data:` URI,
    /// or, with `assetPrefix`, link to `assetPrefix + name` and return the
    /// files in `assets` (named by a hash of their bytes, so one file per
    /// image however many pages use it).
    public static func export(note: NoteState, options: RenderOptions = RenderOptions(), assetPrefix: String? = nil,
                              report: inout ExportReport) throws -> (pages: [String], assets: [SVGAsset]) {
        let store = ImageStore(options: options)
        var assets = SVGAssets(prefix: assetPrefix)
        var pages: [String] = []
        for (i, page) in note.pages.enumerated() {
            var pageReport = ExportReport()
            pages.append(try render(page: page, meta: note.meta, options: options, store: store, assets: &assets,
                                    report: &pageReport))
            for var issue in pageReport.issues {
                issue.page = i + 1
                report.add(issue)
            }
        }
        return (pages, assets.files)
    }

    static func render(page: Page, meta: NoteMeta, options: RenderOptions, store: ImageStore,
                       assets: inout SVGAssets, report: inout ExportReport) throws -> String {
        let prepared = try PreparedPage(page: page, meta: meta, options: options, images: store)
        report = prepared.report
        let width = meta.pageSize.width
        let height = prepared.extent
        let paperCommands = prepared.fullPagePaper()
        let strokeCommands = prepared.allStrokeCommands()

        var items = ""
        if !prepared.items.isEmpty {
            // Each image once per document, used by every item that shows it.
            var defs = ""
            var ids: [String: String] = [:]
            var body = ""
            var fontSet = SVGFontSet()
            for (n, item) in prepared.items.enumerated() {
                var commands = item.commands(paper: prepared.fillPaper)
                if case let .image(ref, image, m, clip) = item.content {
                    let id: String?
                    if let known = ids[ref.sha256] {
                        id = known
                    } else {
                        switch assets.href(ref, image, store: store, keepMetadata: options.keepImageMetadata) {
                        case .success(let href):
                            let newID = "img-\(ids.count)"
                            ids[ref.sha256] = newID
                            defs += "<image id=\"\(newID)\" width=\"\(image.width)\" height=\"\(image.height)\" "
                            defs += "preserveAspectRatio=\"none\" "
                            if options.keepImageMetadata { defs += "style=\"image-orientation:none\" " }
                            defs += "xlink:href=\"\(href)\"/>\n"
                            id = newID
                        case .failure(let why):
                            report.add(ExportIssue(kind: .placeholder, item: item.item.id, message: why.message))
                            commands += item.asPlaceholder.commands(paper: nil)
                            id = nil
                        }
                    }
                    for c in commands { body += element(c) + "\n" }
                    if let id {
                        let points = clip.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
                        defs += "<clipPath id=\"clip-\(n)\"><polygon points=\"\(points)\"/></clipPath>\n"
                        body += "<g clip-path=\"url(#clip-\(n))\"><use xlink:href=\"#\(id)\" "
                        body += "transform=\"matrix(\(coef(m.a)) \(coef(m.b)) \(coef(m.c)) \(coef(m.d)) \(fmt(m.e)) \(fmt(m.f)))\"/></g>\n"
                    }
                } else if case let .text(shaped, rotation) = item.content {
                    for c in commands { body += element(c) + "\n" }
                    body += fontSet.elements(shaped, transform: rotation)
                } else {
                    for c in commands { body += element(c) + "\n" }
                }
            }
            if !fontSet.subsets.isEmpty { defs += "<style>\n" + (try fontSet.style()) + "</style>\n" }
            if !defs.isEmpty { items += "<defs>\n" + defs + "</defs>\n" }
            items += "<g id=\"items\">\n" + body + "</g>\n"
        }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" "
        if items.contains("xlink:href") { s += "xmlns:xlink=\"http://www.w3.org/1999/xlink\" " }
        s += "width=\"\(fmt(width))pt\" height=\"\(fmt(height))pt\" "
        s += "viewBox=\"0 0 \(fmt(width)) \(fmt(height))\">\n"
        if !meta.title.isEmpty { s += "<title>\(escape(meta.title))</title>\n" }
        s += "<g id=\"paper\">\n"
        for c in paperCommands { s += element(c) + "\n" }
        s += "</g>\n" + items
        s += "<g id=\"strokes\">\n"
        for c in strokeCommands { s += element(c) + "\n" }
        s += "</g>\n</svg>\n"
        return s
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

/// An image file an SVG export links to (`SVGWriter.export(assetPrefix:)`).
public struct SVGAsset: Hashable, Sendable {
    /// File name: 16 hex digits of the bytes' SHA-256 plus `.jpg` or `.png`.
    public var name: String
    public var data: Data
}

/// The images of one SVG export: data URIs, or files with relative links.
struct SVGAssets {
    let prefix: String?
    private(set) var files: [SVGAsset] = []
    private var hrefs: [String: Result<String, PlaceholderReason>] = [:]

    init(prefix: String?) { self.prefix = prefix }

    /// The `href` of an image blob: its bytes as passed through (JPEG and
    /// PNG, metadata stripped unless kept) or re-encoded as PNG (decoded
    /// formats), inline or as a file.
    mutating func href(_ ref: BlobRef, _ image: LoadedImage, store: ImageStore,
                       keepMetadata: Bool) -> Result<String, PlaceholderReason> {
        if let r = hrefs[ref.sha256] { return r }
        let r = Result { () -> String in
            let (bytes, type, ext): (Data, String, String)
            switch image.format {
            case .jpeg: (bytes, type, ext) = (keepMetadata ? image.data : try JPEG.stripMetadata(image.data), "image/jpeg", "jpg")
            case .png: (bytes, type, ext) = (keepMetadata ? image.data : try PNG.stripMetadata(image.data), "image/png", "png")
            case .other:
                let rgba = try store.decodeFull(ref, image).get()
                (bytes, type, ext) = (try PNGEncoder.encode(width: rgba.width, height: rgba.height, rgba: rgba.pixels),
                                      "image/png", "png")
            }
            guard let prefix else { return "data:\(type);base64," + bytes.base64EncodedString() }
            let name = String(BlobRef(content: bytes, type: type).sha256.prefix(16)) + "." + ext
            if !files.contains(where: { $0.name == name }) { files.append(SVGAsset(name: name, data: bytes)) }
            return SVGWriter.escape(prefix + name)
        }.mapError { $0 as? PlaceholderReason ?? PlaceholderReason(message: ImageStore.describe($0)) }
        hrefs[ref.sha256] = r
        return r
    }
}
