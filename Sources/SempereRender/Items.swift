import Foundation
import Sempere

// MARK: - Affine maps

/// A 2-D affine map in PDF's convention: `x' = a·x + c·y + e`,
/// `y' = b·x + d·y + f`.
struct Affine: Hashable, Sendable {
    var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    static let identity = Affine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    func apply(_ p: Point) -> Point { Point(x: a * p.x + c * p.y + e, y: b * p.x + d * p.y + f) }

    /// `self` after `first`: `self.then(...)` reads right to left like matrix products.
    func after(_ first: Affine) -> Affine {
        Affine(a: a * first.a + c * first.b, b: b * first.a + d * first.b,
               c: a * first.c + c * first.d, d: b * first.c + d * first.d,
               e: a * first.e + c * first.f + e, f: b * first.e + d * first.f + f)
    }

    var determinant: Double { a * d - b * c }

    /// The inverse, or nil when the map is singular or not finite.
    var inverse: Affine? {
        let det = determinant
        guard det.isFinite, abs(det) > 1e-300 else { return nil }
        let inv = Affine(a: d / det, b: -b / det, c: -c / det, d: a / det,
                         e: (c * f - d * e) / det, f: (b * e - a * f) / det)
        return [inv.a, inv.b, inv.c, inv.d, inv.e, inv.f].allSatisfy(\.isFinite) ? inv : nil
    }

    static func translation(_ x: Double, _ y: Double) -> Affine { Affine(a: 1, b: 0, c: 0, d: 1, e: x, f: y) }
    static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, b: 0, c: 0, d: y, e: 0, f: 0) }
}

// MARK: - Placement (format.md §8.5.1)

/// Where a source rectangle lands on a page: the crop mapped onto the frame,
/// rotated clockwise about the frame's centre (format.md §8.5.1).
enum Placement {
    /// Stored pixel coordinates `(a, b)` of a `w × h` image → oriented
    /// coordinates `(u, v)` for EXIF `orientation` 1–8 (the table of §8.5.1).
    static func orientation(_ o: Int, width w: Double, height h: Double) -> Affine {
        switch o {
        case 2: return Affine(a: -1, b: 0, c: 0, d: 1, e: w, f: 0)
        case 3: return Affine(a: -1, b: 0, c: 0, d: -1, e: w, f: h)
        case 4: return Affine(a: 1, b: 0, c: 0, d: -1, e: 0, f: h)
        case 5: return Affine(a: 0, b: 1, c: 1, d: 0, e: 0, f: 0)
        case 6: return Affine(a: 0, b: 1, c: -1, d: 0, e: h, f: 0)
        case 7: return Affine(a: 0, b: -1, c: -1, d: 0, e: h, f: w)
        case 8: return Affine(a: 0, b: -1, c: 1, d: 0, e: 0, f: w)
        default: return .identity
        }
    }

    /// The oriented size of a stored `w × h` image.
    static func orientedSize(_ o: Int, width w: Double, height h: Double) -> (w: Double, h: Double) {
        (5...8).contains(o) ? (h, w) : (w, h)
    }

    /// Source rectangle `crop` → `frame`, then the rotation about the frame's centre.
    static func cropToPage(crop: Rect, frame: Rect, rotation: Double) -> Affine {
        let toFrame = Affine(a: frame.w / crop.w, b: 0, c: 0, d: frame.h / crop.h,
                             e: frame.x - crop.x * frame.w / crop.w, f: frame.y - crop.y * frame.h / crop.h)
        return self.rotation(rotation, about: frame).after(toFrame)
    }

    /// Clockwise rotation (y down) by `degrees` about the centre of `frame`.
    static func rotation(_ degrees: Double, about frame: Rect) -> Affine {
        guard degrees != 0 else { return .identity }
        let t = degrees * .pi / 180
        // Exact quarter turns keep axis-aligned images free of rounding noise.
        let q = degrees.truncatingRemainder(dividingBy: 90) == 0
        let cs = q ? cos(t).rounded() : cos(t), sn = q ? sin(t).rounded() : sin(t)
        let mx = frame.x + frame.w / 2, my = frame.y + frame.h / 2
        return Affine(a: cs, b: sn, c: -sn, d: cs, e: mx - mx * cs + my * sn, f: my - mx * sn - my * cs)
    }

