import Foundation
import Sempere

/// Minimal PDF 1.4 writer: vector paths, RGB colour, alpha via `ExtGState`.
///
/// Every note page becomes one PDF page of `pageSize` points; an `infinite`
/// page is split into pages of `infiniteChunkHeight`, else the page's
/// `pageSize.breakHeight`, else page width x 11 / 8.5 (letter aspect),
/// independent of the page's current extent,
/// covering the page's full extent. Page content is flipped to PDF's bottom-left
/// origin with a single leading `1 0 0 -1 0 H cm`, so all geometry stays in
/// page coordinates. Strokes crossing a chunk boundary are drawn on both pages.
public enum PDFWriter {
    /// Renders one note.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions()) throws -> Data {
        var report = ExportReport()
        return try render(notes: [note], options: options, report: &report)
    }

    /// Renders one note and reports what it drew as placeholders (format.md §8.5.2).
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              report: inout ExportReport) throws -> Data {
        try render(notes: [note], options: options, report: &report)
    }

    /// Renders several notes into one document, in order. `/Title` is the
    /// note's title (titles joined by "; " for several notes).
    public static func render(notes: [NoteState], options: RenderOptions = RenderOptions()) throws -> Data {
        var report = ExportReport()
        return try render(notes: notes, options: options, report: &report)
    }

    /// Renders several notes into one document and reports placeholders and
    /// warnings (with `note` set to the note's index when there are several).
    ///
    /// Images (format.md §8.2.5) become Image XObjects, one per blob however
    /// often it is used: a JPEG is passed through (`DCTDecode`) with its
    /// metadata stripped unless `options.keepImageMetadata`; other images
    /// are decoded and stored as 8-bit Flate RGB or grey with an `/SMask`
    /// for transparency. Each is drawn with one `cm` (orientation, crop,
    /// frame and rotation) inside a clip to its rotated frame.
    public static func render(notes: [NoteState], options: RenderOptions = RenderOptions(),
                              report: inout ExportReport) throws -> Data {
        struct OutPage { var width: Double; var height: Double; var content: Data; var alphas: [Int]; var images: [Int] }
        var pages: [OutPage] = []
        let store = ImageStore(options: options)
        var xobjects = ImageXObjects()

        for (n, note) in notes.enumerated() {
            for (pi, page) in note.pages.enumerated() {
                let prepared = try PreparedPage(page: page, meta: note.meta, options: options, images: store)
                var pageReport = prepared.report
                for chunk in prepared.chunks {
                    let layers = prepared.layers(for: chunk)
                    var cs = ContentStream(height: chunk.height)
                    cs.begin()
                    for c in layers.paper { cs.emit(c) }
                    for item in prepared.items(for: chunk) {
                        let shift = Affine.translation(0, -chunk.yOffset)
                        for c in item.commands(paper: prepared.fillPaper) { cs.emit(c.translated(dy: -chunk.yOffset)) }
                        guard case let .image(ref, image, transform, clip) = item.content else { continue }
                        switch xobjects.add(ref, image, store: store, keepMetadata: options.keepImageMetadata) {
                        case .success(let index):
                            cs.image(index: index, width: image.width, height: image.height,
                                     transform: shift.after(transform), clip: clip.map(shift.apply))
                        case .failure(let why):
                            // Found only now (a PNG that does not decode): a placeholder after all.
                            pageReport.add(ExportIssue(kind: .placeholder, item: item.item.id, message: why.message))
                            for c in item.asPlaceholder.commands(paper: nil) { cs.emit(c.translated(dy: -chunk.yOffset)) }
                        }
                    }
                    for c in layers.strokes { cs.emit(c) }
                    pages.append(OutPage(width: chunk.width, height: chunk.height, content: Data(cs.text.utf8),
                                         alphas: cs.alphas.sorted(), images: cs.images.sorted()))
                }
                for var issue in pageReport.issues {
                    issue.page = pi + 1
                    if notes.count > 1 { issue.note = n }
                    report.add(issue)
                }
            }
        }
        if pages.isEmpty {
            // A document needs a page: render an empty one through the same
            // validation and chunking as real pages.
            let meta = notes.first?.meta ?? NoteMeta(created: Date(timeIntervalSince1970: 0))
            let prepared = try PreparedPage(page: Page(order: "a"), meta: meta, options: options)
            for chunk in prepared.chunks.prefix(1) {
                var cs = ContentStream(height: chunk.height)
                cs.begin()
                for c in prepared.layers(for: chunk).paper { cs.emit(c) }
                pages.append(OutPage(width: chunk.width, height: chunk.height,
                                     content: Data(cs.text.utf8), alphas: cs.alphas.sorted(), images: []))
            }
        }

        // Object numbering: 1 catalog, 2 pages, 3 info, ExtGStates, page/content pairs, then images.
        let allAlphas = Array(Set(pages.flatMap(\.alphas))).sorted()
        let gsBase = 4
        var gsObj: [Int: Int] = [:]
        for (i, a) in allAlphas.enumerated() { gsObj[a] = gsBase + i }
        let pageBase = gsBase + allAlphas.count
        let imageBase = pageBase + 2 * pages.count
        let imageObj = xobjects.objectNumbers(base: imageBase)

        var objects: [Data] = []   // objects[i] is object i+1's body
        let kids = pages.indices.map { "\(pageBase + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>".utf8))
        let title = notes.map(\.meta.title).filter { !$0.isEmpty }.joined(separator: "; ")
        var info = "<< "
        if !title.isEmpty { info += "/Title \(textString(title)) " }
        info += "/Producer (Sempere) >>"
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
            if !p.images.isEmpty {
                res += "/XObject << " + p.images.map { "/Im\($0) \(imageObj[$0]) 0 R" }.joined(separator: " ") + " >> "
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
            objects.append(streamObject(dict: "/Length \(stream.count)\(dict)", stream))
        }
        objects += xobjects.objects(base: imageBase)

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
        for o in offsets {
            let digits = String(o)   // not printf: "%d" width is ABI-dependent for 64-bit Int
            xref += String(repeating: "0", count: max(10 - digits.count, 0)) + digits + " 00000 n \n"
        }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    /// `<< dict >>` followed by the stream.
    static func streamObject(dict: String, _ stream: Data) -> Data {
        var body = Data("<< \(dict) >>\nstream\n".utf8)
        body.append(stream)
        body.append(Data("\nendstream".utf8))
        return body
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
    /// Image XObjects drawn (`/Im<n>`).
    var images = Set<Int>()
    let height: Double

    init(height: Double) { self.height = height }

    mutating func begin() { text += "1 0 0 -1 0 \(fmt(height)) cm\n" }

    private static func rgb(_ p: Paint) -> String {
        "\(fmt(Double(p.r) / 255)) \(fmt(Double(p.g) / 255)) \(fmt(Double(p.b) / 255))"
    }

    /// Draws image XObject `index` (`width × height` stored pixels) with
    /// `transform` (stored pixel coordinates → page) inside `clip`.
    mutating func image(index: Int, width: Int, height: Int, transform m: Affine, clip: [Point]) {
        images.insert(index)
        let w = Double(width), h = Double(height)
        // The XObject paints the unit square, y up, row 0 at the top: (s, t) → (s·w, (1 − t)·h).
        let u = Affine(a: w, b: 0, c: 0, d: -h, e: 0, f: h)
        let x = m.after(u)
        text += "q\n"
        for (i, p) in clip.enumerated() { text += "\(fmt(p.x)) \(fmt(p.y)) \(i == 0 ? "m" : "l")\n" }
        text += "h W n\n"
        text += "\(coef(x.a)) \(coef(x.b)) \(coef(x.c)) \(coef(x.d)) \(fmt(x.e)) \(fmt(x.f)) cm\n/Im\(index) Do\nQ\n"
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
            text += "\(fmt(a.x)) \(fmt(a.y)) m \(fmt(b.x)) \(fmt(b.y)) l \(op)\n"
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

/// The image XObjects of one PDF, one per blob (format.md §8.2.5).
struct ImageXObjects {
    struct Entry {
        var dict: String
        var stream: Data
        /// Alpha as an 8-bit grey image of the same size, Flate-compressed.
        var smask: Data?
        var width: Int
        var height: Int
    }
    private(set) var entries: [Entry] = []
    private var index: [String: Result<Int, PlaceholderReason>] = [:]

    /// The XObject index for an image blob, embedding it on first use.
    mutating func add(_ ref: BlobRef, _ image: LoadedImage, store: ImageStore,
                      keepMetadata: Bool) -> Result<Int, PlaceholderReason> {
        if let r = index[ref.sha256] { return r }
        let r = Result { () -> Int in
            entries.append(try Self.entry(ref, image, store: store, keepMetadata: keepMetadata))
            return entries.count - 1
        }.mapError { $0 as? PlaceholderReason ?? PlaceholderReason(message: ImageStore.describe($0)) }
        index[ref.sha256] = r
        return r
    }

    static func entry(_ ref: BlobRef, _ image: LoadedImage, store: ImageStore, keepMetadata: Bool) throws -> Entry {
        let size = "/Width \(image.width) /Height \(image.height) /BitsPerComponent 8"
        if case let .jpeg(info) = image.format {
            let bytes = keepMetadata ? image.data : try JPEG.stripMetadata(image.data)
            var dict = "/Type /XObject /Subtype /Image \(size) /ColorSpace /\(info.components == 1 ? "DeviceGray" : "DeviceRGB")"
            dict += " /Filter /DCTDecode"
            if info.isRGB { dict += " /DecodeParms << /ColorTransform 0 >>" }
            return Entry(dict: dict, stream: bytes, smask: nil, width: image.width, height: image.height)
        }
        let rgba = try store.decodeFull(ref, image).get()
        let n = rgba.width * rgba.height
        let p = rgba.pixels
        var grey = true
        var i = 0
        while i < p.count {
            if p[i] != p[i + 1] || p[i] != p[i + 2] { grey = false; break }
            i += 4
        }
        var colour = [UInt8]()
        colour.reserveCapacity(n * (grey ? 1 : 3))
        for k in 0..<n {
            colour.append(p[4 * k])
            if !grey { colour.append(p[4 * k + 1]); colour.append(p[4 * k + 2]) }
        }
        let dict = "/Type /XObject /Subtype /Image /Width \(rgba.width) /Height \(rgba.height) /BitsPerComponent 8 "
            + "/ColorSpace /\(grey ? "DeviceGray" : "DeviceRGB") /Filter /FlateDecode"
        var smask: Data?
        if !rgba.isOpaque {
            smask = try Zlib.compress(Data((0..<n).map { p[4 * $0 + 3] }))
        }
        return Entry(dict: dict, stream: try Zlib.compress(Data(colour)), smask: smask, width: rgba.width,
                     height: rgba.height)
    }

    /// Object number of each entry when the first is `base` (an entry with a
    /// soft mask takes two numbers: image, then mask).
    func objectNumbers(base: Int) -> [Int] {
        var out: [Int] = []
        var next = base
        for e in entries {
            out.append(next)
            next += e.smask == nil ? 1 : 2
        }
        return out
    }

    /// The objects' bodies, in object-number order.
    func objects(base: Int) -> [Data] {
        var out: [Data] = []
        let numbers = objectNumbers(base: base)
        for (i, e) in entries.enumerated() {
            var dict = e.dict + " /Length \(e.stream.count)"
            if e.smask != nil { dict += " /SMask \(numbers[i] + 1) 0 R" }
            out.append(PDFWriter.streamObject(dict: dict, e.stream))
            if let m = e.smask {
                out.append(PDFWriter.streamObject(dict: "/Type /XObject /Subtype /Image /Width \(e.width) "
                    + "/Height \(e.height) /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode "
                    + "/Length \(m.count)", m))
            }
        }
        return out
    }
}
