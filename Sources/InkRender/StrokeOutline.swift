import Foundation
import InkVault

/// Converts sampled strokes into fillable or strokable geometry.
///
/// Per tool (approximations, there is no texture rendering):
/// - `pen`, `fountainPen`: variable-width ribbon from the sample `w`; opacity
///   `ink.color.a * mean(o)`. The fountain pen is not nib-angle dependent.
/// - `monoline`: constant `ink.width` stroked polyline.
/// - `marker`: constant `ink.width` stroked polyline, opacity x 0.5
///   (approximates the marker's translucent look).
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

    /// Final paint alpha: `color.a * mean(sample o) * toolOpacity`.
    public static func opacity(for stroke: Stroke, samples: [StrokeSample]) -> Double {
        let meanO = samples.isEmpty ? 1 : samples.reduce(0) { $0 + $1.o } / Double(samples.count)
        return Double(stroke.ink.color.a) / 255 * min(max(meanO, 0), 1) * toolOpacity(stroke.ink.tool)
    }

    /// Draw commands for one stroke (empty for a stroke with no points).
    public static func commands(for stroke: Stroke, tolerance: Double = 0.05, offsetY: Double = 0) -> [DrawCommand] {
        let samples = StrokeSampler.samples(for: stroke, tolerance: tolerance, offsetY: offsetY)
        guard !samples.isEmpty else { return [] }
        let scale = (stroke.transform ?? .identity).meanScale
        let c = stroke.ink.color
        let paint = Paint(r: c.r, g: c.g, b: c.b, alpha: opacity(for: stroke, samples: samples))

        switch stroke.ink.tool {
        case .monoline, .marker:
            let width = max(stroke.ink.width * scale, 0.05)
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
            return max(w, 0.05) / 2
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

    /// Regular polygon approximating a circle, with positive orientation.
    public static func circle(_ c: Point, radius r: Double) -> Subpath {
        let tol = 0.02
        let steps: Int
        if r <= tol {
            steps = 8
        } else {
            steps = min(max(Int((Double.pi / acos(1 - tol / r)).rounded(.up)), 8), 48)
        }
        var pts: [Point] = []
        pts.reserveCapacity(steps)
        for k in 0..<steps {
            let a = 2 * Double.pi * Double(k) / Double(steps)
            pts.append(Point(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        return oriented(Subpath(points: pts, closed: true))
    }

    private static func oriented(_ s: Subpath) -> Subpath {
        s.signedArea < 0 ? Subpath(points: s.points.reversed(), closed: true) : s
    }
}
