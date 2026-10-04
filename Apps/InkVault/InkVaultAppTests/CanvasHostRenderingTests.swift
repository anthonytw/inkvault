import Foundation
import InkVault
import PencilKit
import Testing
import UIKit
@testable import InkVaultApp

/// The canvas as the user sees it: a `PageCanvasHost` in a window, scrolled
/// and zoomed, snapshotted from the screen. Imported notes are one infinite
/// page thousands of points tall with ink anywhere on it; every band must show
/// the ink PencilKit's own renderer draws for the same rect (that renderer is
/// pinned against InkRender in `ImportedStrokeRenderingTests`).
@MainActor
@Suite(.serialized)
struct CanvasHostRenderingTests {
    typealias R = ImportedStrokeRenderingTests

    /// A host showing `strokes` on an infinite page of `height` points in a
    /// `size` window, laid out and fitted to the page width.
    static func host(_ strokes: [Stroke], height: Double, size: CGSize = CGSize(width: 700, height: 900))
        -> (UIWindow, PageCanvasHost) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.canvas.drawing = PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
        host.apply(paper: .blank, pageSize: PageSize(width: 612, height: height, infinite: true, breakHeight: 803.25))
        host.layoutIfNeeded()
        return (window, host)
    }

    /// Scrolls so page y `top` is at the top, waits for PencilKit's tiles, and
    /// returns the on-screen snapshot and the page rect it shows.
    static func snapshot(_ host: PageCanvasHost, top: Double) async throws -> (UIImage, CGRect) {
        let z = host.canvas.zoomScale
        let maxY = max(host.canvas.contentSize.height - host.canvas.bounds.height, 0)
        let y = min(CGFloat(top) * z, maxY)
        host.canvas.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(1500))
        let image = UIGraphicsImageRenderer(bounds: host.canvas.bounds).image { _ in
            host.canvas.drawHierarchy(in: host.canvas.bounds, afterScreenUpdates: true)
        }
        let rect = CGRect(x: host.canvas.contentOffset.x / z, y: host.canvas.contentOffset.y / z,
                          width: host.canvas.bounds.width / z, height: host.canvas.bounds.height / z)
        return (image, rect)
    }

    /// Dark (ink) pixels of an opaque snapshot: luminance below half.
    static func darkPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(UIColor.white.cgColor)
            ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var n = 0
        for i in stride(from: 0, to: buf.count, by: 4) where Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) < 3 * 128 {
            n += 1
        }
        return n
    }

    /// The same page rect drawn by `PKDrawing.image`, at the snapshot's pixel size.
    static func reference(_ strokes: [Stroke], rect: CGRect, pixels: CGSize) -> UIImage {
        let drawing = PKDrawing(strokes: strokes.map(StrokeConversion.pkStroke))
        return drawing.image(from: rect, scale: pixels.width / rect.width)
    }

    /// Canvas and reference agree on how much ink a band shows.
    static func expectBandMatches(_ host: PageCanvasHost, _ strokes: [Stroke], top: Double, _ label: String) async throws {
        let (shot, rect) = try await snapshot(host, top: top)
        let px = CGSize(width: shot.size.width * shot.scale, height: shot.size.height * shot.scale)
        let canvas = darkPixels(shot), ref = darkPixels(reference(strokes, rect: rect, pixels: px))
        #expect(ref > 0, "\(label): reference drew nothing at y \(rect.minY)")
        let ratio = Double(canvas) / Double(max(ref, 1))
        #expect((0.75...1.33).contains(ratio), "\(label): canvas/reference ink \(canvas)/\(ref) at y \(rect.minY)")
    }

    @Test func tallImportedPageShowsInkFarBelowTheFirstScreen() async throws {
        let height = 24_000.0
        let bands = [80.0, 6_000, 12_500, 23_200]
        let strokes = bands.flatMap { R.importedPage(top: $0 / R.k) }
        let (window, host) = Self.host(strokes, height: height)
        defer { window.isHidden = true }
        let z = host.canvas.zoomScale
        // The whole page scrolls, so the last ink can be reached.
        #expect(host.canvas.contentSize.height >= CGFloat(height) * z - 0.5)
        #expect(host.canvas.drawing.strokes.count == strokes.count)
        for top in bands {
            try await Self.expectBandMatches(host, strokes, top: top - 40, "band \(top)")
        }
    }

    @Test func zoomedInCanvasShowsTheSameInk() async throws {
        let strokes = R.importedPage(top: 9_000 / R.k)
        let (window, host) = Self.host(strokes, height: 10_000)
        defer { window.isHidden = true }
        host.canvas.zoomScale = host.canvas.minimumZoomScale * 2.5
        host.zoomChanged()
        try await Self.expectBandMatches(host, strokes, top: 9_000 - 20, "zoom 2.5x")
    }

    @Test func everyInkShowsOnTheCanvas() async throws {
        var strokes: [Stroke] = []
        for (i, tool) in InkTool.allCases.enumerated() {
            let w = tool == .marker ? 14.0 : 3.0
            let y = 5_000 + Double(i) * 60
            let points = (0..<60).map { j in
                StrokePoint(x: 60 + Double(j) * 8, y: y + 6 * sin(Double(j) / 4), t: Double(j) / 120,
                            w: w, h: w, o: 1, f: 0.5, az: 0, al: .pi / 2)
            }
            // Dark colours so every ink passes the darkness threshold.
            strokes.append(Stroke(ink: Ink(tool: tool, color: InkVault.Color(r: 0x10, g: 0x10, b: 0x60, a: 0xFF),
                                           width: w), points: points))
        }
        let (window, host) = Self.host(strokes, height: 6_000)
        defer { window.isHidden = true }
        for (i, tool) in InkTool.allCases.enumerated() {
            let y = 5_000 + Double(i) * 60
            let (shot, rect) = try await Self.snapshot(host, top: y - 25)
            // Only this stroke's band: the top 50 points of the screen.
            let band = CGRect(x: 0, y: 0, width: shot.size.width * shot.scale,
                              height: 50 * host.canvas.zoomScale * shot.scale)
            let crop = try #require(shot.cgImage?.cropping(to: band))
            #expect(Self.darkPixels(UIImage(cgImage: crop)) > 0, "\(tool) drew nothing at y \(rect.minY)")
        }
    }

    @Test func thousandsOfStrokesAllLoadAndTheLastOnesShow() async throws {
        var strokes: [Stroke] = []
        for i in 0..<4_000 {
            let x = 30 + Double(i % 40) * 13.5, y = 40 + Double(i / 40) * 30
            strokes.append(R.importedPen(x: x / R.k - 18.8, y: y / R.k, glyphs: 1, base: 1.4))
        }
        let height = 40 + 100 * 30 + 60.0
        let (window, host) = Self.host(strokes, height: height)
        defer { window.isHidden = true }
        #expect(host.canvas.drawing.strokes.count == strokes.count)
        try await Self.expectBandMatches(host, strokes, top: 0, "first screen")
        try await Self.expectBandMatches(host, strokes, top: height - 800, "last screen")
    }
}