    /// The frame's corners after rotation, clockwise from top-left: the clip
    /// and the placeholder outline.
    static func corners(frame: Rect, rotation: Double) -> [Point] {
        let r = self.rotation(rotation, about: frame)
        return [Point(x: frame.x, y: frame.y), Point(x: frame.x + frame.w, y: frame.y),
                Point(x: frame.x + frame.w, y: frame.y + frame.h), Point(x: frame.x, y: frame.y + frame.h)]
            .map(r.apply)
    }
}

// MARK: - Report

/// Something an export could not draw as stored: a placeholder, or a
/// warning about what was drawn. Every exporter returns these and the CLI
/// prints them (docs/attachments.md §10; format.md §8.5.2).
public struct ExportIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case placeholder, warning }
    public var kind: Kind
    /// 0-based index of the note in a multi-note export; nil otherwise.
    public var note: Int?
    /// 1-based note page; nil for the note as a whole.
    public var page: Int?
    /// The item concerned.
    public var item: UUID?
    /// What happened, for people.
    public var message: String

    public init(kind: Kind, note: Int? = nil, page: Int? = nil, item: UUID? = nil, message: String) {
        self.kind = kind; self.note = note; self.page = page; self.item = item; self.message = message
    }

    public var description: String {
        var s = page.map { "page \($0): " } ?? ""
        if let item { s += "item \(item.uuidString.lowercased().prefix(8)): " }
        return s + message
    }
}

/// The issues of one export.
public struct ExportReport: Sendable, Equatable {
    public var issues: [ExportIssue] = []
    public init(issues: [ExportIssue] = []) { self.issues = issues }
    public var placeholders: Int { issues.filter { $0.kind == .placeholder }.count }
    public var isEmpty: Bool { issues.isEmpty }
    mutating func add(_ issue: ExportIssue) { if !issues.contains(issue) { issues.append(issue) } }
}

// MARK: - Image sources

/// The blob source of each note, by note id: a reference resolves only in
/// its own note (format.md §8.1.1), so multi-note exports take one per note.
public typealias BlobSources = @Sendable (UUID) -> (any BlobSource)?

/// Decodes image formats SempereRender cannot (HEIC): the app implements it
/// with ImageIO. Return nil for a type it does not handle either.
public protocol ImageDecoding: Sendable {
    func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage?
}

/// An image blob's bytes and what its header says, read once per export.
struct LoadedImage {
    enum Format { case jpeg(JPEG.Info), png(PNG.Info), other }
    let data: Data
    let format: Format
    let type: String
    /// Stored (unoriented) pixel size.
    let width: Int
    let height: Int
}

/// What a blob-backed item could not be drawn for.
struct PlaceholderReason: Error {
    let message: String
}

/// Per-export cache of image blobs: each blob is read, checked and decoded
/// once however many items and pages use it.
final class ImageStore {
    let blobs: (any BlobSource)?
    let decoder: (any ImageDecoding)?
    let maxPixels: Int
    private var loaded: [String: Result<LoadedImage, PlaceholderReason>] = [:]
    private var decoded: [String: Result<RGBAImage, PlaceholderReason>] = [:]

    init(options: RenderOptions) {
        blobs = options.blobs
        decoder = options.imageDecoder
        maxPixels = options.maxImagePixels
    }

    /// The blob of an image item with its header parsed, or why not.
    func load(_ ref: BlobRef) -> Result<LoadedImage, PlaceholderReason> {
        if let r = loaded[ref.sha256] { return r }
        let r = Result { try read(ref) }.mapError { $0 as? PlaceholderReason ?? PlaceholderReason(message: Self.describe($0)) }
        loaded[ref.sha256] = r
        return r
    }

