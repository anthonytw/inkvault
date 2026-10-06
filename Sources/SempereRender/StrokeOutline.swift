import Foundation
import Sempere

/// Converts sampled strokes into fillable or strokable geometry.
///
/// Per tool (approximations, there is no texture rendering):
/// - `pen`, `fountainPen`: variable-width ribbon from the sample `w`; opacity
///   `ink.color.a * mean(o)`. The fountain pen is not nib-angle dependent.
/// - `monoline`: constant `ink.width` stroked polyline.
/// - `marker`: variable-width ribbon from the sample `w` (the drawn width,
///   format.md §5.6, as PencilKit draws a marker's point sizes and Notability
///   its highlighters), opacity x 0.5 (approximates the marker's translucent
///   look); one fill, so overlaps within a stroke blend once.
/// - `pencil` (x0.8), `crayon` (x0.85), `watercolor` (x0.5): rendered like
///   `pen` with the stated opacity factor; no grain or bleed.
///
/// A ribbon is a union of positively-oriented polygons (one quad per segment
/// plus circles at the ends and at sharp turns) meant for a non-zero fill.
/// Opacity is one value per stroke (the mean sample opacity); per-sample
/// opacity variation along a stroke is not representable in a single fill.
public enum StrokeOutline {
    /// Opacity multiplier for a tool, on top of colour alpha and sample opacity.
    public static func toolOpacity(_ tool: InkTool) -> Double {
        switch tool {
        case .pen, .fountainPen, .monoline: return 1
        case .marker: return 0.5
        case .pencil: return 0.8
        case .crayon: return 0.85
        case .watercolor: return 0.5
        }
    }

    /// Opacity factor applied on top of the colour's own alpha:
    /// `mean(sample o) * toolOpacity`. Feed it to `Paint(_:opacity:)`.
    public static func opacityFactor(for stroke: Stroke, samples: [StrokeSample]) -> Double {
        let meanO = samples.isEmpty ? 1 : samples.reduce(0) { $0 + $1.o } / Double(samples.count)
        return clamp01(meanO) * toolOpacity(stroke.ink.tool)
    }

    /// Draw commands for one stroke (empty for a stroke with no points).
    public static func commands(for stroke: Stroke, tolerance: Double = 0.05, offsetY: Double = 0) -> [DrawCommand] {
        let samples = StrokeSampler.samples(for: stroke, tolerance: tolerance, offsetY: offsetY)
        guard !samples.isEmpty else { return [] }
        let scale = (stroke.transform ?? .identity).meanScale
        let paint = Paint(stroke.ink.color, opacity: opacityFactor(for: stroke, samples: samples))

        switch stroke.ink.tool {
        case .monoline:
            let width = min(max(stroke.ink.width * scale, 0.05), RenderLimits.maxNibWidth)
            if isDot(samples) {
                return [DrawCommand(.path([circle(samples[0].point, radius: width / 2)]), fill: paint)]
            }
            return [DrawCommand(.path([Subpath(points: samples.map(\.point), closed: false)]),
                                stroke: paint, lineWidth: width)]
        default:
            let polys = ribbon(samples, fallbackWidth: stroke.ink.width * scale)
            return polys.isEmpty ? [] : [DrawCommand(.path(polys), fill: paint)]
        }
    }

    static func isDot(_ s: [StrokeSample]) -> Bool {
        guard let first = s.first else { return false }
        return s.allSatisfy { $0.point.distance(to: first.point) < 1e-9 }
    }

