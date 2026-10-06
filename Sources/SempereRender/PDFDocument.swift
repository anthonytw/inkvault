import Foundation

/// A page of text and rectangles for `PDFDocument`, laid out in points with
/// the origin at the top left and y growing downward (as everywhere else in
/// SempereRender); the writer converts to PDF's bottom-left origin.
public struct PDFPage: Sendable {
    /// One of the PDF standard 14 fonts, which every reader has built in,
    /// so nothing is embedded.
    public enum Font: String, CaseIterable, Sendable {
        case helvetica = "Helvetica"
        case helveticaBold = "Helvetica-Bold"
        case courier = "Courier"
        case courierBold = "Courier-Bold"

        /// Resource name in the page's font dictionary.
        var resourceName: String {
            switch self {
            case .helvetica: return "F1"
            case .helveticaBold: return "F2"
            case .courier: return "F3"
            case .courierBold: return "F4"
            }
        }

        /// True for the fixed-pitch fonts, whose every glyph is 0.6 em wide.
        public var isMonospaced: Bool { self == .courier || self == .courierBold }
    }

    /// Page width in points.
    public let width: Double
    /// Page height in points.
    public let height: Double
    var content = ""
    var fonts = Set<Font>()

    /// A blank page; US Letter by default.
    public init(width: Double = 612, height: Double = 792) {
        self.width = width
        self.height = height
    }

    /// Fills a rectangle whose top-left corner is `(x, y)`. `gray` 0 is black.
    public mutating func fillRect(x: Double, y: Double, width w: Double, height h: Double, gray: Double = 0) {
        content += "\(fmt(gray)) g\n\(fmt(x)) \(fmt(height - y - h)) \(fmt(w)) \(fmt(h)) re f\n"
    }

    /// Strokes the outline of a rectangle whose top-left corner is `(x, y)`.
    public mutating func strokeRect(x: Double, y: Double, width w: Double, height h: Double, lineWidth: Double = 1,
                                    gray: Double = 0) {
        content += "\(fmt(gray)) G\n\(fmt(lineWidth)) w\n\(fmt(x)) \(fmt(height - y - h)) \(fmt(w)) \(fmt(h)) re S\n"
    }

    /// Draws a horizontal line at `y` from `x1` to `x2`.
    public mutating func hline(y: Double, from x1: Double, to x2: Double, lineWidth: Double = 0.5, gray: Double = 0) {
        content += "\(fmt(gray)) G\n\(fmt(lineWidth)) w\n\(fmt(x1)) \(fmt(height - y)) m \(fmt(x2)) \(fmt(height - y)) l S\n"
    }

    /// Draws one line of text with its baseline at `y`. Characters outside
    /// printable ASCII are drawn as `?` (the standard fonts use WinAnsi).
    public mutating func text(_ s: String, x: Double, y: Double, size: Double, font: Font = .helvetica,
                              gray: Double = 0) {
        fonts.insert(font)
        content += "BT\n\(fmt(gray)) g\n/\(font.resourceName) \(fmt(size)) Tf\n\(fmt(x)) \(fmt(height - y)) Td\n"
            + "\(PDFDocument.literal(s)) Tj\nET\n"
    }

    /// Draws a QR code with its top-left module at `(x, y)`, every module
    /// `module` points square. The caller leaves the quiet zone free.
    public mutating func qrCode(_ code: QRCode, x: Double, y: Double, module: Double) {
        content += "0 g\n"
        for row in 0..<code.size {
            var col = 0
            // One rectangle per horizontal run of dark modules.
            while col < code.size {
                guard code[col, row] else { col += 1; continue }
                let start = col
                while col < code.size && code[col, row] { col += 1 }
                let top = y + Double(row) * module
                content += "\(fmt(x + Double(start) * module)) \(fmt(height - top - module)) "
                    + "\(fmt(Double(col - start) * module)) \(fmt(module)) re\n"
            }
        }
        content += "f\n"
    }

    /// Width of `s` in `font` at `size`, for the monospaced fonts only
    /// (nil otherwise).
    public static func monospacedWidth(_ s: String, size: Double, font: PDFPage.Font = .courier) -> Double? {
        font.isMonospaced ? Double(s.count) * 0.6 * size : nil
    }
}

/// Writes documents of `PDFPage`s: text in the standard 14 fonts and filled
/// or stroked rectangles. Content streams are left uncompressed unless asked,
/// so tests (and curious users) can read them.
public enum PDFDocument {
    /// Serialises `pages` into a PDF 1.4 file.
    public static func render(pages: [PDFPage], title: String? = nil, compress: Bool = false) throws -> Data {
        let pages = pages.isEmpty ? [PDFPage()] : pages
        let usedFonts = PDFPage.Font.allCases.filter { f in pages.contains { $0.fonts.contains(f) } }
        // 1 catalog, 2 pages, 3 info, fonts, then page/content pairs.
        let fontBase = 4
        var fontObj: [PDFPage.Font: Int] = [:]
        for (i, f) in usedFonts.enumerated() { fontObj[f] = fontBase + i }
        let pageBase = fontBase + usedFonts.count

        var objects: [Data] = []
        let kids = pages.indices.map { "\(pageBase + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>".utf8))
        var info = "<< "
        if let title, !title.isEmpty { info += "/Title \(PDFWriter.textString(title)) " }
        info += "/Producer (Sempere) >>"
        objects.append(Data(info.utf8))
        for f in usedFonts {
            objects.append(Data(("<< /Type /Font /Subtype /Type1 /BaseFont /\(f.rawValue) "
                + "/Encoding /WinAnsiEncoding >>").utf8))
        }
        for (i, p) in pages.enumerated() {
            let contentID = pageBase + 2 * i + 1
            var res = "<< "
            let fonts = usedFonts.filter { p.fonts.contains($0) }
            if !fonts.isEmpty {
                res += "/Font << " + fonts.compactMap { f in fontObj[f].map { "/\(f.resourceName) \($0) 0 R" } }
                    .joined(separator: " ") + " >> "
            }
            res += ">>"
            objects.append(Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(fmt(p.width)) \(fmt(p.height))] "
                + "/Resources \(res) /Contents \(contentID) 0 R >>").utf8))
            var stream = Data(p.content.utf8)
            var filter = ""
            if compress {
                stream = try Zlib.compress(stream)
                filter = " /Filter /FlateDecode"
            }
            var body = Data("<< /Length \(stream.count)\(filter) >>\nstream\n".utf8)
            body.append(stream)
            body.append(Data("\nendstream".utf8))
            objects.append(body)
        }

        var out = Data("%PDF-1.4\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefPos = out.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets {
            let digits = String(o)
            xref += String(repeating: "0", count: max(10 - digits.count, 0)) + digits + " 00000 n \n"
        }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 3 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    /// A PDF literal string of printable ASCII; anything else becomes `?`.
    static func literal(_ s: String) -> String {
        var o = "("
        for u in s.unicodeScalars {
            let c = (u.value >= 0x20 && u.value < 0x7F) ? Character(u) : "?"
            if c == "(" || c == ")" || c == "\\" { o.append("\\") }
            o.append(c)
        }
        return o + ")"
    }
}