    private func read(_ ref: BlobRef) throws -> LoadedImage {
        guard let blobs else { throw PlaceholderReason(message: "image not available (no attachments given)") }
        guard ref.size <= Int64(ImageLimits.maxBlobBytes) else {
            throw PlaceholderReason(message: "image of \(ref.size) bytes is over the \(ImageLimits.maxBlobBytes >> 20) MiB export limit")
        }
        // At most 16 MiB is held whole by the blob store; larger blobs come through a temporary file.
        let memory = Vault.maxInMemoryBlobBytes
        let data = ref.size <= Int64(memory) ? try blobs.data(for: ref, maxBytes: memory)
            : try blobs.withFile(for: ref) { try BoundedRead.contents(of: $0, maxBytes: ImageLimits.maxBlobBytes) }
        let d = [UInt8](data.prefix(16))
        if d.starts(with: [0xFF, 0xD8]) {
            let info = try JPEG.info(data)
            return try checked(LoadedImage(data: data, format: .jpeg(info), type: "image/jpeg",
                                           width: info.width, height: info.height))
        }
        if d.starts(with: PNG.signature) {
            let info = try PNG.info(data)
            return try checked(LoadedImage(data: data, format: .png(info), type: "image/png",
                                           width: info.width, height: info.height))
        }
        if d.count >= 12, Array(d[4..<8]) == Array("ftyp".utf8) || ref.type.lowercased().hasPrefix("image/hei") {
            guard decoder != nil else {
                throw PlaceholderReason(message: "HEIC images cannot be decoded here (convert it to JPEG in the app)")
            }
            return LoadedImage(data: data, format: .other, type: "image/heic", width: 0, height: 0)
        }
        guard decoder != nil else { throw PlaceholderReason(message: "unsupported image type \(ref.type)") }
        return LoadedImage(data: data, format: .other, type: ref.type, width: 0, height: 0)
    }

    private func checked(_ image: LoadedImage) throws -> LoadedImage {
        let pixels = Double(image.width) * Double(image.height)
        guard pixels <= Double(maxPixels) else {
            throw PlaceholderReason(message: "image of \(image.width) × \(image.height) pixels is over the "
                                    + "\(maxPixels / 1_000_000) MP limit")
        }
        return image
    }

    /// The image decoded at full size (PDF and SVG need every pixel). Only
    /// the most recent decode is kept (a page usually shows an image on
    /// consecutive chunks), so memory holds one bitmap, not one per image;
    /// failures are remembered for every image.
    func decodeFull(_ ref: BlobRef, _ image: LoadedImage) -> Result<RGBAImage, PlaceholderReason> {
        if let r = decoded[ref.sha256] { return r }
        let r = Result { try decode(image, scale: 1) }.mapError { PlaceholderReason(message: Self.describe($0)) }
        decoded = decoded.filter { if case .failure = $0.value { return true } else { return false } }
        decoded[ref.sha256] = r
        return r
    }

    private var reduced: [String: Result<RGBAImage, PlaceholderReason>] = [:]

    /// The image for drawing at `reduction` source pixels per output pixel:
    /// a JPEG decoded with DCT scaling (1/2, 1/4, 1/8) where that keeps at
    /// least one decoded pixel per output pixel, then reduced by an integer
    /// box average while two or more remain (docs/attachments.md §10, §10
    /// "Raster limits"). Cached per size.
    func forRaster(_ ref: BlobRef, _ image: LoadedImage, reduction: Double) -> Result<RGBAImage, PlaceholderReason> {
        var dct = 1
        if case .jpeg = image.format, reduction.isFinite {
            for s in [2, 4, 8] where Double(s) <= reduction { dct = s }
        }
        let rest = reduction.isFinite ? reduction / Double(dct) : 1
        let box = rest >= 2 ? Int(min(rest, 65_536)) : 1
        let key = "\(ref.sha256)-\(dct)-\(box)"
        if let r = reduced[key] { return r }
        let r = Result { () -> RGBAImage in
            let base = dct == 1 ? try decodeFull(ref, image).get() : try decode(image, scale: dct)
            return base.boxReduced(by: box)
        }.mapError { $0 as? PlaceholderReason ?? PlaceholderReason(message: Self.describe($0)) }
        reduced = reduced.filter { if case .failure = $0.value { return true } else { return false } }   // one bitmap at a time
        reduced[key] = r
        return r
    }

    /// The image decoded at `1/scale` (JPEG DCT scaling; other formats ignore it).
    func decode(_ image: LoadedImage, scale: Int) throws -> RGBAImage {
        switch image.format {
        case .jpeg: return try JPEG.decode(image.data, scale: scale, maxPixels: maxPixels)
        case .png: return try PNG.decode(image.data, maxPixels: maxPixels)
        case .other:
            guard let decoder, let img = try decoder.decode(image.data, type: image.type, maxPixels: maxPixels) else {
                throw PlaceholderReason(message: "image type \(image.type) cannot be decoded here")
            }
            guard Double(img.width) * Double(img.height) <= Double(maxPixels) else {
                throw ImageError.tooLarge(width: img.width, height: img.height)
            }
            return img
        }
    }

