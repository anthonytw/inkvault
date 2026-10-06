import CoreGraphics
import Foundation
import PencilKit
import Sempere
import SempereRender
import UIKit
import Vision

/// Reads the handwriting of one page. Implementations run off the main
/// actor; tests substitute a fake.
protocol PageRecognizing: Sendable {
    /// The text of `strokes` (one page's live strokes). `basis` is left nil:
    /// the caller sets it from the stroke ids it passed.
    func recognize(strokes: [Stroke]) async throws -> Recognition
}

/// Why a page could not be read.
enum RecognitionFailure: Error, CustomStringConvertible {
    /// The page's ink could not be drawn into an image (for example, out of memory).
    case cannotRender

    var description: String { "The page could not be drawn for reading." }
}

/// Whether the app recognises handwriting on its own (default on). It is
/// on-device only: Vision runs here and nothing leaves the device.
enum RecognitionPreference {
    static let key = "Sempere.recognizeHandwriting"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Recognition with Vision's `VNRecognizeTextRequest` on an image of the
/// page's ink: the strokes are drawn black on white (markers left out, they
/// would cover text), cropped to the ink, at up to 2x and no more than
/// `maxPixels`.
struct VisionPageRecognizer: PageRecognizing {
    /// Margin around the ink, in points.
    static let margin = 24.0
    /// Largest image, in pixels, and its longest side.
    static let maxPixels = 36_000_000.0
    static let maxSide = 8000.0

    /// `vision-<iPadOS major.minor>` (format.md §5.5 `engine`).
    static var engine: String { VisionRecognition.engine }

    func recognize(strokes: [Stroke]) async throws -> Recognition {
        try await Task.detached(priority: .utility) { try Self.recognizeNow(strokes) }.value
    }

    static func recognizeNow(_ strokes: [Stroke]) throws -> Recognition {
        let empty = Recognition(engine: engine, text: "")
        let drawable = strokes.filter { $0.ink.tool != .marker && !$0.points.isEmpty }.map { s -> PKStroke in
            var black = s
            black.ink.color = .black
            return StrokeConversion.pkStroke(black)
        }
        let drawing = PKDrawing(strokes: drawable)
        let bounds = drawing.bounds
        guard !drawable.isEmpty, !bounds.isNull, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite
        else { return empty }
        let region = bounds.insetBy(dx: -margin, dy: -margin)
        let scale = min(2, (maxPixels / (region.width * region.height)).squareRoot(),
                        maxSide / max(region.width, region.height))
        // A page whose ink cannot be drawn is an error, not "nothing legible": an
        // empty result would be stored as current and never read again.
        guard scale > 0, scale.isFinite, let image = render(drawing, region: region, scale: scale) else {
            throw RecognitionFailure.cannotRender
        }
        let lines = try VisionText.lines(in: image, region: .init(x: Double(region.minX), y: Double(region.minY),
                                                                  w: Double(region.width), h: Double(region.height)))
        return RecognitionLayout.assemble(engine: engine, lines: lines, basis: nil)
    }

    /// The ink on white, as the light appearance draws it.
    static func render(_ drawing: PKDrawing, region: CGRect, scale: CGFloat) -> CGImage? {
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: region, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: region.size)
        return UIGraphicsImageRenderer(size: region.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            ink?.draw(in: bounds)
        }.cgImage
    }
}

/// The Vision call, apart from the page rendering so a test can read a
/// printed image.
enum VisionText {
    /// Recognised lines of `image`, with word boxes in page points. `region`
    /// is the page rectangle the image shows. The Vision call itself is shared
    /// with `sempere recognize` (`VisionRecognition`).
    static func lines(in image: CGImage, region: Recognition.Box) throws -> [RecognizedLine] {
        try VisionRecognition.lines(performing: VNImageRequestHandler(cgImage: image, options: [:]), region: region)
    }
}
