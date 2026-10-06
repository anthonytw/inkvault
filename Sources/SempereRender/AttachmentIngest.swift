import Foundation
import Sempere
import SemperePDF

// What a writer needs to know about a file before it becomes an attachment
// (docs/attachments.md §7, §8; format.md §8.2.5, §8.2.6): shared by the CLI,
// and by the app for the formats it does not convert itself.

/// Why a file cannot become an image attachment as it is.
public enum ImageIngestError: Error, Equatable, Sendable {
    /// HEIC (or HEIF): stored only by writers that can decode it (the app); convert to JPEG first.
    case heic
    /// Not JPEG or PNG (WebP, GIF, TIFF, ...): convert to JPEG or PNG first.
    case unsupportedFormat
    /// JPEG or PNG, but not readable as an image.
    case unreadable(ImageError)
}

extension ImageIngestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .heic: return "HEIC images are not supported here: convert the photo to JPEG first (the app does it when adding)"
        case .unsupportedFormat: return "only JPEG and PNG images can be attached: convert the file first"
        case .unreadable(let e): return "\(e)"
        }
    }
}

/// An image ready to be stored as a blob and placed as an `image` item.
public struct PreparedImage: Hashable, Sendable {
    /// The bytes to store (metadata removed unless it was kept).
    public var data: Data
    /// `image/jpeg` or `image/png`.
    public var mediaType: String
    /// `[w, h]` in pixels after orientation (format.md §8.2.5).
    public var pixelSize: Size
    /// EXIF orientation 2…8; nil is 1.
    public var orientation: Int?
}

public enum ImageIngest {
    /// Reads the size and orientation of a JPEG or PNG, checks that it decodes
    /// and removes its location and camera metadata (every APPn segment except
    /// JFIF, ICC and Adobe, and comments; ancillary PNG chunks other than the
    /// colour ones) unless `keepMetadata`. The EXIF orientation is read before
    /// it is removed and returned as the item's `orientation` field, so a
    /// stripped JPEG still shows upright.
    ///
    /// - Throws: `ImageIngestError`.
    public static func prepare(_ data: Data, keepMetadata: Bool = false,
                               maxPixels: Int = ImageLimits.maxPixels) throws -> PreparedImage {
        let head = [UInt8](data.prefix(12))
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8 {
            return try jpeg(data, keepMetadata: keepMetadata, maxPixels: maxPixels)
        }
        if head.count >= 8, Array(head[0..<8]) == PNG.signature {
            return try png(data, keepMetadata: keepMetadata, maxPixels: maxPixels)
        }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8),
           ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(String(decoding: head[8..<12], as: UTF8.self)) {
            throw ImageIngestError.heic
        }
        throw ImageIngestError.unsupportedFormat
    }

    private static func jpeg(_ data: Data, keepMetadata: Bool, maxPixels: Int) throws -> PreparedImage {
        do {
            let info = try JPEG.info(data)
            try ImageLimits.check(width: info.width, height: info.height, inputBytes: data.count, maxPixels: maxPixels)
            // A scaled decode reads every entropy-coded block but allocates an eighth of the pixels.
            _ = try JPEG.decode(data, scale: 8, maxPixels: maxPixels)
            let orientation = exifOrientation(data)
            let swapped = orientation >= 5
            let stored = keepMetadata ? data : try JPEG.stripMetadata(data)
            return PreparedImage(data: stored, mediaType: "image/jpeg",
                                 pixelSize: Size(w: Double(swapped ? info.height : info.width),
                                                 h: Double(swapped ? info.width : info.height)),
                                 orientation: orientation == 1 ? nil : orientation)
        } catch let e as ImageError {
            throw ImageIngestError.unreadable(e)
        }
    }

    private static func png(_ data: Data, keepMetadata: Bool, maxPixels: Int) throws -> PreparedImage {
        do {
            let image = try PNG.decode(data, maxPixels: maxPixels)
            let stored = keepMetadata ? data : try PNG.stripMetadata(data)
            return PreparedImage(data: stored, mediaType: "image/png",
                                 pixelSize: Size(w: Double(image.width), h: Double(image.height)), orientation: nil)
        } catch let e as ImageError {
            throw ImageIngestError.unreadable(e)
        }
    }

    /// The Exif orientation (1…8) of a JPEG, 1 when it has none or it is not valid.
    static func exifOrientation(_ data: Data) -> Int {
        let d = [UInt8](data)
        var pos = 2
        while pos + 4 <= d.count {
            guard d[pos] == 0xFF else { return 1 }
            let code = d[pos + 1]
            if code == 0xFF { pos += 1; continue }
            if code == 0xDA || code == 0xD9 { return 1 }   // image data begins: no Exif
            if (0xD0...0xD8).contains(code) || code == 0x01 { pos += 2; continue }
            let length = Int(d[pos + 2]) << 8 | Int(d[pos + 3])
            guard length >= 2, pos + 2 + length <= d.count else { return 1 }
            if code == 0xE1, length >= 2 + 6 + 8, Array(d[pos + 4..<pos + 10]) == Array("Exif\0\0".utf8) {
                return tiffOrientation(d, tiff: pos + 10, end: pos + 2 + length)
            }
            pos += 2 + length
        }
        return 1
    }

    /// Tag 0x0112 of the first IFD of the TIFF structure at `tiff`.
    private static func tiffOrientation(_ d: [UInt8], tiff: Int, end: Int) -> Int {
        guard tiff + 8 <= end else { return 1 }
        let little: Bool
        switch (d[tiff], d[tiff + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return 1
        }
        func u16(_ i: Int) -> Int { little ? Int(d[i]) | Int(d[i + 1]) << 8 : Int(d[i]) << 8 | Int(d[i + 1]) }
        func u32(_ i: Int) -> Int {
            little ? Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24
                : Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
        }
        guard u16(tiff + 2) == 42 else { return 1 }
        let ifd = tiff + u32(tiff + 4)
        guard ifd >= tiff + 8, ifd + 2 <= end else { return 1 }
        let count = u16(ifd)
        for i in 0..<min(count, 512) {
            let e = ifd + 2 + 12 * i
            guard e + 12 <= end else { return 1 }
            if u16(e) == 0x0112 {
                let value = u16(e + 8)
                return (1...8).contains(value) && u16(e + 2) == 3 ? value : 1
            }
        }
        return 1
    }
}

