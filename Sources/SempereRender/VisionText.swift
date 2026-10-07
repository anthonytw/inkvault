#if canImport(Vision)
import Foundation
import Sempere
import Vision

/// Handwriting recognition with Apple's Vision (`VNRecognizeTextRequest`),
/// on device. One mapping from Vision's observations to the format's lines
/// and word boxes (format.md §5.5), used by the app and by `sempere
/// recognize` on macOS.
public enum VisionText {
    /// `vision-<OS major.minor>` (format.md §5.5 `engine`).
    public static var engine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "vision-\(v.majorVersion).\(v.minorVersion)"
    }

    /// Recognised lines of the image `handler` holds, with word boxes in page
    /// points. `region` is the page rectangle the image shows.
    public static func lines(_ handler: VNImageRequestHandler, region: Recognition.Box) throws -> [RecognizedLine] {
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

    /// The recognition of one page's `strokes`, drawn by `RecognitionImage`
    /// (pure Swift; the app draws with PencilKit instead). `basis` is left nil:
    /// the caller sets it from the stroke ids it read. Nil when no stroke is
    /// readable.
    public static func recognize(strokes: [Stroke]) throws -> Recognition? {
        guard let (png, region) = try RecognitionImage.render(strokes: strokes) else { return nil }
        let lines = try lines(VNImageRequestHandler(data: png, options: [:]), region: region)
        return RecognitionLayout.assemble(engine: engine, lines: lines, basis: nil)
    }

    private static func pageBox(_ n: CGRect, _ region: Recognition.Box) -> Recognition.Box {
        RecognitionLayout.pageBox(normalized: .init(x: Double(n.minX), y: Double(n.minY), w: Double(n.width),
                                                    h: Double(n.height)),
                                  region: region)
    }
}
#endif
