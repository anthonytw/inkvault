import Foundation
import Sempere
import SemperePDF

/// Draws PDF pages as pixels for the SVG and PNG exporters (and for the PDF
/// exporter when a page cannot be copied as a form). The app implements it
/// with PDFKit; the CLI runs Poppler in a separate process. Never part of
/// the renderers themselves: `Process` does not exist on iOS.
public protocol PDFPageRasterizer: Sendable {
    /// The effective page `pageIndex` of the PDF at `pdf` (CropBox ∩ MediaBox,
    /// turned by `/Rotate`, format.md §8.2.6), scaled to exactly
    /// `pixelWidth × pixelHeight`.
    func rasterize(pdf: URL, pageIndex: Int, pixelWidth: Int, pixelHeight: Int) throws -> RGBAImage
}

/// An RGBA8 image: straight alpha, rows top first.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width × height × 4` bytes.
    public let pixels: [UInt8]

    /// - Throws: `RenderError.invalidImage` unless both sides are positive and
    ///   `pixels` holds exactly `width × height × 4` bytes.
    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        let (area, o1) = width.multipliedReportingOverflow(by: height)
        let (bytes, o2) = area.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !o1, !o2, pixels.count == bytes else { throw RenderError.invalidImage }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

/// What an export drew as placeholders and what it wants the user to know
/// (`docs/attachments.md` §10). Exports never fail because of an item.
public struct RenderReport: Sendable, Equatable {
    /// An item drawn as a placeholder (format.md §8.5.2).
    public struct Placeholder: Sendable, Equatable {
        /// 1-based note page (in the order exported, across notes).
        public var page: Int
        public var item: UUID
        public var kind: ItemKind
        public var reason: PlaceholderReason
    }

    public var placeholders: [Placeholder] = []
    public var warnings: [String] = []

    public init() {}

    /// Placeholders for `reason`.
    public func count(_ reason: PlaceholderReason) -> Int { placeholders.filter { $0.reason == reason }.count }
}

/// Why an item is a placeholder.
public enum PlaceholderReason: Error, Hashable, Sendable {
    /// The export was given no `BlobSource`.
    case noBlobSource
    /// The blob is missing, invalid or too large (why).
    case blobUnavailable(String)
    /// The PDF cannot be read or the page cannot be copied (why).
    case pdfUnreadable(String)
    /// SVG/PNG: no `PDFPageRasterizer` was given.
    case noRasterizer
    /// The rasterizer failed, timed out or returned nothing usable (why).
    case rasterizerFailed(String)
    /// An item kind this renderer does not draw (yet), or an unknown one.
    case unsupportedKind(String)
    /// The export's raster budget (`RenderLimits.maxBackgroundPixels`) is spent.
    case rasterBudget

    /// A short English description, for reports.
    public var description: String {
        switch self {
        case .noBlobSource: return "attachments not available to this export"
        case .blobUnavailable(let why): return "attachment unavailable: \(why)"
        case .pdfUnreadable(let why): return "PDF page unreadable: \(why)"
        case .noRasterizer: return "no PDF renderer"
        case .rasterizerFailed(let why): return "PDF renderer failed: \(why)"
        case .unsupportedKind(let k): return "\(k) items are not drawn by this export"
        case .rasterBudget: return "too many PDF background pixels in this export"
        }
    }
}

/// An affine map `(x, y) ↦ (a·x + c·y + tx, b·x + d·y + ty)`, PDF's `cm` order.
struct Affine: Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0

    static let identity = Affine()

    func apply(_ p: Point) -> Point { Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }

    /// `self ∘ m`: first `m`, then `self`.
    func after(_ m: Affine) -> Affine {
        Affine(a: a * m.a + c * m.b, b: b * m.a + d * m.b, c: a * m.c + c * m.d, d: b * m.c + d * m.d,
               tx: a * m.tx + c * m.ty + tx, ty: b * m.tx + d * m.ty + ty)
    }

    var inverse: Affine? {
        let det = a * d - b * c
        guard det.isFinite, abs(det) > 1e-300 else { return nil }
        return Affine(a: d / det, b: -b / det, c: -c / det, d: a / det,
                      tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }

    var isFinite: Bool { [a, b, c, d, tx, ty].allSatisfy(\.isFinite) }

    static func translate(_ x: Double, _ y: Double) -> Affine { Affine(tx: x, ty: y) }
}

/// Placement of an item on its page (format.md §8.5.1).
enum ItemGeometry {
    /// cos and sin of `degrees`, exact for multiples of 90.
    static func rotation(_ degrees: Double) -> (cos: Double, sin: Double) {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        switch (r + 360).truncatingRemainder(dividingBy: 360) {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default:
            let t = r * .pi / 180
            return (cos(t), sin(t))
        }
    }

    /// Rotation by `degrees` (clockwise on the y-down page) about the frame's centre.
    static func rotate(frame f: Rect, degrees: Double) -> Affine {
        let (cs, sn) = rotation(degrees)
        let mx = f.x + f.w / 2, my = f.y + f.h / 2
        return Affine(a: cs, b: sn, c: -sn, d: cs, tx: mx - mx * cs + my * sn, ty: my - mx * sn - my * cs)
    }

    /// Source coordinates → page: the crop onto the frame, then the rotation.
    static func placement(crop: Rect, frame: Rect, degrees: Double) -> Affine {
        let sx = frame.w / crop.w, sy = frame.h / crop.h
        let toFrame = Affine(a: sx, d: sy, tx: frame.x - crop.x * sx, ty: frame.y - crop.y * sy)
        return rotate(frame: frame, degrees: degrees).after(toFrame)
    }

