import Foundation
import InkVault

/// RGB colour plus alpha (0...1), the paint used by every draw command.
public struct Paint: Hashable, Sendable {
    /// Red, green and blue components, 0...255.
    public var r: UInt8, g: UInt8, b: UInt8
    /// Opacity 0...1.
    public var alpha: Double

    /// Creates a paint; `alpha` is clamped to 0...1 (NaN becomes 0).
    public init(r: UInt8, g: UInt8, b: UInt8, alpha: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.alpha = clamp01(alpha)
    }

    /// Paint from a model colour: alpha = `color.a / 255 * opacity`.
    public init(_ c: Color, opacity: Double = 1) {
        self.init(r: c.r, g: c.g, b: c.b, alpha: Double(c.a) / 255 * opacity)
    }

    /// `#rrggbb`.
    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

/// A polyline or polygon.
public struct Subpath: Hashable, Sendable {
    /// Vertices in drawing order.
    public var points: [Point]
    /// Whether the last vertex connects back to the first.
    public var closed: Bool
    /// Creates a subpath.
    public init(points: [Point], closed: Bool) { self.points = points; self.closed = closed }

    /// Shoelace signed area (positive = counter-clockwise in a y-up frame).
    public var signedArea: Double {
        guard points.count > 2 else { return 0 }
        var a = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }
}

/// The geometry a draw command paints.
public enum Primitive: Hashable, Sendable {
    case rect(x: Double, y: Double, width: Double, height: Double)
    case line(from: Point, to: Point)
    case circle(center: Point, radius: Double)
    case path([Subpath])
}

/// A primitive plus how to paint it. This is the common vocabulary the PDF and
/// SVG writers consume; both paper and strokes are expressed with it.
/// Strokes always use round caps and round joins.
public struct DrawCommand: Hashable, Sendable {
    /// The shape to paint.
    public var primitive: Primitive
    /// Fill paint, or `nil` for no fill.
    public var fill: Paint?
    /// Outline paint, or `nil` for no outline.
    public var stroke: Paint?
    /// Outline width in points (used only when `stroke` is set).
    public var lineWidth: Double

    /// Creates a command; `lineWidth` only matters when `stroke` is set.
    public init(_ primitive: Primitive, fill: Paint? = nil, stroke: Paint? = nil, lineWidth: Double = 1) {
        self.primitive = primitive; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
    }
    /// Vertices the primitive holds (what `RenderLimits.maxOutlinePoints` counts).
    var pointCount: Int {
        switch primitive {
        case .rect: return 4
        case .line: return 2
        case .circle: return 1
        case .path(let subs): return subs.reduce(0) { $0 + $1.points.count }
        }
    }
}

/// Options shared by the PDF and SVG writers.
public struct RenderOptions: Sendable {
    /// Draw the paper background and pattern.
    public var paper: Bool
    /// Compress PDF content streams with zlib `FlateDecode`.
    public var compress: Bool
    /// Curve flattening tolerance in points.
    public var tolerance: Double
    /// Height of each PDF page an infinite page is split into. `nil` uses the
    /// page's `pageSize.breakHeight`, else the page width x 11 / 8.5 (letter
    /// aspect), independent of the page's current extent. Clamped to 72 ... `RenderLimits.maxExtent`.
    public var infiniteChunkHeight: Double?

