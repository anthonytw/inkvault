import Foundation
import Sempere

/// An image of one page's ink for a handwriting recogniser: the strokes drawn
/// black on white (markers left out, they would cover text), cropped to the
/// ink with a margin, at up to 2x and within `maxPixels`. The pure-Swift
/// counterpart of the app's PencilKit rendering, used by `sempere recognize`.
public enum RecognitionImage {
    /// Margin around the ink, in points.
    public static let margin = 24.0
    /// Largest image, in pixels, and its longest side.
    public static let maxPixels = 36_000_000.0
    public static let maxSide = 8000.0

    public struct Rendered: Sendable {
        /// A PNG, black ink on white.
        public var png: Data
        /// The page rectangle the image shows (page points, origin top left).
        public var region: Recognition.Box
    }

    /// The image of `strokes`, or nil when there is nothing to read (no
    /// strokes, or only markers): the caller stores empty text for such a page.
    ///
    /// - Throws: `RenderError` when the page cannot be drawn (non-finite data,
    ///   an extent beyond `RenderLimits.maxExtent`), so the caller never stores
    ///   "nothing legible" for a page that was not read.
    public static func render(strokes: [Stroke]) throws -> Rendered? {
        let drawable = strokes.filter { $0.ink.tool != .marker && !$0.points.isEmpty }
        guard !drawable.isEmpty else { return nil }
        guard let bounds = inkBounds(drawable) else { throw RenderError.invalidGeometry }
        let region = Recognition.Box(x: bounds.minX - margin, y: bounds.minY - margin,
                                     w: bounds.maxX - bounds.minX + 2 * margin, h: bounds.maxY - bounds.minY + 2 * margin)
        let scale = min(2, (maxPixels / (region.w * region.h)).squareRoot(), maxSide / max(region.w, region.h))
        guard scale > 0, scale.isFinite else { throw RenderError.extentTooLarge(max(region.w, region.h)) }
        let moved = drawable.map { s -> Stroke in
            var s = s
            s.ink.color = .black
            var t = s.transform ?? .identity
            t.tx -= region.x
            t.ty -= region.y
            s.transform = t
            return s
        }
        var page = Page(order: "a")
        page.strokes = moved
        let meta = NoteMeta(created: Date(timeIntervalSince1970: 0), paper: .blank,
                            pageSize: PageSize(width: region.w, height: region.h))
        let pngs = try PNGWriter.render(page: page, meta: meta, options: RenderOptions(paper: true, compress: false),
                                        png: PNGOptions(scale: scale, maxPixels: Int(maxPixels)))
        guard let png = pngs.first, pngs.count == 1 else { return nil }
        return Rendered(png: png, region: region)
    }

    /// Bounds of the strokes' points (transformed, padded by half the nib), or
    /// nil when there are none or they are not finite.
    static func inkBounds(_ strokes: [Stroke]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for s in strokes {
            let t = s.transform ?? .identity
            for p in s.points {
                let x = t.a * p.x + t.c * p.y + t.tx, y = t.b * p.x + t.d * p.y + t.ty
                let pad = max(p.w, p.h, s.ink.width) / 2
                minX = min(minX, x - pad); maxX = max(maxX, x + pad)
                minY = min(minY, y - pad); maxY = max(maxY, y + pad)
            }
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite, maxX > minX, maxY > minY else { return nil }
        return (minX, minY, maxX, maxY)
    }
}

#if canImport(Vision)
import Vision

/// The Vision call, shared by the app and `sempere recognize` (Apple
/// platforms only).
public enum VisionRecognition {
    /// `vision-<OS major.minor>` (format.md §5.5 `engine`).
    public static var engine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "vision-\(v.majorVersion).\(v.minorVersion)"
    }

    /// Recognised lines of the image `handler` holds, with word boxes in page
    /// points; `region` is the page rectangle the image shows.
    public static func lines(performing handler: VNImageRequestHandler, region: Recognition.Box) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            let lineBox = pageBox(observation.boundingBox, region)
            var words: [Recognition.Word] = []
            var failed = false
            var i = text.startIndex
            while i < text.endIndex {
                if text[i].isWhitespace { i = text.index(after: i); continue }
                var j = i
                while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
                if let rect = try? candidate.boundingBox(for: i..<j) {
                    words.append(.init(text: String(text[i..<j]), box: pageBox(rect.boundingBox, region)))
                } else {
                    failed = true
                }
                i = j
            }
            // Word boxes are best effort: without them the line's box is shared out.
            if failed || words.isEmpty { words = RecognitionLayout.distribute(text: text, in: lineBox) }
            return RecognizedLine(text: text, words: words)
        }
    }

    /// `lines(performing:region:)` on the PNG `data`.
    public static func lines(inPNG data: Data, region: Recognition.Box) throws -> [RecognizedLine] {
        try lines(performing: VNImageRequestHandler(data: data, options: [:]), region: region)
    }

    private static func pageBox(_ n: CGRect, _ region: Recognition.Box) -> Recognition.Box {
        RecognitionLayout.pageBox(normalized: .init(x: Double(n.minX), y: Double(n.minY), w: Double(n.width), h: Double(n.height)),
                                  region: region)
    }
}
#endif
