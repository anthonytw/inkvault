import Foundation
import InkVault

/// Minimal PDF 1.4 writer: vector paths, RGB colour, alpha via `ExtGState`.
///
/// Every note page becomes one PDF page of `pageSize` points; an `infinite`
/// page is split into pages of `infiniteChunkHeight` (default `pageSize.height`)
/// covering the page's full extent. Page content is flipped to PDF's bottom-left
/// origin with a single leading `1 0 0 -1 0 H cm`, so all geometry stays in
/// page coordinates. Strokes crossing a chunk boundary are drawn on both pages.
public enum PDFWriter {
    /// Renders one note.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> Data {
        try render(notes: [note], options: options)
    }

    /// Renders several notes into one document, in order. `/Title` is the
    /// note's title (titles joined by "; " for several notes).
    public static func render(notes: [NoteState], options: RenderOptions = RenderOptions()) throws -> Data {
        struct OutPage { var width: Double; var height: Double; var content: Data; var alphas: [Int] }
        var pages: [OutPage] = []

        for note in notes {
            for page in note.pages {
                for chunk in PageComposer.chunks(page: page, meta: note.meta, options: options) {
                    let layers = PageComposer.layers(page: page, meta: note.meta, chunk: chunk, options: options)
                    var cs = ContentStream(height: chunk.height)
                    cs.begin()
                    for c in layers.paper + layers.strokes { cs.emit(c) }
                    pages.append(OutPage(width: chunk.width, height: chunk.height,
                                         content: Data(cs.text.utf8), alphas: cs.alphas.sorted()))
                }
            }
        }
        if pages.isEmpty {
            let size = notes.first?.meta.pageSize ?? .letter
            pages.append(OutPage(width: size.width, height: size.height, content: Data(), alphas: []))
        }

        // Object numbering: 1 catalog, 2 pages, 3 info, ExtGStates, then page/content pairs.
        let allAlphas = Array(Set(pages.flatMap(\.alphas))).sorted()
        let gsBase = 4
        var gsObj: [Int: Int] = [:]
        for (i, a) in allAlphas.enumerated() { gsObj[a] = gsBase + i }
        let pageBase = gsBase + allAlphas.count

        var objects: [Data] = []   // objects[i] is object i+1's body
        let kids = pages.indices.map { "\(pageBase + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>".utf8))
        let title = notes.map(\.meta.title).filter { !$0.isEmpty }.joined(separator: "; ")
        var info = "<< "
        if !title.isEmpty { info += "/Title \(textString(title)) " }
        info += "/Producer (InkVault) >>"
        objects.append(Data(info.utf8))
        for a in allAlphas {
            let v = fmt(Double(a) / 1000)
            objects.append(Data("<< /Type /ExtGState /ca \(v) /CA \(v) >>".utf8))
        }
        for (i, p) in pages.enumerated() {
            let contentID = pageBase + 2 * i + 1
            var res = "<< "
            if !p.alphas.isEmpty {
                res += "/ExtGState << " + p.alphas.compactMap { a in gsObj[a].map { "/GS\(a) \($0) 0 R" } }
                    .joined(separator: " ") + " >> "
            }
            res += ">>"
            objects.append(Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(fmt(p.width)) \(fmt(p.height))] "
                + "/Resources \(res) /Contents \(contentID) 0 R >>").utf8))
            var stream = p.content
            var dict = ""
            if options.compress {
                stream = try Zlib.compress(p.content)
                dict = " /Filter /FlateDecode"
            }
            var body = Data("<< /Length \(stream.count)\(dict) >>\nstream\n".utf8)
            body.append(stream)
            body.append(Data("\nendstream".utf8))
            objects.append(body)
        }

        var out = Data("%PDF-1.4\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])   // binary-marker comment
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefPos = out.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { xref += String(format: "%010d 00000 n \n", o) }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    /// PDF text string: literal for printable ASCII, else UTF-16BE hex with BOM.
    static func textString(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            var o = "("
            for ch in s {
                if ch == "(" || ch == ")" || ch == "\\" { o.append("\\") }
                o.append(ch)
            }
            return o + ")"
        }
        var hex = "<FEFF"
        for u in s.utf16 { hex += String(format: "%04X", u) }
        return hex + ">"
    }
}

/// Builds one page's content stream text.
struct ContentStream {
    var text = ""
    var alphas = Set<Int>()
    let height: Double

    init(height: Double) { self.height = height }

    mutating func begin() { text += "1 0 0 -1 0 \(fmt(height)) cm\n" }

    private static func rgb(_ p: Paint) -> String {
        "\(fmt(Double(p.r) / 255)) \(fmt(Double(p.g) / 255)) \(fmt(Double(p.b) / 255))"
    }

    mutating func emit(_ c: DrawCommand) {
        guard c.fill != nil || c.stroke != nil else { return }
        text += "q\n"
        // Fill and stroke share one alpha (no caller needs them to differ).
        let alpha = Int((((c.fill ?? c.stroke)?.alpha ?? 1) * 1000).rounded())
        if alpha < 1000 {
            alphas.insert(alpha)
            text += "/GS\(alpha) gs\n"
        }
        if let f = c.fill { text += "\(Self.rgb(f)) rg\n" }
        if let s = c.stroke {
            text += "\(Self.rgb(s)) RG\n\(fmt(c.lineWidth)) w\n1 J 1 j\n"
        }
        let op = c.fill != nil && c.stroke != nil ? "B" : (c.fill != nil ? "f" : "S")
        switch c.primitive {
        case let .rect(x, y, w, h):
            text += "\(fmt(x)) \(fmt(y)) \(fmt(w)) \(fmt(h)) re \(op)\n"
        case let .line(a, b):
            text += "\(fmt(a.x)) \(fmt(a.y)) m \(fmt(b.x)) \(fmt(b.y)) l S\n"
        case let .circle(center, r):
            let k = 0.5522847498 * r
            let x = center.x, y = center.y
            text += "\(fmt(x + r)) \(fmt(y)) m\n"
            text += "\(fmt(x + r)) \(fmt(y + k)) \(fmt(x + k)) \(fmt(y + r)) \(fmt(x)) \(fmt(y + r)) c\n"
            text += "\(fmt(x - k)) \(fmt(y + r)) \(fmt(x - r)) \(fmt(y + k)) \(fmt(x - r)) \(fmt(y)) c\n"
            text += "\(fmt(x - r)) \(fmt(y - k)) \(fmt(x - k)) \(fmt(y - r)) \(fmt(x)) \(fmt(y - r)) c\n"
            text += "\(fmt(x + k)) \(fmt(y - r)) \(fmt(x + r)) \(fmt(y - k)) \(fmt(x + r)) \(fmt(y)) c\nh \(op)\n"
        case let .path(subs):
            for sp in subs where !sp.points.isEmpty {
                for (i, p) in sp.points.enumerated() {
                    text += "\(fmt(p.x)) \(fmt(p.y)) \(i == 0 ? "m" : "l")\n"
                }
                if sp.closed { text += "h\n" }
            }
            text += "\(op)\n"
        }
        text += "Q\n"
    }
}