    /// The frame's corners after rotation, in page coordinates.
    static func corners(frame f: Rect, degrees: Double) -> [Point] {
        let r = rotate(frame: f, degrees: degrees)
        return [Point(x: f.x, y: f.y), Point(x: f.x + f.w, y: f.y), Point(x: f.x + f.w, y: f.y + f.h),
                Point(x: f.x, y: f.y + f.h)].map(r.apply)
    }

    /// PDF user space → effective-page coordinates (y down) for a page's
    /// visible box and `/Rotate` (format.md §8.5.1 table).
    static func pdfToEffective(visible v: PDFRect, rotation: Int) -> Affine {
        let bw = v.width, bh = v.height
        switch rotation {
        case 90: return Affine(a: 0, b: 1, c: 1, d: 0, tx: bh - v.y1, ty: -v.x0)            // (bh − t, s)
        case 180: return Affine(a: -1, b: 0, c: 0, d: 1, tx: bw + v.x0, ty: bh - v.y1)        // (bw − s, bh − t)
        case 270: return Affine(a: 0, b: -1, c: -1, d: 0, tx: v.y1, ty: bw + v.x0)           // (t, bw − s)
        default: return Affine(a: 1, b: 0, c: 0, d: -1, tx: -v.x0, ty: v.y1)                 // (s, t)
        }
    }

    /// The placeholder: the rotated frame outlined 1 pt in `#9AA0A6` with both diagonals.
    static func placeholder(_ corners: [Point]) -> [DrawCommand] {
        let grey = Paint(r: 0x9A, g: 0xA0, b: 0xA6)
        return [DrawCommand(.path([Subpath(points: corners, closed: true)]), stroke: grey, lineWidth: 1),
                DrawCommand(.line(from: corners[0], to: corners[2]), stroke: grey, lineWidth: 1),
                DrawCommand(.line(from: corners[1], to: corners[3]), stroke: grey, lineWidth: 1)]
    }
}

/// An item validated once, with its rotated frame.
struct PreparedItem {
    var item: Item
    /// 1-based note page, for the report.
    var pageNumber: Int
    var corners: [Point]
    var minY: Double
    var maxY: Double

    /// Background items first fill their frame with the paper colour (format.md §8.2.3).
    var fillsBackground: Bool { item.layer.rawValue < ItemLayer.content.rawValue }

    /// - Throws: `RenderError.invalidGeometry` for a non-finite frame or
    ///   rotation, `.extentTooLarge` beyond `RenderLimits.maxExtent`.
    init(_ item: Item, pageNumber: Int) throws {
        let f = item.frame
        guard [f.x, f.y, f.w, f.h].allSatisfy(\.isFinite), f.w > 0, f.h > 0, (item.rotation ?? 0).isFinite else {
            throw RenderError.invalidGeometry
        }
        corners = ItemGeometry.corners(frame: f, degrees: item.rotation ?? 0)
        for p in corners {
            guard p.x.isFinite, p.y.isFinite else { throw RenderError.invalidGeometry }
            guard abs(p.x) <= RenderLimits.maxExtent, abs(p.y) <= RenderLimits.maxExtent else {
                throw RenderError.extentTooLarge(max(abs(p.x), abs(p.y)))
            }
        }
        self.item = item
        self.pageNumber = pageNumber
        minY = corners.map(\.y).min() ?? f.y
        maxY = corners.map(\.y).max() ?? f.y
    }

    /// The paper fill of a background item, in page coordinates.
    func backgroundFill(_ paper: Paper) -> DrawCommand {
        DrawCommand(.path([Subpath(points: corners, closed: true)]), fill: Paint(paper.background))
    }

    /// The placeholder, in page coordinates.
    var placeholder: [DrawCommand] { ItemGeometry.placeholder(corners) }
}

/// A PDF page drawn by a `PDFPageRasterizer`, ready to place.
struct RasterBackground {
    var image: RGBAImage
    /// Effective-page coordinates → page coordinates.
    var placement: Affine
    /// The effective page, points.
    var width: Double
    var height: Double
    /// The part of the effective page shown.
    var crop: Rect
}

/// Resolves every item of a page once for the SVG and PNG writers: a
/// rasterized PDF page or a placeholder (reported).
enum RasterItems {
    enum Draw {
        case raster(RasterBackground)
        case placeholder(PlaceholderReason)
    }

    static func resolve(_ items: [PreparedItem], backgrounds: PDFBackgrounds, scale: Double, maxPixels: Int,
                        report: inout RenderReport) -> [UUID: Draw] {
        var out: [UUID: Draw] = [:]
        for it in items {
            let d: Draw
            if it.item.kind != .pdfPage || it.item.blob == nil {
                d = .placeholder(.unsupportedKind(it.item.kind.rawValue))
            } else if backgrounds.blobs == nil {
                d = .placeholder(.noBlobSource)
            } else if backgrounds.rasterizer == nil {
                d = .placeholder(.noRasterizer)
            } else {
                switch PDFWriter.rasterized(it, backgrounds: backgrounds, scale: scale, maxPixels: maxPixels) {
                case .success(let r)?: d = .raster(r)
                case .failure(let reason)?: d = .placeholder(reason)
                case nil:
                    if case .failure(let reason) = backgrounds.file(it.item) { d = .placeholder(reason) }
                    else { d = .placeholder(.pdfUnreadable("unknown page geometry")) }
                }
            }
            if case .placeholder(let reason) = d {
                report.placeholders.append(.init(page: it.pageNumber, item: it.item.id, kind: it.item.kind, reason: reason))
            }
            out[it.item.id] = d
        }
        return out
    }
}
