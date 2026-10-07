import Foundation
import Sempere
import SemperePDF

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
        var report = RenderReport()
        return try render(notes: [note], options: options, report: &report)
    }

    /// Renders one note and reports placeholders and warnings.
    public static func render(note: NoteState, options: RenderOptions = RenderOptions(),
                              report: inout RenderReport) throws -> Data {
        try render(notes: [note], options: options, report: &report)
    }

    /// Renders several notes into one document, in order. `/Title` is the
    /// note's title (titles joined by "; " for several notes).
    public static func render(notes: [NoteState], options: RenderOptions = RenderOptions()) throws -> Data {
        var report = RenderReport()
        return try render(notes: notes, options: options, report: &report)
    }

    /// Renders several notes into one document.
    ///
    /// PDF page backgrounds (`pdfPage` items) are copied from their PDF as
    /// Form XObjects, so they stay exact (`docs/attachments.md` §10); a page
    /// that cannot be copied is rasterized by `options.pdfRasterizer` when
    /// there is one, else drawn as a placeholder. The file is PDF 1.7 when it
    /// embeds forms (copied objects may use 1.5+ features), else 1.4.
    ///
    /// Images (format.md §8.2.5) become Image XObjects, one per blob however
    /// often it is used: a JPEG is passed through (`DCTDecode`) with its
    /// metadata stripped unless `options.keepImageMetadata`; other images
    /// are decoded and stored as 8-bit Flate RGB or grey with an `/SMask`
    /// for transparency. Each is drawn with one `cm` (orientation, crop,
    /// frame and rotation) inside a clip to its rotated frame.
    ///
    /// - Parameters:
    ///   - blobs: one blob source per note (`nil` entries, or no array, use
    ///     `options.blobs`): references resolve only within their note.
    ///   - report: receives one entry per placeholder.
    public static func render(notes: [NoteState], blobs: [(any BlobSource)?]? = nil,
                              options: RenderOptions = RenderOptions(), report: inout RenderReport) throws -> Data {
        let doc = PDFObjects()
        let catalog = doc.allocate(), pagesNum = doc.allocate(), infoNum = doc.allocate()   // 1, 2, 3
        struct OutPage {
            var width: Double; var height: Double; var content: Int; var alphas: [Int]; var xobjects: [Int]; var fonts: [Int]
        }
        var pages: [OutPage] = []
        var embedsForms = false
        var pageNumber = 0
        // Image XObjects by content hash, shared by every note that shows the image.
        var imageObjects: [String: Result<Int, PlaceholderReason>] = [:]
        // Font subsets, shared by every page (docs/attachments.md §10).
        var fonts = PDFFontSet()

        func addPage(_ chunk: PageChunk, _ cs: ContentStream, xobjects: [Int]) throws {
            let content = doc.allocate()
            var stream = Data(cs.text.utf8)
            var dict = ""
            if options.compress {
                stream = try Zlib.compress(stream)
                dict = " /Filter /FlateDecode"
            }
            doc.set(content, Array("<< /Length \(stream.count)\(dict) >>\nstream\n".utf8) + [UInt8](stream)
                + Array("\nendstream".utf8))
            pages.append(OutPage(width: chunk.width, height: chunk.height, content: content,
                                 alphas: cs.alphas.sorted(), xobjects: xobjects, fonts: cs.usedFonts.sorted()))
        }

        for (n, note) in notes.enumerated() {
            let source: (any BlobSource)? = (blobs.flatMap { n < $0.count ? $0[n] : nil }) ?? options.blobs
            let backgrounds = PDFBackgrounds(blobs: source, rasterizer: options.pdfRasterizer)
            let images = ImageStore(options: options, blobs: source)
            var copiers: [String: PDFFormCopier] = [:]
            for page in note.pages {
                pageNumber += 1
                let prepared = try PreparedPage(page: page, meta: note.meta, options: options, pageNumber: pageNumber)
                for w in prepared.warnings { report.warn(w) }
                var draws: [UUID: ItemDraw] = [:]
                for it in prepared.items {
                    let d: ItemDraw
                    switch it.item.kind {
                    case .image: d = drawImage(it, images: images, objects: &imageObjects, doc: doc, options: options)
                    case .text:
                        switch TextItems.shape(it, shaper: options.shaper, report: &report) {
                        case .success(let (shaped, rotation)): d = .text(shaped, rotation)
                        case .failure(let reason): d = .placeholder(reason)
                        }
                    default: d = draw(it, backgrounds: backgrounds, copiers: &copiers, doc: doc, options: options)
                    }
                    if case .placeholder(let reason) = d {
                        report.placeholders.append(.init(page: pageNumber, item: it.item.id, kind: it.item.kind,
                                                         reason: reason))
                    }
                    if case .form = d { embedsForms = true }
                    draws[it.item.id] = d
                }
                for chunk in prepared.chunks {
                    let layers = prepared.layers(for: chunk)
                    var cs = ContentStream(height: chunk.height)
                    cs.begin()
                    for c in layers.paper { cs.emit(c) }
                    var xobjects: [Int] = []
                    let chunkItems = prepared.items(for: chunk)
                    let under = PreparedPage.underIndex(chunkItems)
                    for (n, it) in chunkItems.enumerated() {
                        if n == under { for c in layers.under { cs.emit(c) } }
                        if it.fillsBackground, options.paper {
                            cs.emit(it.backgroundFill(prepared.drawnPaper).translated(dy: -chunk.yOffset))
                        }
                        switch draws[it.item.id] ?? .placeholder(.unsupportedKind(it.item.kind.rawValue)) {
                        case .form(let num, let m), .image(let num, let m):
                            cs.drawXObject(num, matrix: Affine.translate(0, -chunk.yOffset).after(m),
                                           clip: it.corners.map { Point(x: $0.x, y: $0.y - chunk.yOffset) })
                            xobjects.append(num)
                        case .text(let shaped, let rotation):
                            cs.text(shaped, transform: Affine.translate(0, -chunk.yOffset).after(rotation), fonts: &fonts)
                        case .placeholder:
                            for c in it.placeholder { cs.emit(c.translated(dy: -chunk.yOffset)) }
                        }
                    }
                    if under == chunkItems.count { for c in layers.under { cs.emit(c) } }
                    for c in layers.strokes { cs.emit(c) }
                    try addPage(chunk, cs, xobjects: xobjects)
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
                try addPage(chunk, cs, xobjects: [])
            }
        }

        var gsObj: [Int: Int] = [:]
        for a in Set(pages.flatMap(\.alphas)).sorted() {
            let num = doc.allocate()
            gsObj[a] = num
            let v = fmt(Double(a) / 1000)
            doc.set(num, Array("<< /Type /ExtGState /ca \(v) /CA \(v) >>".utf8))
        }
        // Five objects per font (PDFFontSet.objects), numbered consecutively.
        let fontNumbers = (0..<(5 * fonts.entries.count)).map { _ in doc.allocate() }
        let fontBase = fontNumbers.first ?? 0
        for (i, body) in try fonts.objects(base: fontBase, compress: options.compress).enumerated() {
            doc.set(fontNumbers[i], [UInt8](body))
        }
        var kids: [Int] = []
        for p in pages {
            let num = doc.allocate()
            kids.append(num)
            var res = "<< "
            if !p.alphas.isEmpty {
                res += "/ExtGState << " + p.alphas.compactMap { a in gsObj[a].map { "/GS\(a) \($0) 0 R" } }
                    .joined(separator: " ") + " >> "
            }
            if !p.xobjects.isEmpty {
                res += "/XObject << " + Set(p.xobjects).sorted().map { "/X\($0) \($0) 0 R" }.joined(separator: " ") + " >> "
            }
            if !p.fonts.isEmpty {
                res += "/Font << " + p.fonts.map { "/T\($0) \(fontBase + 5 * $0) 0 R" }.joined(separator: " ") + " >> "
            }
            res += ">>"
            doc.set(num, Array(("<< /Type /Page /Parent \(pagesNum) 0 R /MediaBox [0 0 \(fmt(p.width)) \(fmt(p.height))] "
                + "/Resources \(res) /Contents \(p.content) 0 R >>").utf8))
        }
        doc.set(catalog, Array("<< /Type /Catalog /Pages \(pagesNum) 0 R >>".utf8))
        doc.set(pagesNum, Array(("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] "
            + "/Count \(pages.count) >>").utf8))
        let title = notes.map(\.meta.title).filter { !$0.isEmpty }.joined(separator: "; ")
        var info = "<< "
        if !title.isEmpty { info += "/Title \(textString(title)) " }
        info += "/Producer (Sempere) >>"
        doc.set(infoNum, Array(info.utf8))
        return doc.serialize(version: embedsForms ? "1.7" : "1.4", root: catalog, info: infoNum)
    }

    /// How an item is drawn in this export.
    enum ItemDraw {
        /// A copied page form and the matrix from PDF user space to page coordinates.
        case form(Int, Affine)
        /// An image XObject and the matrix from its unit square to page coordinates.
        case image(Int, Affine)
        /// Laid-out text and its rotation about the frame's centre.
        case text(ShapedText, Affine)
        case placeholder(PlaceholderReason)
    }

    /// An image item as its Image XObject (embedded on first use) and the
    /// matrix from the XObject's unit square to page coordinates.
    static func drawImage(_ it: PreparedItem, images: ImageStore, objects: inout [String: Result<Int, PlaceholderReason>],
                          doc: PDFObjects, options: RenderOptions) -> ItemDraw {
        let placed: PlacedImage
        switch images.place(it) {
        case .failure(let r): return .placeholder(r)
        case .success(let p): placed = p
        }
        let key = placed.ref.sha256
        let num: Int
        switch objects[key] ?? Result(catching: { try doc.addImage(placed, store: images, keepMetadata: options.keepImageMetadata) })
            .mapError(ImageStore.reason) {
        case .failure(let r):
            objects[key] = .failure(r)
            return .placeholder(r)
        case .success(let n):
            objects[key] = .success(n)
            num = n
        }
        // The XObject paints the unit square, y up, row 0 at the top: (s, t) → (s·w, (1 − t)·h).
        let w = Double(placed.image.width), h = Double(placed.image.height)
        return .image(num, placed.transform.after(Affine(a: w, d: -h, ty: h)))
    }

    static func draw(_ it: PreparedItem, backgrounds: PDFBackgrounds, copiers: inout [String: PDFFormCopier],
                     doc: PDFObjects, options: RenderOptions) -> ItemDraw {
        let item = it.item
        guard item.kind == .pdfPage, let ref = item.blob, let index = item.pageIndex else {
            return .placeholder(.unsupportedKind(item.kind.rawValue))
        }
        let reason: PlaceholderReason
        switch backgrounds.file(item) {
        case .success(let file):
            do {
                let info = try file.page(index)
                let copier = copiers[ref.sha256] ?? PDFFormCopier(file: file, allocate: { [doc] in doc.allocate() })
                copiers[ref.sha256] = copier
                let num = try copier.formObject(page: index)
                for o in copier.takeObjects() { doc.set(o.number, o.body) }
                let crop = item.crop ?? Rect(x: 0, y: 0, w: info.effectiveWidth, h: info.effectiveHeight)
                let m = ItemGeometry.placement(crop: crop, frame: item.frame, degrees: item.rotation ?? 0)
                    .after(ItemGeometry.pdfToEffective(visible: info.visibleBox, rotation: info.rotation))
                guard m.isFinite else { return .placeholder(.pdfUnreadable("degenerate placement")) }
                return .form(num, m)
            } catch {
                reason = .pdfUnreadable(PDFBackgrounds.describe(error))
            }
        case .failure(let r):
            reason = r
        }
        // A PDF that cannot be copied may still be drawn by the rasterizer.
        guard case .pdfUnreadable = reason, options.pdfRasterizer != nil,
              let raster = rasterized(it, backgrounds: backgrounds, scale: options.rasterScale,
                                         maxPixels: options.maxBackgroundPixels) else {
            return .placeholder(reason)
        }
        switch raster {
        case .success(let r):
            guard let num = try? doc.addImage(r.image) else { return .placeholder(reason) }
            let unit = Affine(a: r.width, b: 0, c: 0, d: -r.height, tx: 0, ty: r.height)   // unit square, y up
            return .image(num, r.placement.after(unit))
        case .failure:
            return .placeholder(reason)
        }
    }

    /// The effective page as pixels at `scale` pixels per drawn point, with the
    /// placement from effective-page coordinates to page coordinates and the
    /// effective page's size. nil when the page's geometry is unknown.
    static func rasterized(_ it: PreparedItem, backgrounds: PDFBackgrounds, scale: Double,
                           maxPixels: Int) -> Result<RasterBackground, PlaceholderReason>? {
        let item = it.item
        guard let info = backgrounds.page(item) else { return nil }
        let w = info.effectiveWidth, h = info.effectiveHeight
        let crop = item.crop ?? Rect(x: 0, y: 0, w: w, h: h)
        guard let (pw, ph) = PDFBackgrounds.pixelSize(width: w * item.frame.w / crop.w,
                                                      height: h * item.frame.h / crop.h, scale: scale,
                                                      maxPixels: maxPixels) else {
            return nil
        }
        let placement = ItemGeometry.placement(crop: crop, frame: item.frame, degrees: item.rotation ?? 0)
        guard placement.isFinite else { return nil }
        return backgrounds.raster(item, pixelWidth: pw, pixelHeight: ph).map {
            RasterBackground(image: $0, placement: placement, width: w, height: h, crop: crop)
        }
    }

    /// PDF text string: literal for printable ASCII, else UTF-16BE hex with BOM.
    /// An indirect stream object's body: `dict` (without `<< >>`) then the stream.
    static func streamObject(dict: String, _ stream: Data) -> Data {
        var body = Data("<< \(dict) >>\nstream\n".utf8)
        body.append(stream)
        body.append(Data("\nendstream".utf8))
        return body
    }

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
    /// Fonts drawn (`/T<n>`, indices into the document's `PDFFontSet`).
    var usedFonts = Set<Int>()
    let height: Double

    init(height: Double) { self.height = height }

    mutating func begin() { text += "1 0 0 -1 0 \(fmt(height)) cm\n" }

    /// Draws XObject `num` (named `/X<num>`) with `matrix`, clipped to the polygon `clip`.
    mutating func drawXObject(_ num: Int, matrix m: Affine, clip: [Point]) {
        text += "q\n"
        for (i, p) in clip.enumerated() { text += "\(fmt(p.x)) \(fmt(p.y)) \(i == 0 ? "m" : "l")\n" }
        text += "h W n\n"
        text += [m.a, m.b, m.c, m.d, m.tx, m.ty].map(fmt6).joined(separator: " ") + " cm\n/X\(num) Do\nQ\n"
    }

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

/// A PDF file's objects, numbered as they are allocated. A class so that a
/// form copier's allocator and the writer share one counter.
final class PDFObjects {
    private var next = 1
    private var bodies: [Int: [UInt8]] = [:]

    func allocate() -> Int {
        defer { next += 1 }
        return next
    }

    func set(_ num: Int, _ body: [UInt8]) { bodies[num] = body }

    /// An RGB image XObject (Flate), with an `/SMask` when any pixel is not opaque.
    func addImage(_ img: RGBAImage) throws -> Int {
        let count = img.width * img.height
        var rgb = [UInt8](repeating: 0, count: count * 3)
        var alpha = [UInt8](repeating: 0, count: count)
        var opaque = true
        for i in 0..<count {
            rgb[3 * i] = img.pixels[4 * i]; rgb[3 * i + 1] = img.pixels[4 * i + 1]; rgb[3 * i + 2] = img.pixels[4 * i + 2]
            alpha[i] = img.pixels[4 * i + 3]
            if alpha[i] != 255 { opaque = false }
        }
        var smask = ""
        if !opaque {
            let s = allocate()
            let z = try Zlib.compress(Data(alpha))
            set(s, Array(("<< /Type /XObject /Subtype /Image /Width \(img.width) /Height \(img.height) "
                + "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length \(z.count) >>\nstream\n").utf8)
                + [UInt8](z) + Array("\nendstream".utf8))
            smask = " /SMask \(s) 0 R"
        }
        let num = allocate()
        let z = try Zlib.compress(Data(rgb))
        set(num, Array(("<< /Type /XObject /Subtype /Image /Width \(img.width) /Height \(img.height) "
            + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode\(smask) /Length \(z.count) >>\nstream\n").utf8)
            + [UInt8](z) + Array("\nendstream".utf8))
        return num
    }

    /// An image item's Image XObject: a JPEG passed through (`DCTDecode`,
    /// metadata stripped unless `keepMetadata`), anything else decoded and
    /// stored as 8-bit Flate grey or RGB, with an `/SMask` when not opaque.
    func addImage(_ placed: PlacedImage, store: ImageStore, keepMetadata: Bool) throws -> Int {
        let image = placed.image
        let size = "/Width \(image.width) /Height \(image.height) /BitsPerComponent 8"
        if case let .jpeg(info) = image.format {
            let bytes = keepMetadata ? image.data : try JPEG.stripMetadata(image.data)
            var dict = "/Type /XObject /Subtype /Image \(size) /ColorSpace /\(info.components == 1 ? "DeviceGray" : "DeviceRGB")"
            dict += " /Filter /DCTDecode"
            if info.isRGB { dict += " /DecodeParms << /ColorTransform 0 >>" }
            let num = allocate()
            set(num, Array("<< \(dict) /Length \(bytes.count) >>\nstream\n".utf8) + [UInt8](bytes) + Array("\nendstream".utf8))
            return num
        }
        let rgba = try store.decodeFull(placed.ref, image).get()
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
        var smask = ""
        if !rgba.isOpaque {
            let m = try Zlib.compress(Data((0..<n).map { p[4 * $0 + 3] }))
            let s = allocate()
            set(s, Array(("<< /Type /XObject /Subtype /Image /Width \(rgba.width) /Height \(rgba.height) "
                + "/BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode /Length \(m.count) >>\nstream\n").utf8)
                + [UInt8](m) + Array("\nendstream".utf8))
            smask = " /SMask \(s) 0 R"
        }
        let z = try Zlib.compress(Data(colour))
        let num = allocate()
        set(num, Array(("<< /Type /XObject /Subtype /Image /Width \(rgba.width) /Height \(rgba.height) /BitsPerComponent 8 "
            + "/ColorSpace /\(grey ? "DeviceGray" : "DeviceRGB") /Filter /FlateDecode /Length \(z.count)\(smask) >>\nstream\n").utf8)
            + [UInt8](z) + Array("\nendstream".utf8))
        return num
    }

    /// The file: header, every object (`null` for numbers allocated but not
    /// used), a classic xref table and the trailer.
    func serialize(version: String, root: Int, info: Int) -> Data {
        var out = Array("%PDF-\(version)\n".utf8)
        out += [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]   // binary-marker comment
        var offsets: [Int] = []
        for num in 1..<next {
            offsets.append(out.count)
            out += Array("\(num) 0 obj\n".utf8)
            out += bodies[num] ?? Array("null".utf8)
            out += Array("\nendobj\n".utf8)
        }
        let xrefPos = out.count
        var xref = "xref\n0 \(next)\n0000000000 65535 f \n"
        for o in offsets {
            let digits = String(o)   // not printf: "%d" width is ABI-dependent for 64-bit Int
            xref += String(repeating: "0", count: max(10 - digits.count, 0)) + digits + " 00000 n \n"
        }
        xref += "trailer\n<< /Size \(next) /Root \(root) 0 R /Info \(info) 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        out += Array(xref.utf8)
        return Data(out)
    }
}

/// Like `fmt`, with 6 decimals (matrices: 3 decimals of a scale factor are
/// visible on a large page).
func fmt6(_ v: Double) -> String {
    guard v.isFinite else { return "0" }
    var s = String(format: "%.6f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return (s == "-0" || s.isEmpty) ? "0" : s
}
