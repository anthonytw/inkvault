import Foundation

/// An RGBA8 image (straight, non-premultiplied alpha, row-major, top row first)
/// with an anti-aliased non-zero-winding polygon filler.
///
/// Coverage is exact horizontally and sampled `subRows` times vertically per
/// pixel, so edges get `subRows * (pixel width)` distinct levels. Overlapping
/// polygons in one `fill` call are a union (non-zero rule), exactly like a
/// single PDF `f` operator, so an overlapping ribbon is blended once.
struct Raster {
    /// Vertical samples per pixel row.
    static let subRows = 8

    let width: Int
    let height: Int
    /// `width * height * 4` bytes; starts fully transparent.
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    private struct Edge {
        var x0: Double, y0: Double, slope: Double
        var jStart: Int, jEnd: Int
        var dir: Int
    }

    /// Fills the union of `polygons` (device pixel coordinates, implicitly
    /// closed) with `paint`, blended "over" the existing pixels.
    mutating func fill(_ polygons: [[Point]], paint: Paint) {
        guard width > 0, height > 0 else { return }
        let ss = Self.subRows
        let limit = Double(height * ss)
        var edges: [Edge] = []
        for poly in polygons where poly.count >= 3 {
            for i in poly.indices {
                var a = poly[i], b = poly[(i + 1) % poly.count]
                guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, a.y != b.y else { continue }
                var dir = 1
                if a.y > b.y { swap(&a, &b); dir = -1 }
                // Sub-rows j whose sample line y = (j + 0.5) / ss lies in [a.y, b.y).
                let lo = max((a.y * Double(ss) - 0.5).rounded(.up), 0)
                let hi = min((b.y * Double(ss) - 0.5).rounded(.up), limit)
                guard lo < hi else { continue }
                edges.append(Edge(x0: a.x, y0: a.y, slope: (b.x - a.x) / (b.y - a.y),
                                  jStart: Int(lo), jEnd: Int(hi), dir: dir))
            }
        }
        guard !edges.isEmpty else { return }
        edges.sort { $0.jStart < $1.jStart }

        let inv = 1.0 / Double(ss)
        let w = Double(width)
        var acc = [Double](repeating: 0, count: width + 1)
        var delta = [Double](repeating: 0, count: width + 1)
        var rowMin = Int.max, rowMax = -1
        var active: [Int] = []
        var crossings: [(x: Double, dir: Int)] = []
        var next = 0
        var j = edges[0].jStart
        var row = j / ss

        func flush(_ r: Int) {
            guard rowMax >= 0 else { return }
            var run = 0.0
            for px in rowMin...rowMax {
                run += delta[px]
                let cov = min(acc[px] + run, 1)
                acc[px] = 0; delta[px] = 0
                if px < width, cov > 1.0 / 1024 { blend(x: px, y: r, paint: paint, coverage: cov) }
            }
            rowMin = Int.max; rowMax = -1
        }

        while true {
            if active.isEmpty {
                guard next < edges.count else { break }
                j = max(j, edges[next].jStart)
            }
            if j / ss != row { flush(row); row = j / ss }
            while next < edges.count, edges[next].jStart <= j { active.append(next); next += 1 }
            active.removeAll { edges[$0].jEnd <= j }
            if !active.isEmpty {
                let ys = (Double(j) + 0.5) * inv
                crossings.removeAll(keepingCapacity: true)
                for e in active { crossings.append((edges[e].x0 + (ys - edges[e].y0) * edges[e].slope, edges[e].dir)) }
                crossings.sort { $0.x < $1.x }
                var winding = 0
                var start = 0.0
                for c in crossings {
                    let before = winding
                    winding += c.dir
                    if before == 0, winding != 0 { start = c.x }
                    else if before != 0, winding == 0 {
                        let xa = min(max(start, 0), w), xb = min(max(c.x, 0), w)
                        guard xb > xa else { continue }
                        let ia = Int(xa), ib = Int(xb)
                        if ia == ib {
                            acc[ia] += (xb - xa) * inv
                        } else {
                            acc[ia] += (Double(ia + 1) - xa) * inv
                            acc[ib] += (xb - Double(ib)) * inv
                            if ib > ia + 1 { delta[ia + 1] += inv; delta[ib] -= inv }
                        }
                        rowMin = min(rowMin, ia); rowMax = max(rowMax, ib)
                    }
                }
            }
            j += 1
            if j >= height * ss { break }
        }
        flush(row)
    }