    static func describe(_ error: any Error) -> String {
        if let p = error as? PlaceholderReason { return p.message }
        if let e = error as? ImageError { return e.errorDescription ?? "\(e)" }
        if let e = error as? BlobError { return "\(e)" }
        return "image cannot be read (\(error))"
    }
}

// MARK: - Prepared items

/// An item ready to draw: validated, placed, with its bounds on the page.
struct PreparedItem {
    enum Content {
        /// An image: `transform` maps stored pixel coordinates to the page,
        /// `clip` is the rotated frame.
        case image(ref: BlobRef, image: LoadedImage, transform: Affine, clip: [Point])
        /// Laid-out text (page coordinates before `rotation`, applied about the frame's centre).
        case text(ShapedText, rotation: Affine)
        /// A placeholder (format.md §8.5.2): outline and diagonals.
        case placeholder
        /// Nothing to draw (text until text export exists).
        case none
    }

    let item: Item
    let content: Content
    /// The rotated frame, clockwise from its top-left corner.
    let corners: [Point]
    let minY: Double
    let maxY: Double

    /// The same item drawn as a placeholder (an image that fails to decode
    /// only when a writer needs its pixels).
    var asPlaceholder: PreparedItem {
        PreparedItem(item: item, content: .placeholder, corners: corners, minY: minY, maxY: maxY)
    }

    /// The background fill a layer below 100 gets (format.md §8.2.3), plus
    /// the placeholder geometry when the item is one. Page coordinates.
    func commands(paper: Paper?) -> [DrawCommand] {
        var out: [DrawCommand] = []
        if item.layer.isBackground, let paper {
            out.append(DrawCommand(.path([Subpath(points: corners, closed: true)]), fill: Paint(paper.background)))
        }
        if case .placeholder = content {
            let grey = Paint(r: 0x9A, g: 0xA0, b: 0xA6)
            out.append(DrawCommand(.path([Subpath(points: corners, closed: true)]), stroke: grey, lineWidth: 1))
            out.append(DrawCommand(.line(from: corners[0], to: corners[2]), stroke: grey, lineWidth: 1))
            out.append(DrawCommand(.line(from: corners[1], to: corners[3]), stroke: grey, lineWidth: 1))
        }
        return out
    }

