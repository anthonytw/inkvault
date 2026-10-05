import Foundation
import InkVault

/// A parsed Notability `.note` package (see `docs/import-notability.md`).
///
/// Everything the importer maps, plus counts of what it cannot map, for the
/// report. Lengths are Notability document units: the page is
/// `paper.width` units wide (716.8 for an iPad note).
public struct NotabilityNote: Hashable, Sendable {
    /// From `metadata.plist`, falling back to `Session.plist`.
    public struct Metadata: Hashable, Sendable {
        /// Note title (`noteName`).
        public var name: String
        /// Notability subject (`noteSubject`); nil for the "unsorted" pseudo-subject.
        public var subject: String?
        /// Tags (`noteTags`, split on commas and newlines).
        public var tags: [String]
        /// `noteCreationDateKey`, else the session's `creationDate`.
        public var created: Date?
        /// `noteModifiedDateKey`.
        public var modified: Date?
        /// `uuidKey`: Notability's stable note id.
        public var uuid: String?
        /// `notePackagePath`.
        public var packagePath: String?

        public init(name: String, subject: String? = nil, tags: [String] = [], created: Date? = nil,
                    modified: Date? = nil, uuid: String? = nil, packagePath: String? = nil) {
            self.name = name; self.subject = subject; self.tags = tags; self.created = created
            self.modified = modified; self.uuid = uuid; self.packagePath = packagePath
        }
    }

    /// Page geometry and paper style, resolved to document units.
    public struct Paper: Hashable, Sendable {
        /// Document width: `lockedWidth:<w>:<device>`, else the reflow
        /// state's page width, else `NotabilityNote.defaultWidth` (widened to
        /// fit the strokes).
        public var width: Double
        /// Height of one Notability page, i.e. the distance from one page's
        /// top to the next: `width` × the page aspect (from a `custom:<w/h>`
        /// paper size, else the largest thumbnail, else 21/16). On a note whose
        /// pages are PDF pages it is that product rounded up to a whole unit
        /// (measured: 716.8 × 0.75 = 537.6 pages repeat every 538).
        public var pageHeight: Double
        /// Added to every ink and recognition x to place it on the page
        /// (`width × horizontalInsetFraction`).
        public var insetX: Double { width * NotabilityNote.horizontalInsetFraction }
        /// Paper pattern.
        public var kind: PaperKind
        /// Line, dot or grid pitch in document units; nil for blank paper.
        public var spacing: Double?
        /// `paperIdentifier`, e.g. `Legacy:13`.
        public var identifier: String?
        /// `paperSize`, e.g. `letter` or `custom:0.7619`.
        public var size: String?
        /// `paperSizingBehavior`, e.g. `lockedWidth:716.8:iPad` or `deviceBasedWidth`.
        public var sizingBehavior: String?
        /// `lineStyle2` (newer) or nil.
        public var lineStyle2: String?
        /// `lineStyle` / root `paperLineStyle` (older integer code) or nil.
        public var lineStyle: Int?

        public init(width: Double, pageHeight: Double, kind: PaperKind, spacing: Double?, identifier: String? = nil,
                    size: String? = nil, sizingBehavior: String? = nil, lineStyle2: String? = nil, lineStyle: Int? = nil) {
            self.width = width; self.pageHeight = pageHeight; self.kind = kind; self.spacing = spacing
            self.identifier = identifier; self.size = size; self.sizingBehavior = sizingBehavior
            self.lineStyle2 = lineStyle2; self.lineStyle = lineStyle
        }
    }

    /// A 2-D point in document units.
    public struct Point: Hashable, Sendable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// One curve of the handwriting overlay (`InkedSpatialHash`).
    public struct Curve: Hashable, Sendable {
        /// Piecewise cubic Bézier control polygon: on-curve, control,
        /// control, on-curve, … (`3k + 1` points for `k` segments).
        public var points: [Point]
        /// Width multiplier per on-curve point (`k + 1` values).
        public var fractionalWidths: [Double]
        /// Pencil force per on-curve point, when recorded.
        public var forces: [Double]?
        /// Altitude (radians) per on-curve point, when recorded.
        public var altitudes: [Double]?
        /// Azimuth (radians, `atan2` of the stored unit vector) per on-curve point, when recorded.
        public var azimuths: [Double]?
        /// Base width in document units (`curveswidth`).
        public var width: Double
        /// Colour, stored RGBA.
        public var color: Color
        /// `curvesstyles`: 3 pen, 4 highlighter (other values unseen).
        public var style: Int
        /// Listed in `dashStyles` (drawn dashed in Notability).
        public var dashed: Bool
        /// `curveUUIDs` entry, when present.
        public var uuid: UUID?