    /// Composites a rasterized PDF page: every device pixel whose centre
    /// maps (through the inverse of `device`, effective page → device) into
    /// the crop and the page is sampled bilinearly from the image and blended
    /// over. Work is bounded by the frame's device bounding box.
    mutating func draw(_ r: RasterBackground, toDevice device: Affine) {
        guard width > 0, height > 0, let inv = device.inverse, inv.isFinite else { return }
        let c = r.crop
        let corners = [Point(x: c.x, y: c.y), Point(x: c.x + c.w, y: c.y), Point(x: c.x + c.w, y: c.y + c.h),
                       Point(x: c.x, y: c.y + c.h)].map(device.apply)
        guard let x0 = corners.map(\.x).min(), let x1 = corners.map(\.x).max(),
              let y0 = corners.map(\.y).min(), let y1 = corners.map(\.y).max(),
              x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite else { return }
        let px0 = max(0, Int(max(x0, -1).rounded(.down))), px1 = min(width - 1, Int(min(x1, Double(width)).rounded(.up)))
        let py0 = max(0, Int(max(y0, -1).rounded(.down))), py1 = min(height - 1, Int(min(y1, Double(height)).rounded(.up)))
        guard px0 <= px1, py0 <= py1 else { return }
        let img = r.image
        let kx = Double(img.width) / r.width, ky = Double(img.height) / r.height
        let lo = (x: max(c.x, 0), y: max(c.y, 0)), hi = (x: min(c.x + c.w, r.width), y: min(c.y + c.h, r.height))
        for py in py0...py1 {
            for px in px0...px1 {
                let e = inv.apply(Point(x: Double(px) + 0.5, y: Double(py) + 0.5))
                guard e.x >= lo.x, e.x < hi.x, e.y >= lo.y, e.y < hi.y else { continue }
                let (rgba, a) = Self.sample(img, x: e.x * kx - 0.5, y: e.y * ky - 0.5)
                guard a > 0 else { continue }
                blend(x: px, y: py, paint: Paint(r: rgba.0, g: rgba.1, b: rgba.2, alpha: a), coverage: 1)
            }
        }
    }

    /// Bilinear sample (edge pixels extended); colour weighted by alpha.
    static func sample(_ img: RGBAImage, x: Double, y: Double) -> ((UInt8, UInt8, UInt8), Double) {
        let fx = min(max(x, 0), Double(img.width - 1)), fy = min(max(y, 0), Double(img.height - 1))
        let ix = Int(fx), iy = Int(fy)
        let jx = min(ix + 1, img.width - 1), jy = min(iy + 1, img.height - 1)
        let tx = fx - Double(ix), ty = fy - Double(iy)
        var acc = [0.0, 0.0, 0.0, 0.0]
        for (xx, yy, w) in [(ix, iy, (1 - tx) * (1 - ty)), (jx, iy, tx * (1 - ty)), (ix, jy, (1 - tx) * ty), (jx, jy, tx * ty)]
        where w > 0 {
            let i = (yy * img.width + xx) * 4
            let a = Double(img.pixels[i + 3]) / 255 * w
            acc[0] += Double(img.pixels[i]) * a; acc[1] += Double(img.pixels[i + 1]) * a
            acc[2] += Double(img.pixels[i + 2]) * a; acc[3] += a
        }
        guard acc[3] > 0 else { return ((0, 0, 0), 0) }
        func ch(_ v: Double) -> UInt8 { UInt8(min(max((v / acc[3]).rounded(), 0), 255)) }
        return ((ch(acc[0]), ch(acc[1]), ch(acc[2])), min(acc[3], 1))
    }

    private mutating func blend(x: Int, y: Int, paint: Paint, coverage: Double) {
        let sa = paint.alpha * coverage
        guard sa > 0 else { return }
        let i = (y * width + x) * 4
        let da = Double(pixels[i + 3]) / 255
        let outA = sa + da * (1 - sa)
        guard outA > 0 else { return }
        let src = [Double(paint.r), Double(paint.g), Double(paint.b)]
        for c in 0..<3 {
            let v = (src[c] * sa + Double(pixels[i + c]) * da * (1 - sa)) / outA
            pixels[i + c] = UInt8(min(max(v.rounded(), 0), 255))
        }
        pixels[i + 3] = UInt8(min(max((outA * 255).rounded(), 0), 255))
    }
}