    /// Creates options; the defaults are paper on, compression on, 0.05 pt tolerance.
    public init(paper: Bool = true, compress: Bool = true, tolerance: Double = 0.05,
                infiniteChunkHeight: Double? = nil) {
        self.paper = paper; self.compress = compress; self.tolerance = tolerance
        self.infiniteChunkHeight = infiniteChunkHeight
    }
}

/// Hard limits protecting the renderers from hostile or corrupt input.
public enum RenderLimits {
    /// Largest page height / stroke extent accepted, in points (~2.8 km at 72 dpi).
    public static let maxExtent = 200_000.0
    /// Smallest ruling / grid / dot spacing drawn; tighter paper renders blank.
    public static let minPaperSpacing = 4.0
    /// Most ruling commands drawn per band (output page or chunk-sized slice); more renders blank paper.
    public static let maxPaperCommands = 40_000.0
    /// Most ruling commands drawn over all bands of one page; a page needing
    /// more (a very tall infinite page with dense paper) renders on plain
    /// background throughout. 25 letter pages of 4 pt dots fit.
    public static let maxPaperCommandsPerPage = 1_000_000.0
    /// Curve samples a stroke may use: `samplesPerPoint` per control point
    /// plus `baseSamples`. A stroke whose segments would need more (very long
    /// segments from a few control points) is sampled more coarsely, so the
    /// work and memory a stroke costs grow with its size on disk, not with
    /// the distances its coordinates name.
    public static let samplesPerPoint = 64
    /// See `samplesPerPoint`.
    public static let baseSamples = 1024
    /// Widest nib drawn, in points (after the stroke's transform): wider ones
    /// are drawn this wide. Real tools are well under 100 pt; a nib as wide
    /// as the page would make every band rasterize every outline polygon.
    public static let maxNibWidth = 1000.0
    /// Most outline points (polygon vertices) one page may produce; more throws
    /// `RenderError.tooComplex`. A dense page of handwriting needs well under
    /// a tenth of this.
    public static let maxOutlinePoints = 40_000_000
}

/// Errors thrown by the renderers.
public enum RenderError: Error, Equatable {
    /// zlib returned this status while compressing.
    case compressionFailed(Int32)
    /// A page or stroke extends beyond `RenderLimits.maxExtent` (the value is the offending extent).
    case extentTooLarge(Double)
    /// A stroke has non-finite coordinates, widths or transform.
    case invalidGeometry
    /// Page width is not a finite positive number <= `maxExtent`, or height is negative/non-finite/too large.
    case invalidPageSize
    /// The raster scale is not a finite positive number.
    case invalidScale
    /// An output image would have `pixels` pixels, more than `limit` allows.
    case imageTooLarge(pixels: Double, limit: Int)
    /// A page's strokes would produce more than `RenderLimits.maxOutlinePoints`
    /// outline points.
    case tooComplex
}

extension RenderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let rc): return "zlib failed (status \(rc))"
        case .extentTooLarge(let e): return "page or stroke extent \(fmt(e)) pt is beyond the supported limit"
        case .invalidGeometry: return "a stroke has non-finite coordinates, sizes or transform"
        case .invalidPageSize: return "the page size is invalid"
        case .invalidScale: return "the raster scale or dpi must be a finite positive number"
        case .imageTooLarge(let pixels, let limit):
            return "image of \(fmt(pixels)) pixels exceeds the limit of \(limit); lower --dpi"
        case .tooComplex: return "the page has more ink geometry than the renderer accepts"
        }
    }
}

/// Clamps to 0...1; NaN becomes 0 (plain `min(max(x, 0), 1)` passes NaN through).
func clamp01(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }

extension DrawCommand {
    /// The same command moved down by `dy` points.
    func translated(dy: Double) -> DrawCommand {
        func t(_ p: Point) -> Point { Point(x: p.x, y: p.y + dy) }
        var c = self
        switch primitive {
        case let .rect(x, y, w, h): c.primitive = .rect(x: x, y: y + dy, width: w, height: h)
        case let .line(a, b): c.primitive = .line(from: t(a), to: t(b))
        case let .circle(center, r): c.primitive = .circle(center: t(center), radius: r)
        case let .path(subs): c.primitive = .path(subs.map { Subpath(points: $0.points.map(t), closed: $0.closed) })
        }
        return c
    }
}

/// Deterministic, locale-independent number formatting (<= 3 decimals).
func fmt(_ v: Double) -> String {
    guard v.isFinite else { return "0" }
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return (s == "-0" || s.isEmpty) ? "0" : s
}