        /// True for the highlighter style.
        public var isHighlighter: Bool { style == NotabilityNote.highlighterStyle }

        public init(points: [Point], fractionalWidths: [Double], forces: [Double]? = nil, altitudes: [Double]? = nil,
                    azimuths: [Double]? = nil, width: Double, color: Color, style: Int, dashed: Bool = false,
                    uuid: UUID? = nil) {
            self.points = points; self.fractionalWidths = fractionalWidths; self.forces = forces
            self.altitudes = altitudes; self.azimuths = azimuths; self.width = width; self.color = color
            self.style = style; self.dashed = dashed; self.uuid = uuid
        }
    }

    /// Notability's own handwriting recognition for one page (`HandwritingIndex/index.plist`).
    public struct RecognizedPage: Hashable, Sendable {
        /// Recognised text, lines separated by `\n`.
        public var text: String
        /// Offset of the character rectangles within the page (`pageContentOrigin`).
        public var origin: Point
        /// One rectangle per UTF-16 unit of `text`, relative to `origin`; nil
        /// for whitespace (stored as infinities).
        public var characterBoxes: [Recognition.Box?]

        public init(text: String, origin: Point, characterBoxes: [Recognition.Box?]) {
            self.text = text; self.origin = origin; self.characterBoxes = characterBoxes
        }
    }

    /// Note metadata.
    public var metadata: Metadata
    /// Page geometry and paper.
    public var paper: Paper
    /// Handwriting, in drawing order.
    public var curves: [Curve]
    /// Typed text (`richText.attributedString`), kept for the report only.
    public var typedText: String
    /// Recognised handwriting by 1-based Notability page number.
    public var recognition: [Int: RecognizedPage]
    /// `richText.pdfFiles` count (imported PDFs the ink sits on).
    public var pdfCount: Int
    /// Pages of the note that are PDF pages (`richText.pageLayoutArray`
    /// entries naming a PDF file); 0 for a note on paper.
    public var pdfPageCount: Int
    /// `richText.mediaObjects` count (images and other media).
    public var mediaCount: Int
    /// Audio recordings listed in `Recordings/library.plist`.
    public var recordingCount: Int
    /// `NBNoteTakingSessionBundleVersionNumberKey`, e.g. `14.2.6`.
    public var bundleVersion: String?
    /// `sessionFormatVersion` (5–9 seen).
    public var formatVersion: Int?

    /// Largest accepted coordinate magnitude, document units (about 1000
    /// pages); anything beyond is treated as corrupt.
    public static let maxCoordinate = 1_000_000.0
    /// Handwriting-index pages beyond this number are ignored (a corrupt key
    /// must not place recognised words 10¹⁸ pages down).
    public static let maxRecognizedPage = 100_000
    /// The highlighter value of `curvesstyles`.
    public static let highlighterStyle = 4
    /// The pen value of `curvesstyles`.
    public static let penStyle = 3
    /// Document width used when the note does not record one (an iPad
    /// note's locked width).
    public static let defaultWidth = 716.8
    /// Horizontal offset from Notability's ink coordinates to the page, as a
    /// fraction of the document width: ink x = 0 is 18.8 units in from the
    /// left edge of a 716.8-wide page (measured against Notability's own
    /// thumbnails across every format version; ink reaches x ≈ -18 and
    /// x ≈ 698 but never beyond).
    public static let horizontalInsetFraction = 18.8 / 716.8
    /// Page aspect (height / width) used when nothing records one: what every
    /// "letter" note in the reference corpus shows (thumbnails 48 × 63).
    public static let defaultPageAspect = 21.0 / 16.0

    public init(metadata: Metadata, paper: Paper, curves: [Curve], typedText: String = "",
                recognition: [Int: RecognizedPage] = [:], pdfCount: Int = 0, pdfPageCount: Int = 0, mediaCount: Int = 0,
                recordingCount: Int = 0, bundleVersion: String? = nil, formatVersion: Int? = nil) {
        self.metadata = metadata; self.paper = paper; self.curves = curves; self.typedText = typedText
        self.recognition = recognition; self.pdfCount = pdfCount; self.pdfPageCount = pdfPageCount
        self.mediaCount = mediaCount
        self.recordingCount = recordingCount; self.bundleVersion = bundleVersion; self.formatVersion = formatVersion
    }
}