/// Why a PDF cannot become a background or figure.
public enum PDFIngestError: Error, Equatable, Sendable {
    /// Not readable, encrypted, or beyond a reader limit.
    case unreadable(PDFError)
    /// The PDF has no pages.
    case noPages
    /// More than `NoteOps.Limits.pdfPages`.
    case tooManyPages(Int)
    /// A page whose size is empty or beyond the extent limit (1-based number).
    case unusablePage(Int)
    /// A page number outside the PDF (1-based).
    case noSuchPage(Int, of: Int)
}

extension PDFIngestError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unreadable(let e): return e.errorDescription ?? "\(e)"
        case .noPages: return "the PDF has no pages"
        case .tooManyPages(let n): return "the PDF has \(n) pages; at most \(NoteOps.Limits.pdfPages) are accepted"
        case .unusablePage(let n): return "page \(n) of the PDF has no usable size"
        case .noSuchPage(let n, let total): return "the PDF has no page \(n) (it has \(total))"
        }
    }
}

/// A PDF's pages as the format sees them (format.md §8.2.6).
public struct PDFSummary: Hashable, Sendable {
    /// Every page: its 0-based index and effective size (CropBox ∩ MediaBox, turned by `/Rotate`).
    public var pages: [PDFPageRef]
    /// Whether the reader had to rebuild a damaged cross-reference table.
    public var repaired: Bool

    /// The pages a 1-based page list selects, in the order given.
    public func pages(numbered numbers: [Int]) throws -> [PDFPageRef] {
        try numbers.map { n in
            guard n >= 1, n <= pages.count else { throw PDFIngestError.noSuchPage(n, of: pages.count) }
            return pages[n - 1]
        }
    }
}

public enum PDFIngest {
    /// Reads the page sizes of an unencrypted PDF. Cost: linear in the page
    /// tree; no page content is decoded.
    ///
    /// - Throws: `PDFIngestError`.
    public static func inspect(_ data: Data) throws -> PDFSummary {
        let file: PDFFile
        do { file = try PDFFile(data: data) } catch let e as PDFError { throw PDFIngestError.unreadable(e) }
        let count = file.pageCount
        guard count > 0 else { throw PDFIngestError.noPages }
        guard count <= NoteOps.Limits.pdfPages else { throw PDFIngestError.tooManyPages(count) }
        var pages: [PDFPageRef] = []
        pages.reserveCapacity(count)
        for i in 0..<count {
            let info: PDFPageInfo
            do { info = try file.page(i) } catch { throw PDFIngestError.unusablePage(i + 1) }
            let size = Size(w: InkJSON.round3(info.effectiveWidth), h: InkJSON.round3(info.effectiveHeight))
            guard size.isPositive, size.w <= NoteOps.Limits.extent, size.h <= NoteOps.Limits.extent else {
                throw PDFIngestError.unusablePage(i + 1)
            }
            pages.append(PDFPageRef(index: i, size: size))
        }
        return PDFSummary(pages: pages, repaired: file.repaired)
    }
}
