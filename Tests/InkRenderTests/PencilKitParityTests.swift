import XCTest
import InkVault
@testable import InkRender

#if canImport(PencilKit)
import PencilKit

final class PencilKitParityTests: XCTestCase {
    func testInterpolatedLocationMatchesPKStrokePath() {
        let raw: [(Double, Double)] = [(0, 0), (10, 20), (30, 5), (50, 40), (70, 10), (90, 30), (120, 0)]
        let ours = raw.enumerated().map { i, p in
            StrokePoint(x: p.0, y: p.1, t: Double(i) * 0.1, w: 2 + Double(i), h: 2 + Double(i), o: 1)
        }
        let cps = ours.map {
            PKStrokePoint(location: CGPoint(x: $0.x, y: $0.y), timeOffset: $0.t,
                          size: CGSize(width: $0.w, height: $0.h), opacity: CGFloat($0.o),
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: cps, creationDate: Date())
        let maxT = Double(raw.count - 1)
        for k in 0..<20 {
            let t = maxT * Double(k) / 19
            let a = path.interpolatedLocation(at: CGFloat(t))
            let b = BSpline.location(of: ours, at: t)
            XCTAssertEqual(Double(a.x), b.x, accuracy: 0.01, "x at t=\(t)")
            XCTAssertEqual(Double(a.y), b.y, accuracy: 0.01, "y at t=\(t)")
            let pp = path.interpolatedPoint(at: CGFloat(t))
            let s = BSpline.sample(of: ours, at: t)
            XCTAssertEqual(Double(pp.size.width), s.w, accuracy: 0.01, "w at t=\(t)")
        }
    }
}
#endif