// MARK: - Parsing

extension NotabilityNote {
    /// Parses the bytes of a `.note` file (a zip package).
    ///
    /// - Throws: `ImportError.zip` for a bad container, `.archive` for a bad
    ///   plist, `.notability` when `Session.plist` is missing or its
    ///   handwriting arrays are inconsistent.
    public static func parse(data: Data) throws -> NotabilityNote {
        try parse(package: NotePackage(data: data))
    }

    /// Parses a `.note` package already opened as a zip.
    public static func parse(archive zip: ZipArchive) throws -> NotabilityNote {
        try parse(package: NotePackage(zip: zip))
    }

    /// Parses a `.note` package (zip or unzipped directory).
    public static func parse(package pkg: NotePackage) throws -> NotabilityNote {
        // The package is one top-level directory (`<name>/Session.plist`), or
        // `Session.plist` at the root of an unzipped package.
        let sessionPath = pkg.paths.first { $0 == "Session.plist" }
            ?? pkg.paths.first { $0.hasSuffix("/Session.plist") && $0.split(separator: "/").count == 2 }
        guard let sessionPath else { throw ImportError.notability("no Session.plist in package") }
        let prefix = String(sessionPath.dropLast("Session.plist".count))
        func part(_ name: String) throws -> Data? {
            pkg.contains(prefix + name) ? try pkg.read(prefix + name) : nil
        }

        let session = try KeyedArchive(data: pkg.read(sessionPath))
        let root = try session.root(anyOf: ["$0", "root"])
        guard root.className != nil || root.raw("richText") != nil else {
            throw ImportError.notability("Session.plist root is not a NoteTakingSession")
        }

        var meta = try parseMetadata(part("metadata.plist"), session: session, root: root,
                                     fallbackName: prefix.isEmpty ? "Untitled" : String(prefix.dropLast()))
        if meta.name.isEmpty { meta.name = "Untitled" }

        let richText = try session.field(root, "richText")
        let overlay = try session.field(richText, "Handwriting Overlay")
        let hash = try session.field(overlay, "SpatialHash")
        let curves = hash.isNull ? [] : try parseCurves(session, hash)

        let typed = try session.field(try session.field(richText, "attributedString"), "stringKey").string ?? ""
        let pdfCount = try session.elements(session.field(richText, "pdfFiles")).count
        let pdfPageCount = try session.elements(session.field(richText, "pageLayoutArray")).filter { page in
            page.raw("kPageLayoutPDFFileNameKey") != nil || page.raw("kPageLayoutPDFFileKey") != nil
        }.count
        let mediaCount = try session.elements(session.field(richText, "mediaObjects")).count
        let recordings = try parseRecordingCount(part("Recordings/library.plist"))
        let recognition = try parseRecognition(part("HandwritingIndex/index.plist"))

        // Page aspect from the widest thumbnail (thumb.png is 48 px wide,
        // thumb12x.png 576 px, so the larger ones carry the aspect more
        // precisely); ties prefer thumb.png. A thumbnail is only a hint: one
        // that cannot be read, or whose aspect is implausible, is skipped.
        var thumb: (Int, Int)?
        let thumbs = pkg.paths.filter { p in
            p.hasPrefix(prefix) && !p.dropFirst(prefix.count).contains("/")
                && p.dropFirst(prefix.count).hasPrefix("thumb") && p.hasSuffix(".png")
        }.sorted { a, b in (a == prefix + "thumb.png" ? 0 : 1, a) < (b == prefix + "thumb.png" ? 0 : 1, b) }
        for t in thumbs {
            guard let data = try? pkg.read(t), let size = pngSize(data),
                  plausibleAspect(Double(size.1) / Double(max(size.0, 1))) != nil, size.0 > (thumb?.0 ?? 0) else { continue }
            thumb = size
        }

        let paper = try parsePaper(session, root: root, richText: richText, thumbnail: thumb, curves: curves,
                                   pdfPages: pdfPageCount > 0)
        return NotabilityNote(
            metadata: meta, paper: paper, curves: curves, typedText: typed, recognition: recognition,
            pdfCount: pdfCount, pdfPageCount: pdfPageCount, mediaCount: mediaCount, recordingCount: recordings,
            bundleVersion: try session.field(root, "NBNoteTakingSessionBundleVersionNumberKey").string,
            formatVersion: try session.field(root, "sessionFormatVersion").int.map { Int($0) })
    }

