import CoreGraphics
import Foundation
import ImageIO
import Sempere
import SempereRender
import UIKit

/// How sharp the item layer draws: pixels per page point as a power of two
/// at or above what the screen shows (zoom × screen scale), so zooming in
/// redraws an item only when it crosses a step. Pure, tested.
enum ItemScale {
    static let minimum = 1.0
    static let maximum = 16.0

    static func bucket(zoom: Double, screenScale: Double) -> Double {
        let want = zoom * screenScale
        guard want.isFinite, want > 0 else { return minimum }
        let step = pow(2, (log2(want)).rounded(.up))
        return min(max(step, minimum), maximum)
    }
}

/// What the item layer draws for one item.
enum ItemPicture {
    /// The item's pixels covering `bounds` (page points, the rotated frame's bounds).
    case image(CGImage, bounds: Rect)
    /// A grey frame with diagonals (format.md §8.5.2), and why.
    case placeholder(Reason)

    enum Reason: Equatable {
        /// The attachment is being fetched (downloaded or decrypted).
        case loading
        /// It cannot be drawn (missing, unreadable, unknown kind).
        case unavailable(String)
    }
}

/// Everything a picture depends on: when it changes, the item is drawn again.
struct ItemRenderKey: Hashable, Sendable {
    /// The item without its snapshot-only fields.
    var item: Item
    var scale: Double
    /// Background items are filled with the paper (format.md §8.2.3).
    var paper: Paper?

    init(_ item: Item, scale: Double, paper: Paper) {
        var plain = item
        plain.origin = nil
        plain.clocks = nil
        self.item = plain
        self.scale = scale
        self.paper = item.layer.isBackground ? paper : nil
    }
}

/// Draws items off the main actor for the item layer (`ItemLayerView`):
/// images and PDF pages through SempereRender's composition (`ItemRaster`,
/// as exports draw them) from the vault's `BlobCache`; text natively until
/// the app has its CoreText `TextShaper` (task E2).
enum ItemRendering {
    /// Largest picture of one item, in pixels.
    static let maxPixels = 6_000_000

    /// Draws one item. Pixels are made off the main actor; the text of a
    /// text box is drawn here (UIKit text drawing stays on the main actor).
    @MainActor
    static func render(_ key: ItemRenderKey, note: UUID, cache: BlobCache?) async -> ItemPicture {
        let item = key.item
        if item.kind == .text, let text = item.text {
            return TextItemImage.render(text, frame: item.frame, rotation: item.rotation, scale: key.scale)
                .map { ItemPicture.image($0, bounds: ItemFrames.bounds(item.frame, rotation: item.rotation)) }
                ?? .placeholder(.unavailable("text cannot be drawn"))
        }
        var files: [String: URL] = [:]
        let blobs = item.blob.map { [$0] } ?? []
        if let cache {
            for ref in blobs {
                do { files[ref.sha256] = try await cache.acquire(note: note, ref: ref) } catch {
                    for held in blobs where files[held.sha256] != nil { await cache.release(note: note, ref: held) }
                    // Not here yet (iCloud), or the cache went away: still loading, tried again later.
                    return .placeholder(isTransient(error) ? .loading : .unavailable("\(error)"))
                }
            }
        }
        let source: CachedBlobSource? = cache == nil ? nil : CachedBlobSource(files: files)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            let options = RenderOptions(paper: false, blobs: source, pdfRasterizer: PDFKitRasterizer(),
                                        imageDecoder: ImageIODecoder())
            do {
                let r = try ItemRaster.render(item, scale: key.scale, maxPixels: ItemRendering.maxPixels, paper: key.paper, options: options)
                if let reason = r.placeholder { return .failed(reason.description) }
                return .pixels(r.image, r.bounds)
            } catch {
                return .failed("\(error)")
            }
        }.value
        if let cache { for ref in blobs where files[ref.sha256] != nil { await cache.release(note: note, ref: ref) } }
        switch outcome {
        case .pixels(let image, let bounds):
            guard let cg = cgImage(image) else { return .placeholder(.unavailable("cannot be drawn")) }
            return .image(cg, bounds: bounds)
        case .failed(let why):
            return .placeholder(.unavailable(why))
        }
    }

    /// Whether fetching a blob failed for now only: iCloud has not delivered
    /// it (or stalled), the cache was cleared, or the draw was cancelled. The
    /// item layer tries such an item again instead of keeping a placeholder.
    nonisolated static func isTransient(_ error: any Error) -> Bool {
        error is CloudVault.CloudError || error is CancellationError || (error as? BlobCache.CacheError) == .cleared
    }

    /// What the off-main part hands back.
    private enum Outcome: Sendable {
        case pixels(RGBAImage, Rect)
        case failed(String)
    }

    /// A `CGImage` of straight-alpha RGBA pixels.
    static func cgImage(_ image: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Decodes what SempereRender cannot (HEIC) with ImageIO, for drawing.
struct ImageIODecoder: ImageDecoding {
    func decode(_ data: Data, type: String, maxPixels: Int) throws -> RGBAImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= maxPixels / h,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // Stored (unoriented) pixels: the item's `orientation` turns them.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = context.data else { return nil }
        var px = [UInt8](UnsafeRawBufferPointer(start: raw, count: w * h * 4))
        // Premultiplied → straight alpha.
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 && px[i + 3] != 255 {
            let a = Double(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min(255, (Double(px[i + c]) * 255 / a).rounded())) }
        }
        return try RGBAImage(width: w, height: h, pixels: px)
    }
}