    /// Prepares the page's items in drawing order (format.md §8.2.3),
    /// recording an issue for each one drawn as a placeholder or not drawn.
    static func prepare(_ items: [Item], images: ImageStore?, shaper: (any TextShaper)? = nil,
                        report: inout ExportReport) -> [PreparedItem] {
        let maxE = RenderLimits.maxExtent
        var out: [PreparedItem] = []
        for item in items.prefix(RenderLimits.maxItemsPerPage).sorted(by: Item.drawsBefore) {
            let f = item.frame
            let rotation = item.rotation ?? 0
            guard [f.x, f.y, f.w, f.h, rotation].allSatisfy(\.isFinite), f.w > 0, f.h > 0,
                  abs(f.x) <= maxE, abs(f.y) <= maxE, f.w <= maxE, f.h <= maxE else {
                report.add(ExportIssue(kind: .warning, item: item.id, message: "item outside the drawable area; not drawn"))
                continue
            }
            let corners = Placement.corners(frame: f, rotation: rotation)
            // Turned, a frame inside the limit may reach past it: skip it rather than fail the page.
            guard corners.allSatisfy({ abs($0.x) <= maxE && abs($0.y) <= maxE }) else {
                report.add(ExportIssue(kind: .warning, item: item.id, message: "item outside the drawable area; not drawn"))
                continue
            }
            let ys = corners.map(\.y)
            func placed(_ c: Content) -> PreparedItem {
                PreparedItem(item: item, content: c, corners: corners, minY: ys.min() ?? f.y, maxY: ys.max() ?? f.y)
            }
            func placeholder(_ why: String) -> PreparedItem {
                report.add(ExportIssue(kind: .placeholder, item: item.id, message: why))
                return placed(.placeholder)
            }
            switch item.kind {
            case .image:
                guard let ref = item.blob else { out.append(placeholder("image without a blob")); continue }
                guard let images else { out.append(placeholder("image not available (no attachments given)")); continue }
                switch images.load(ref) {
                case .failure(let why):
                    out.append(placeholder(why.message))
                case .success(let image):
                    // Images of other formats are measured when decoded.
                    var img = image
                    if case .other = image.format {
                        switch images.decodeFull(ref, image) {
                        case .failure(let why): out.append(placeholder(why.message)); continue
                        case .success(let rgba):
                            img = LoadedImage(data: image.data, format: .other, type: image.type,
                                              width: rgba.width, height: rgba.height)
                        }
                    }
                    let o = (1...8).contains(item.orientation ?? 1) ? item.orientation ?? 1 : 1
                    let w = Double(img.width), h = Double(img.height)
                    let oriented = Placement.orientedSize(o, width: w, height: h)
                    let full = Rect(x: 0, y: 0, w: oriented.w, h: oriented.h)
                    guard let crop = intersect(item.crop ?? full, full) else {
                        out.append(placeholder("crop lies outside the image"))
                        continue
                    }
                    // The crop, intersected with the image as decoded, is drawn onto the frame (§8.2.5).
                    let m = Placement.cropToPage(crop: crop, frame: f, rotation: rotation)
                        .after(Placement.orientation(o, width: w, height: h))
                    out.append(placed(.image(ref: ref, image: img, transform: m, clip: corners)))
                }
            case .text:
                guard let content = item.text else { out.append(placeholder("text item without text")); continue }
                guard let shaper else {
                    report.add(ExportIssue(kind: .warning, item: item.id, message: "text box not drawn (no text shaper)"))
                    out.append(placed(.none))
                    continue
                }
                do {
                    let shaped = try shaper.shape(content, frame: f)
                    for (script, example) in shaped.missingScripts.sorted(by: { $0.key < $1.key }) {
                        report.add(ExportIssue(kind: .warning, item: item.id, message: TextIssues.missing(script, example)))
                    }
                    for script in shaped.approximateScripts.sorted() where shaped.missingScripts[script] == nil {
                        report.add(ExportIssue(kind: .warning, item: item.id,
                                               message: "\(TextIssues.name(script)) text is drawn without full shaping (approximate); the app's export is exact"))
                    }
                    out.append(placed(.text(shaped, rotation: Placement.rotation(rotation, about: f))))
                } catch {
                    report.add(ExportIssue(kind: .warning, item: item.id, message: "text box not drawn (\(error))"))
                    out.append(placed(.none))
                }
            case .pdfPage:
                out.append(placeholder("PDF page backgrounds are not drawn yet; drawn as a placeholder"))
            default:
                out.append(placeholder("unknown item kind \"\(item.kind.rawValue)\""))
            }
        }
        if items.count > RenderLimits.maxItemsPerPage {
            report.add(ExportIssue(kind: .warning, message: "more than \(RenderLimits.maxItemsPerPage) items on a page; the rest are not drawn"))
        }
        return out
    }

    /// Intersection of two rectangles; nil when it is empty.
    static func intersect(_ a: Rect, _ b: Rect) -> Rect? {
        guard a.hasPositiveSize else { return nil }
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.x + a.w, b.x + b.w), y1 = min(a.y + a.h, b.y + b.h)
        guard x1 > x0, y1 > y0 else { return nil }
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

/// Wording of the text report (docs/attachments.md §6).
enum TextIssues {
    /// A Unicode script name for people (`Old_Italic` → `Old Italic`).
    static func name(_ script: String) -> String {
        switch script {
        case "Han": return "Han (Chinese, Japanese, Korean)"
        case "Common": return "symbol"
        default: return script.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// The package that brings fonts for `script` on Debian and Ubuntu.
    static func package(_ script: String) -> String {
        ["Han", "Hiragana", "Katakana", "Hangul", "Bopomofo"].contains(script) ? "fonts-noto-cjk"
            : script == "Common" ? "fonts-noto-color-emoji or fonts-noto-core" : "fonts-noto-core"
    }

    static func missing(_ script: String, _ example: UInt32) -> String {
        let ch = Unicode.Scalar(example).map { String($0) } ?? "?"
        return "text uses \(name(script)) characters (e.g. \(ch), U+\(String(format: "%04X", example))); no installed font "
            + "covers them, so they are drawn as boxes (install \(package(script)) or put a font in "
            + "~/.local/share/sempere/fonts or $SEMPERE_FONT_DIR)"
    }
}