    static func parseMetadata(_ data: Data?, session: KeyedArchive, root: KeyedArchive.Node,
                              fallbackName: String) throws -> Metadata {
        var m = Metadata(name: try session.field(root, "name").string ?? fallbackName)
        m.subject = try session.field(root, "subject").string
        m.tags = tags(try session.field(root, "tags"), session)
        m.created = try session.field(root, "creationDate").date
        m.packagePath = try session.field(root, "packagePath").string
        if let data {
            let a = try KeyedArchive(data: data)
            let r = try a.root(anyOf: ["root", "$0"])
            if let n = try a.field(r, "noteName").string, !n.isEmpty { m.name = n }
            if let s = try a.field(r, "noteSubject").string { m.subject = s }
            let t = tags(try a.field(r, "noteTags"), a)
            if !t.isEmpty { m.tags = t }
            m.created = try a.field(r, "noteCreationDateKey").date ?? m.created
            m.modified = try a.field(r, "noteModifiedDateKey").date
            m.uuid = try a.field(r, "uuidKey").string
            m.packagePath = try a.field(r, "notePackagePath").string ?? m.packagePath
        }
        if m.subject == "unsortedNotesKey" || m.subject?.isEmpty == true { m.subject = nil }
        return m
    }

    /// Tags arrive as a string (comma or newline separated) or an array of strings.
    static func tags(_ n: KeyedArchive.Node, _ a: KeyedArchive) -> [String] {
        if case .array = n {
            return ((try? a.elements(n)) ?? []).compactMap(\.string).map(trim).filter { !$0.isEmpty }
        }
        guard let s = n.string else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { trim(String($0)) }.filter { !$0.isEmpty }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Curves

    static func parseCurves(_ a: KeyedArchive, _ hash: KeyedArchive.Node) throws -> [Curve] {
        func data(_ key: String) throws -> Data { try a.field(hash, key).data ?? Data() }
        let n = Int(try a.field(hash, "numcurves").int ?? 0)
        guard n > 0 else { return [] }
        let numPoints = Int(try a.field(hash, "numpoints").int ?? -1)
        let counts = try int32s(data("curvesnumpoints"), "curvesnumpoints")
        guard counts.count == n, counts.allSatisfy({ $0 >= 0 }) else {
            throw ImportError.notability("curvesnumpoints has \(counts.count) entries for \(n) curves")
        }
        let total = counts.reduce(0, +)
        guard numPoints < 0 || total == numPoints else {
            throw ImportError.notability("curvesnumpoints sums to \(total), numpoints is \(numPoints)")
        }
        let xy = try float32s(data("curvespoints"), "curvespoints")
        guard xy.count == 2 * total else { throw ImportError.notability("curvespoints holds \(xy.count / 2) points, expected \(total)") }
        let widths = try float32s(data("curveswidth"), "curveswidth")
        guard widths.count == n else { throw ImportError.notability("curveswidth has \(widths.count) entries for \(n) curves") }
        // A NaN or infinite width would only fail when the note is written
        // (JSON has no NaN); a huge one is garbage. Reject both here.
        guard widths.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
            throw ImportError.notability("curveswidth holds widths beyond ±\(Int(maxCoordinate))")
        }
        let colors = try data("curvescolors")
        guard colors.count == 4 * n else { throw ImportError.notability("curvescolors has \(colors.count) bytes for \(n) curves") }
        let stylesData = try data("curvesstyles")
        let styles: [Int]
        if stylesData.count == n {
            styles = stylesData.map { Int($0) }
        } else if stylesData.count == 4 * n {
            styles = try int32s(stylesData, "curvesstyles").map { Int($0) }
        } else if stylesData.isEmpty {
            styles = Array(repeating: penStyle, count: n)
        } else {
            throw ImportError.notability("curvesstyles has \(stylesData.count) bytes for \(n) curves")
        }

        // Per-node arrays: one value per on-curve point (k + 1 per Bézier
        // curve of 3k + 1 points). Decided per curve: a curve whose count is
        // not 3k + 1 (never seen) is taken as a polyline with one value per point.
        let conforming = counts.map { $0 == 0 || ($0 - 1) % 3 == 0 }
        let mixed = zip(counts, conforming).map { c, ok in c == 0 ? 0 : (ok ? (c - 1) / 3 + 1 : c) }
        let fw = try float32s(data("curvesfractionalwidths"), "curvesfractionalwidths")
        var isBezier: [Bool]
        let perNode: [Int]
        if fw.count == mixed.reduce(0, +) {
            perNode = mixed; isBezier = conforming
        } else if fw.count == total {
            // One value per stored point throughout: every curve is a polyline.
            perNode = counts; isBezier = Array(repeating: false, count: n)
        } else {
            throw ImportError.notability("curvesfractionalwidths has \(fw.count) values; expected \(mixed.reduce(0, +))")
        }
        for i in 0..<n where counts[i] <= 1 { isBezier[i] = true }   // nothing to expand
        let nodesTotal = fw.count
        // Non-finite multipliers fall back to 1 (`BezierToBSpline`); finite ones must be sane.
        guard fw.allSatisfy({ !$0.isFinite || abs($0) <= maxCoordinate }) else {
            throw ImportError.notability("curvesfractionalwidths holds values beyond ±\(Int(maxCoordinate))")
        }
        // Notability coordinates are within a few thousand units per page; reject garbage.
        guard xy.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else {
            throw ImportError.notability("curvespoints holds coordinates beyond ±\(Int(maxCoordinate))")
        }
        func optional(_ key: String, stride: Int) throws -> [Double]? {
            let v = try float32s(data(key), key)
            return v.count == stride * nodesTotal && nodesTotal > 0 ? v : nil
        }
        let forces = try optional("curvesforces", stride: 1)
        let altitudes = try optional("curvesaltitudeangles", stride: 1)
        let azimuth = try optional("curvesazimuthunitvector", stride: 2)
        let uuids = try data("curveUUIDs")
        let dashed = try dashedCurves(a.field(hash, "dashStyles").data)

        var out: [Curve] = []
        out.reserveCapacity(n)
        var p = 0, q = 0
        for i in 0..<n {
            let c = counts[i], k = perNode[i]
            var pts: [Point] = []
            pts.reserveCapacity(c)
            for j in 0..<c { pts.append(Point(x: xy[2 * (p + j)], y: xy[2 * (p + j) + 1])) }
            if !isBezier[i] {
                // Polyline fallback: expand to degenerate Bézier segments.
                var bz: [Point] = [pts[0]]
                for j in 1..<c {
                    let a = pts[j - 1], b = pts[j]
                    bz.append(Point(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3))
                    bz.append(Point(x: a.x + 2 * (b.x - a.x) / 3, y: a.y + 2 * (b.y - a.y) / 3))
                    bz.append(b)
                }
                pts = bz
            }
            let az = azimuth.map { v in (q..<(q + k)).map { atan2(v[2 * $0 + 1], v[2 * $0]) } }
            let o = 4 * i
            let color = Color(r: colors[colors.startIndex + o], g: colors[colors.startIndex + o + 1],
                              b: colors[colors.startIndex + o + 2], a: colors[colors.startIndex + o + 3])
            var uuid: UUID?
            if uuids.count == 16 * n {
                let s = uuids.startIndex + 16 * i
                let b = Array(uuids[s..<(s + 16)])
                uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
            }
            out.append(Curve(points: pts, fractionalWidths: Array(fw[q..<(q + k)]),
                             forces: forces.map { Array($0[q..<(q + k)]) },
                             altitudes: altitudes.map { Array($0[q..<(q + k)]) },
                             azimuths: az, width: widths[i], color: color, style: styles[i],
                             dashed: dashed.contains(i), uuid: uuid))
            p += c
            q += k
        }
        return out
    }