/// Text boxes drawn with UIKit until task E2 brings the CoreText layout of
/// format.md §8.5.3 (stored breaks, fixed metrics). Runs keep their bold,
/// italic, underline, strike-through, colour and size.
enum TextItemImage {
    /// The attributed string for a text box (pure mapping, tested).
    @MainActor
    static func attributed(_ content: TextContent) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        switch content.align?.rawValue {
        case "center": paragraph.alignment = .center
        case "end": paragraph.alignment = content.dir?.rawValue == "rtl" ? .left : .right
        case "left": paragraph.alignment = .left
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = content.dir?.rawValue == "rtl" ? .right : .left
        }
        for run in content.runs {
            let size = CGFloat(run.size ?? content.size)
            var font = UIFont.systemFont(ofSize: size)
            var descriptor = font.fontDescriptor
            switch content.font.rawValue {
            case "serif": descriptor = descriptor.withDesign(.serif) ?? descriptor
            case "mono": descriptor = descriptor.withDesign(.monospaced) ?? descriptor
            default: break
            }
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.b { traits.insert(.traitBold) }
            if run.i { traits.insert(.traitItalic) }
            descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
            font = UIFont(descriptor: descriptor, size: size)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph,
                                                             .foregroundColor: (run.color ?? content.color).uiColor]
            if run.u { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.s { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run.t, attributes: attributes))
        }
        return out
    }

    /// The text box drawn into the bounds of its rotated frame at `scale`.
    @MainActor
    static func render(_ content: TextContent, frame: Rect, rotation: Double?, scale: Double) -> CGImage? {
        let bounds = ItemFrames.bounds(frame, rotation: rotation)
        let pixels = bounds.w * bounds.h * scale * scale
        let s = pixels > Double(ItemRendering.maxPixels) ? (Double(ItemRendering.maxPixels) / (bounds.w * bounds.h)).squareRoot() : scale
        guard bounds.w > 0, bounds.h > 0, s.isFinite, s > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(s)
        format.opaque = false
        let text = attributed(content)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: bounds.w, height: bounds.h), format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: CGFloat(frame.x + frame.w / 2 - bounds.x), y: CGFloat(frame.y + frame.h / 2 - bounds.y))
            cg.rotate(by: CGFloat((rotation ?? 0) * .pi / 180))
            let local = CGRect(x: -frame.w / 2, y: -frame.h / 2, width: frame.w, height: frame.h)
            cg.clip(to: local)
            text.draw(with: local, options: [.usesLineFragmentOrigin], context: nil)
        }
        return image.cgImage
    }
}