    /// Variable-width ribbon polygons. Each has positive `signedArea`.
    public static func ribbon(_ samples: [StrokeSample], fallbackWidth: Double) -> [Subpath] {
        guard !samples.isEmpty else { return [] }
        func radius(_ s: StrokeSample) -> Double {
            let w = s.w > 0 ? s.w : fallbackWidth
            return min(max(w, 0.05), RenderLimits.maxNibWidth) / 2
        }
        if isDot(samples) {
            return [circle(samples[0].point, radius: samples.map(radius).max() ?? 0.025)]
        }
        var polys: [Subpath] = []
        let n = samples.count
        for i in 0..<(n - 1) {
            let a = samples[i].point, b = samples[i + 1].point
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
            let ra = radius(samples[i]), rb = radius(samples[i + 1])
            let quad = [Point(x: a.x + nx * ra, y: a.y + ny * ra), Point(x: b.x + nx * rb, y: b.y + ny * rb),
                        Point(x: b.x - nx * rb, y: b.y - ny * rb), Point(x: a.x - nx * ra, y: a.y - ny * ra)]
            polys.append(oriented(Subpath(points: quad, closed: true)))
        }
        // Round caps at both ends, round joins where the direction turns.
        polys.append(circle(samples[0].point, radius: radius(samples[0])))
        polys.append(circle(samples[n - 1].point, radius: radius(samples[n - 1])))
        if n > 2 {
            for i in 1..<(n - 1) {
                let p = samples[i - 1].point, q = samples[i].point, r = samples[i + 1].point
                let l1 = p.distance(to: q), l2 = q.distance(to: r)
                guard l1 > 1e-9, l2 > 1e-9 else { continue }
                let cosT = ((q.x - p.x) * (r.x - q.x) + (q.y - p.y) * (r.y - q.y)) / (l1 * l2)
                if cosT < 0.97 { polys.append(circle(q, radius: radius(samples[i]))) }
            }
        }
        return polys
    }

    /// Unit-circle vertices (32 segments, counter-clockwise in the shoelace
    /// sense). Written out as constants so that no `sin`/`cos` call, whose last
    /// digit can differ between libm implementations, sits in the output path.
    static let unitCircle: [(x: Double, y: Double)] = [
        (1.0, 0.0),
        (0.9807852804032304, 0.1950903220161282),
        (0.9238795325112867, 0.3826834323650898),
        (0.8314696123025452, 0.5555702330196022),
        (0.7071067811865476, 0.7071067811865475),
        (0.5555702330196023, 0.8314696123025452),
        (0.3826834323650898, 0.9238795325112867),
        (0.1950903220161283, 0.9807852804032304),
        (1e-16, 1.0),
        (-0.1950903220161282, 0.9807852804032304),
        (-0.3826834323650897, 0.9238795325112867),
        (-0.555570233019602, 0.8314696123025453),
        (-0.7071067811865475, 0.7071067811865476),
        (-0.8314696123025453, 0.5555702330196022),
        (-0.9238795325112867, 0.3826834323650899),
        (-0.9807852804032304, 0.1950903220161286),
        (-1.0, 1e-16),
        (-0.9807852804032304, -0.1950903220161284),
        (-0.9238795325112868, -0.3826834323650897),
        (-0.8314696123025455, -0.555570233019602),
        (-0.7071067811865477, -0.7071067811865475),
        (-0.5555702330196022, -0.8314696123025452),
        (-0.3826834323650903, -0.9238795325112865),
        (-0.1950903220161287, -0.9807852804032303),
        (-2e-16, -1.0),
        (0.1950903220161283, -0.9807852804032304),
        (0.38268343236509, -0.9238795325112866),
        (0.5555702330196018, -0.8314696123025455),
        (0.7071067811865474, -0.7071067811865477),
        (0.8314696123025452, -0.5555702330196022),
        (0.9238795325112865, -0.3826834323650904),
        (0.9807852804032303, -0.1950903220161287),
    ]

    /// Regular 32-gon approximating a circle, with positive orientation.
    public static func circle(_ c: Point, radius r: Double) -> Subpath {
        Subpath(points: unitCircle.map { Point(x: c.x + r * $0.x, y: c.y + r * $0.y) }, closed: true)
    }

    private static func oriented(_ s: Subpath) -> Subpath {
        s.signedArea < 0 ? Subpath(points: s.points.reversed(), closed: true) : s
    }
}