    /// `dashStyles` is a nested binary plist: `{objectPatterns: {"<curve index>": {pattern: n}}}`.
    static func dashedCurves(_ data: Data?) throws -> Set<Int> {
        guard let data, !data.isEmpty else { return [] }
        guard case .dict(let d) = try PlistValue.parse(data), case .dict(let patterns)? = d["objectPatterns"] else {
            return []
        }
        return Set(patterns.keys.compactMap { Int($0) })
    }

    static func float32s(_ d: Data, _ name: String) throws -> [Double] {
        guard d.count % 4 == 0 else { throw ImportError.notability("\(name) is not a whole number of float32s") }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { i in
                Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))))
            }
        }
    }

    static func int32s(_ d: Data, _ name: String) throws -> [Int] {
        guard d.count % 4 == 0 else { throw ImportError.notability("\(name) is not a whole number of int32s") }
        return d.withUnsafeBytes { raw in
            (0..<(d.count / 4)).map { i in
                Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self)))
            }
        }
    }

    // MARK: Recognition

    static func parseRecognition(_ data: Data?) throws -> [Int: RecognizedPage] {
        guard let data else { return [:] }
        guard case .dict(let root) = try PlistValue.parse(data), case .dict(let pages)? = root["pages"] else { return [:] }
        var out: [Int: RecognizedPage] = [:]
        for (key, value) in pages {
            guard let number = Int(key), (1...maxRecognizedPage).contains(number), case .dict(let page) = value,
                  let text = page["text"]?.string else { continue }
            var origin = Point(x: 0, y: 0)
            if case .array(let o)? = page["pageContentOrigin"], o.count == 2, let x = o[0].double, let y = o[1].double,
               x.isFinite, y.isFinite, abs(x) <= maxCoordinate, abs(y) <= maxCoordinate {
                origin = Point(x: x, y: y)
            }
            let rects = page["characterRects"]?.data ?? Data()
            out[number] = RecognizedPage(text: text, origin: origin, characterBoxes: halfRects(rects))
        }
        return out
    }

    /// `characterRects`: four little-endian IEEE half floats (x, y, w, h) per
    /// UTF-16 unit; infinities mark whitespace.
    static func halfRects(_ d: Data) -> [Recognition.Box?] {
        let count = d.count / 8
        return d.withUnsafeBytes { raw in
            (0..<count).map { i -> Recognition.Box? in
                let v = (0..<4).map { j in
                    half(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 8 * i + 2 * j, as: UInt16.self)))
                }
                guard v.allSatisfy(\.isFinite) else { return nil }
                return Recognition.Box(x: v[0], y: v[1], w: v[2], h: v[3])
            }
        }
    }

    /// IEEE 754 binary16 to Double (Float16 is unavailable on some targets).
    static func half(_ bits: UInt16) -> Double {
        let sign: Double = bits & 0x8000 != 0 ? -1 : 1
        let exp = Int(bits >> 10 & 0x1F), frac = Double(bits & 0x3FF)
        switch exp {
        case 0: return sign * frac * pow(2, -24)
        case 31: return frac == 0 ? sign * .infinity : .nan
        default: return sign * (1 + frac / 1024) * pow(2, Double(exp - 15))
        }
    }

    static func parseRecordingCount(_ data: Data?) throws -> Int {
        guard let data, case .dict(let root) = try PlistValue.parse(data) else { return 0 }
        switch root["recordings"] {
        case .dict(let d)?: return d.count
        case .array(let a)?: return a.count
        default: return 0
        }
    }

    // MARK: Paper

    static func parsePaper(_ a: KeyedArchive, root: KeyedArchive.Node, richText: KeyedArchive.Node,
                           thumbnail: (Int, Int)?, curves: [Curve], pdfPages: Bool = false) throws -> Paper {
        let layout = try a.field(root, "NBNoteTakingSessionDocumentPaperLayoutModelKey")
        let attrs = try a.field(layout, "documentPaperAttributes")
        let sizing = try a.field(attrs, "paperSizingBehavior").string
        let size = try a.field(attrs, "paperSize").string
        let lineStyle2 = try a.field(attrs, "lineStyle2").string
        var lineStyle = try a.field(attrs, "lineStyle").int.map { Int($0) }
        if lineStyle == nil { lineStyle = try a.field(root, "paperLineStyle").int.map { Int($0) } }

        var width: Double?
        if let sizing, sizing.hasPrefix("lockedWidth:") {
            let parts = sizing.split(separator: ":")
            if parts.count >= 2, let w = Double(parts[1]).flatMap(plausibleWidth) { width = w }
        }
        if width == nil, let w = try a.field(try a.field(richText, "reflowState"), "pageWidthInDocumentCoordsKey").double
            .flatMap(plausibleWidth) {
            width = w
        }
        if width == nil {
            // deviceBasedWidth without a recorded width: the iPad default,
            // widened if any ink lies beyond it.
            let maxX = curves.lazy.flatMap(\.points).map(\.x).filter(\.isFinite).max() ?? 0
            width = min(max(defaultWidth, (maxX + 8).rounded(.up)), widthRange.upperBound)
        }
        let w = width ?? defaultWidth

        var aspect = defaultPageAspect
        if let size, size.hasPrefix("custom:"), let r = Double(size.dropFirst("custom:".count)),
           r.isFinite, r > 0, let a = plausibleAspect(1 / r) {
            aspect = a
        } else if let (tw, th) = thumbnail, tw > 0, th > 0, let a = plausibleAspect(Double(th) / Double(tw)) {
            aspect = a
        }

        let (kind, spacing) = paperStyle(lineStyle2: lineStyle2, lineStyle: lineStyle, width: w, size: size)
        // PDF pages are laid out at the document width and stack every
        // ceil(width × aspect) units (measured against the handwriting index
        // on 716.8- and 572-wide notes: 537.6 → 538, 429 → 429). Paper
        // pages are exactly width × aspect (940.8 on a 716.8 note).
        var pageHeight = w * aspect
        if pdfPages { pageHeight = (pageHeight - 1e-6).rounded(.up) }
        return Paper(width: w, pageHeight: pageHeight, kind: kind, spacing: spacing,
                     identifier: try a.field(attrs, "paperIdentifier").string, size: size,
                     sizingBehavior: sizing, lineStyle2: lineStyle2, lineStyle: lineStyle)
    }

    /// Page height / width ratios outside this range are not Notability
    /// pages (the samples hold 0.5625 to 1.414); a corrupt or hostile
    /// thumbnail or `custom:` size would otherwise make a page height of zero
    /// or of 10¹² units.
    static let aspectRange = 1.0 / 16 ... 16.0
    /// Document widths outside this range are ignored (the samples hold 572
    /// and 716.8): a width near 0 scales the ink to infinity, a huge one to 0.
    static let widthRange = 16.0 ... 100_000.0

    static func plausibleAspect(_ a: Double) -> Double? { aspectRange.contains(a) ? a : nil }
    static func plausibleWidth(_ w: Double) -> Double? { widthRange.contains(w) ? w : nil }

    /// Document units per legacy spacing unit (`Dots:0.5`, `Lines:0.5`),
    /// measured on a 716.8-wide page: 0.5 → 18.8.
    static let legacySpacingUnit = 37.6

    /// Paper pattern from `lineStyle2` (`Dots:0.5`, `Dots:false:true:0.25`,
    /// `Lines:0.5`, `No Lines`, …) or the older integer `lineStyle`.
    static func paperStyle(lineStyle2: String?, lineStyle: Int?, width: Double, size: String?) -> (PaperKind, Double?) {
        let legacyScale = width / defaultWidth * legacySpacingUnit
        if let s = lineStyle2 {
            let parts = s.split(separator: ":").map(String.init)
            let kind: PaperKind
            switch parts.first?.lowercased() ?? "" {
            case "dots", "dot": kind = .dot
            case "lines", "line", "ruled": kind = .ruled
            case "grid", "squares": kind = .grid
            default: return (.blank, nil)
            }
            guard let v = parts.last.flatMap(Double.init), v.isFinite, v > 0 else { return (kind, nil) }
            // Newer form (four fields): the last field is inches on the physical paper.
            let spacing = parts.count == 2 ? v * legacyScale : v * width / paperWidthInches(size)
            // An absurd pitch (or one that overflowed to infinity) draws as the default.
            return (kind, spacing.isFinite && spacing <= maxCoordinate ? spacing : nil)
        }
        switch lineStyle {
        case 1: return (.ruled, 0.5 * legacyScale)
        case 9: return (.dot, 0.5 * legacyScale)
        default: return (.blank, nil)
        }
    }

    static func paperWidthInches(_ size: String?) -> Double {
        switch size?.lowercased() {
        case "a4"?: return 210 / 25.4
        case "a5"?: return 148 / 25.4
        default: return 8.5
        }
    }

    /// Width and height from a PNG's IHDR chunk.
    static func pngSize(_ d: Data) -> (Int, Int)? {
        guard d.count >= 24, d.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        func be32(_ i: Int) -> Int {
            let s = d.startIndex + i
            return Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
        }
        return (be32(16), be32(20))
    }
}
