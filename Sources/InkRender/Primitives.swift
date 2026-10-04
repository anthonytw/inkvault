import Foundation
import InkVault

/// RGB colour plus alpha (0...1), the paint used by every draw command.
public struct Paint: Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    /// Opacity 0...1.
    public var alpha: Double

    /// Creates a paint; `alpha` is clamped to 0...1.
    public init(r: UInt8, g: UInt8, b: UInt8, alpha: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.alpha = min(max(alpha, 0), 1)
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
    public var points: [Point]
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
    public var primitive: Primitive
    public var fill: Paint?
    public var stroke: Paint?
    public var lineWidth: Double

    /// Creates a command; `lineWidth` only matters when `stroke` is set.
    public init(_ primitive: Primitive, fill: Paint? = nil, stroke: Paint? = nil, lineWidth: Double = 1) {
        self.primitive = primitive; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
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
    /// page width x 11 / 8.5 (letter aspect), independent of the page's current
    /// extent. Clamped to 72 ... `RenderLimits.maxExtent`.
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
    /// Most ruling commands drawn per output page; more renders blank paper.
    public static let maxPaperCommands = 20_000.0
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
}

/// Deterministic, locale-independent number formatting (<= 3 decimals).
func fmt(_ v: Double) -> String {
    guard v.isFinite else { return "0" }
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return (s == "-0" || s.isEmpty) ? "0" : s
}
