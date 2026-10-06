import Foundation

// MARK: - Wire-format model types (docs/format.md §5.4–§5.6)
//
// These are the Codable value types every other module builds on. Their JSON
// shape is normative; changing an encoding here is a format change.

/// `#RRGGBBAA` colour.
public struct Color: Hashable, Sendable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (case-insensitive).
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: UInt8(v >> 16 & 0xFF), g: UInt8(v >> 8 & 0xFF), b: UInt8(v & 0xFF), a: 255)
        } else {
            self.init(r: UInt8(v >> 24 & 0xFF), g: UInt8(v >> 16 & 0xFF), b: UInt8(v >> 8 & 0xFF), a: UInt8(v & 0xFF))
        }
    }

    public var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }

    public static let black = Color(r: 0, g: 0, b: 0)
    public static let white = Color(r: 255, g: 255, b: 255)

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = Color(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad colour \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

/// PencilKit ink families. Unknown values decode as `.pen` (format.md §5.6).
public enum InkTool: String, Hashable, Sendable, Codable, CaseIterable {
    case pen, pencil, marker, monoline, fountainPen, watercolor, crayon

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InkTool(rawValue: raw) ?? .pen
    }
}

public struct Ink: Hashable, Sendable, Codable {
    public var tool: InkTool
    public var color: Color
    /// Nominal width in points (the tool's base size).
    public var width: Double

    public init(tool: InkTool, color: Color, width: Double) {
        self.tool = tool; self.color = color; self.width = width
    }
}

/// One B-spline control point: `[x, y, t, w, h, o, f, az, al]`.
public struct StrokePoint: Hashable, Sendable, Codable {
    public var x: Double, y: Double
    /// Time offset from stroke start, seconds.
    public var t: Double
    /// Size in points.
    public var w: Double, h: Double
    /// Opacity 0...1.
    public var o: Double
    /// Force (0 when unavailable).
    public var f: Double
    /// Azimuth and altitude, radians.
    public var az: Double, al: Double

    public init(x: Double, y: Double, t: Double = 0, w: Double, h: Double, o: Double = 1,
                f: Double = 0, az: Double = 0, al: Double = .pi / 2) {
        self.x = x; self.y = y; self.t = t; self.w = w; self.h = h
        self.o = o; self.f = f; self.az = az; self.al = al
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self); t = try c.decode(Double.self)
        w = try c.decode(Double.self); h = try c.decode(Double.self); o = try c.decode(Double.self)
        f = try c.decode(Double.self); az = try c.decode(Double.self); al = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in [x, y, t, w, h, o, f, az, al] { try c.encode(InkJSON.round3(v)) }
    }
}

/// Affine matrix `[a b c d tx ty]`.
public struct Transform: Hashable, Sendable, Codable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public static let identity = Transform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public var isIdentity: Bool { self == .identity }

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(Double.self); b = try u.decode(Double.self); c = try u.decode(Double.self)
        d = try u.decode(Double.self); tx = try u.decode(Double.self); ty = try u.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        for v in [a, b, c, d, tx, ty] { try u.encode(InkJSON.round3(v)) }
    }
}

public struct Stroke: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ink: Ink
    public var points: [StrokePoint]
    public var transform: Transform?
    /// Stroke this one was sliced from, if any.
    public var parent: UUID?
    /// Snapshot only: `"<hlc>-<device>-<seq>-<op>"` of the op that added the
    /// stroke (format.md §5.6). Ignored inside ops.
    public var origin: String?

    public init(id: UUID = UUID(), ink: Ink, points: [StrokePoint], transform: Transform? = nil, parent: UUID? = nil,
                origin: String? = nil) {
        self.id = id; self.ink = ink; self.points = points; self.transform = transform; self.parent = parent
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey { case id, ink, points, transform, parent, origin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        ink = try c.decode(Ink.self, forKey: .ink)
        points = try c.decode([StrokePoint].self, forKey: .points)
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform)
        parent = try c.decodeIfPresent(LowercaseUUID.self, forKey: .parent)?.uuid
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(ink, forKey: .ink)
        try c.encode(points, forKey: .points)
        if let transform, !transform.isIdentity { try c.encode(transform, forKey: .transform) }
        if let parent { try c.encode(LowercaseUUID(parent), forKey: .parent) }
        if let origin { try c.encode(origin, forKey: .origin) }
    }
}

/// Text recognised in a page's handwriting (format.md §5.5): produced on
/// device (PencilKit) or carried in by an importer; used for search.
public struct Recognition: Hashable, Sendable, Codable {
    /// One recognised word and where it is on the page.
    public struct Word: Hashable, Sendable, Codable {
        /// The word.
        public var text: String
        /// Bounding box `[x, y, w, h]` in page coordinates (points).
        public var box: Box

        public init(text: String, box: Box) { self.text = text; self.box = box }

        enum CodingKeys: String, CodingKey { case text = "t", box }
    }

    /// Axis-aligned rectangle, encoded `[x, y, w, h]`.
    public struct Box: Hashable, Sendable, Codable {
        public var x: Double, y: Double, w: Double, h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            x = try c.decode(Double.self); y = try c.decode(Double.self)
            w = try c.decode(Double.self); h = try c.decode(Double.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            for v in [x, y, w, h] { try c.encode(InkJSON.round3(v)) }
        }
    }

    /// Name and version of the recogniser, e.g. `pencilkit-27.0` or `notability-14.2.6`.
    public var engine: String
    /// The page's text in reading order, lines separated by `\n`.
    public var text: String
    /// Words of `text` with their boxes; may be empty.
    public var words: [Word]

    public init(engine: String, text: String, words: [Word] = []) {
        self.engine = engine; self.text = text; self.words = words
    }
}

public struct Page: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Sort key; pages order by `(order, id)` lexicographically.
    public var order: String
    public var strokes: [Stroke]
    /// Snapshot only: `"<hlc>-<device>"` stamp of the op that last set `order`
    /// (format.md §5.5). Nil means the snapshot's own stamp.
    public var orderClock: String?
    /// Snapshot only: `"<hlc>-<device>-<seq>-<op>"` of the `addPage` that
    /// added the page (format.md §5.5).
    public var origin: String?
    /// Recognised handwriting text; set by `setPageRecognition` (format.md §5.5).
    public var recognition: Recognition?
    /// Snapshot only: `"<hlc>-<device>"` stamp of the `setPageRecognition`
    /// that last set `recognition`. Nil with a nil `recognition` means never set.
    public var recognitionClock: String?
    /// The removed page this one re-creates, e.g. when restored from history
    /// (format.md §5.5). Informational; set once by `addPage`.
    public var parent: UUID?
    /// This page's own paper, overriding the note's `meta.paper` (format.md
    /// §5.4.2); nil follows the note.
    public var paper: Paper?
    /// `"<hlc>-<device>"` stamp of the op that last set `paper` (or cleared it).
    public var paperClock: String?

    public init(id: UUID = UUID(), order: String, strokes: [Stroke] = [], orderClock: String? = nil,
                origin: String? = nil, recognition: Recognition? = nil, recognitionClock: String? = nil,
                parent: UUID? = nil, paper: Paper? = nil, paperClock: String? = nil) {
        self.id = id; self.order = order; self.strokes = strokes; self.orderClock = orderClock; self.origin = origin
        self.recognition = recognition; self.recognitionClock = recognitionClock; self.parent = parent
        self.paper = paper; self.paperClock = paperClock
    }

    enum CodingKeys: String, CodingKey {
        case id, order, strokes, orderClock, origin, recognition, recognitionClock, parent, paper, paperClock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        order = try c.decode(String.self, forKey: .order)
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        orderClock = try c.decodeIfPresent(String.self, forKey: .orderClock)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        recognition = try c.decodeIfPresent(Recognition.self, forKey: .recognition)
        recognitionClock = try c.decodeIfPresent(String.self, forKey: .recognitionClock)
        parent = try c.decodeIfPresent(LowercaseUUID.self, forKey: .parent)?.uuid
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper)
        paperClock = try c.decodeIfPresent(String.self, forKey: .paperClock)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(strokes, forKey: .strokes)
        if let orderClock { try c.encode(orderClock, forKey: .orderClock) }
        if let origin { try c.encode(origin, forKey: .origin) }
        if let recognition { try c.encode(recognition, forKey: .recognition) }
        if let recognitionClock { try c.encode(recognitionClock, forKey: .recognitionClock) }
        if let parent { try c.encode(LowercaseUUID(parent), forKey: .parent) }
        if let paper { try c.encode(paper, forKey: .paper) }
        if let paperClock { try c.encode(paperClock, forKey: .paperClock) }
    }
}

/// The pattern a page is ruled with (format.md §5.4.2). Unknown names decode
/// as `.blank`, so a vault written by a newer app still opens.
public enum PaperKind: String, Hashable, Sendable, Codable, CaseIterable {
    case blank, ruled, grid, dot
    /// Ruled with a left (and optionally top) margin line.
    case marginRuled
    /// Triangular lattice of dots (isometric dot paper).
    case isoDot
    /// Triangular grid: horizontals plus lines at ±30° from vertical.
    case isoGrid
    /// Cue column on the left, summary band at the bottom, ruled notes area.
    case cornell
    /// Music staves of five lines.
    case staff

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = PaperKind(rawValue: s) ?? .blank
    }

    /// Human-readable name.
    public var title: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "Ruled"
        case .marginRuled: return "Ruled with margin"
        case .grid: return "Grid"
        case .dot: return "Dots"
        case .isoDot: return "Isometric dots"
        case .isoGrid: return "Isometric grid"
        case .cornell: return "Cornell"
        case .staff: return "Music staff"
        }
    }

    /// Kinds whose ruling can carry margin lines (`marginLeft` / `marginTop`).
    public var supportsMargins: Bool { self == .ruled || self == .marginRuled || self == .grid || self == .dot }
}

/// Page background and ruling (format.md §5.4.2). Lengths are points.
///
/// `kind`, `spacing`, `background` and `lineColor` are always encoded (so
/// older readers keep working on the original four kinds); the other fields
/// are encoded only when they differ from the kind's default, and a missing
/// field decodes as that default.
public struct Paper: Hashable, Sendable, Codable {
    /// The pattern. A kind this reader does not know reads as `.blank`
    /// (§5.4.2); setting it replaces the kind name.
    public var kind: PaperKind {
        get { PaperKind(rawValue: kindName) ?? .blank }
        set { kindName = newValue.rawValue }
    }
    /// `kind` as written, kept when it names a kind this reader does not
    /// know, so that rewriting the paper (a snapshot, a restore) does not
    /// turn a newer app's paper into blank (format.md §5.4.2).
    public private(set) var kindName: String
    /// Line, dot or grid spacing in points.
    public var spacing: Double
    public var background: Color
    /// Colour of rules and dots.
    public var lineColor: Color
    /// Width of rules, points.
    public var lineWidth: Double
    /// Dot radius (`dot`, `isoDot`), points.
    public var dotRadius: Double
    /// Distance of the left margin line from the left edge; 0 = none.
    public var marginLeft: Double
    /// Distance of the top margin line from the top edge; 0 = none.
    public var marginTop: Double
    public var marginColor: Color
    /// Cornell cue-column width.
    public var cueWidth: Double
    /// Cornell summary-band height.
    public var summaryHeight: Double
    /// Distance between the five lines of a music staff.
    public var staffSpacing: Double
    /// Gap between the bottom line of one staff and the top line of the next.
    public var staffGap: Double

    public static let defaultLineColor = Color(r: 0xD0, g: 0xD8, b: 0xE8)
    public static let defaultMarginColor = Color(r: 0xF2, g: 0xA6, b: 0xA6)
    public static let cream = Color(r: 0xFF, g: 0xF8, b: 0xE1)
    public static let darkBackground = Color(r: 0x1C, g: 0x1C, b: 0x1E)

    /// Paper of `kind` with that kind's defaults; any parameter can be overridden.
    public init(kind: PaperKind, spacing: Double? = nil, background: Color = .white,
                lineColor: Color = Paper.defaultLineColor, lineWidth: Double = 0.5, dotRadius: Double = 0.9,
                marginLeft: Double? = nil, marginTop: Double = 0, marginColor: Color = Paper.defaultMarginColor,
                cueWidth: Double = 150, summaryHeight: Double = 120,
                staffSpacing: Double = 7, staffGap: Double = 40) {
        self.kindName = kind.rawValue
        self.spacing = spacing ?? 24
        self.background = background; self.lineColor = lineColor
        self.lineWidth = lineWidth; self.dotRadius = dotRadius
        self.marginLeft = marginLeft ?? (kind == .marginRuled ? 72 : 0)
        self.marginTop = marginTop; self.marginColor = marginColor
        self.cueWidth = cueWidth; self.summaryHeight = summaryHeight
        self.staffSpacing = staffSpacing; self.staffGap = staffGap
    }

    public static let blank = Paper(kind: .blank)
    public static let ruled = Paper(kind: .ruled)

    /// Parameter limits (inclusive). Writers clamp to them (`validated`);
    /// readers render whatever they find, clamping the parameters other than
    /// `spacing` so a corrupt value cannot spin the renderer (§5.4.2).
    public enum Limits {
        public static let spacing = 4.0...200.0
        public static let lineWidth = 0.1...4.0
        public static let dotRadius = 0.3...4.0
        public static let margin = 0.0...300.0
        public static let cueWidth = 40.0...400.0
        public static let summaryHeight = 40.0...400.0
        public static let staffSpacing = 3.0...20.0
        public static let staffGap = 8.0...150.0
    }

    /// The paper with every parameter clamped into `Limits` (NaN and
    /// infinities become the default).
    public func validated() -> Paper {
        var p = rendered()
        p.spacing = Paper.clamp(spacing, Limits.spacing, 24)
        return p
    }

    /// Whether `validated()` would change nothing.
    public var isValid: Bool { self == validated() }

    /// Like `validated()` but leaves `spacing` alone (the renderer draws
    /// nothing for spacing below `RenderLimits.minPaperSpacing`, as before).
    public func rendered() -> Paper {
        var p = self
        p.lineWidth = Paper.clamp(lineWidth, Limits.lineWidth, 0.5)
        p.dotRadius = Paper.clamp(dotRadius, Limits.dotRadius, 0.9)
        p.marginLeft = Paper.clamp(marginLeft, Limits.margin, 0)
        p.marginTop = Paper.clamp(marginTop, Limits.margin, 0)
        p.cueWidth = Paper.clamp(cueWidth, Limits.cueWidth, 150)
        p.summaryHeight = Paper.clamp(summaryHeight, Limits.summaryHeight, 120)
        p.staffSpacing = Paper.clamp(staffSpacing, Limits.staffSpacing, 7)
        p.staffGap = Paper.clamp(staffGap, Limits.staffGap, 40)
        return p
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>, _ fallback: Double) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : fallback
    }

    /// The default paper of a kind as the picker starts it: the kind's own
    /// spacing and parameters on white.
    public static func template(_ kind: PaperKind) -> Paper {
        switch kind {
        case .grid, .dot: return Paper(kind: kind, spacing: 18)
        case .isoDot, .isoGrid: return Paper(kind: kind, spacing: 20)
        case .staff: return Paper(kind: kind, lineColor: Color(r: 0x9A, g: 0xA3, b: 0xB5))
        case .cornell: return Paper(kind: kind, spacing: 24)
        default: return Paper(kind: kind)
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, spacing, background, lineColor, lineWidth, dotRadius, marginLeft, marginTop, marginColor
        case cueWidth, summaryHeight, staffSpacing, staffGap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .kind)
        self.init(kind: PaperKind(rawValue: name) ?? .blank)
        kindName = name
        func get<T: Decodable>(_ k: CodingKeys, _ cur: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: k) { cur = v }
        }
        try get(.spacing, &spacing); try get(.background, &background); try get(.lineColor, &lineColor)
        try get(.lineWidth, &lineWidth); try get(.dotRadius, &dotRadius)
        try get(.marginLeft, &marginLeft); try get(.marginTop, &marginTop); try get(.marginColor, &marginColor)
        try get(.cueWidth, &cueWidth); try get(.summaryHeight, &summaryHeight)
        try get(.staffSpacing, &staffSpacing); try get(.staffGap, &staffGap)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kindName, forKey: .kind)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(background, forKey: .background)
        try c.encode(lineColor, forKey: .lineColor)
        let d = Paper(kind: kind)
        func put<T: Encodable & Equatable>(_ k: CodingKeys, _ v: T, _ def: T) throws {
            if v != def { try c.encode(v, forKey: k) }
        }
        try put(.lineWidth, lineWidth, d.lineWidth); try put(.dotRadius, dotRadius, d.dotRadius)
        try put(.marginLeft, marginLeft, d.marginLeft); try put(.marginTop, marginTop, d.marginTop)
        try put(.marginColor, marginColor, d.marginColor)
        try put(.cueWidth, cueWidth, d.cueWidth); try put(.summaryHeight, summaryHeight, d.summaryHeight)
        try put(.staffSpacing, staffSpacing, d.staffSpacing); try put(.staffGap, staffGap, d.staffGap)
    }
}

public struct PageSize: Hashable, Sendable, Codable {
    /// Points (1/72 in).
    public var width: Double
    /// Points; current extent when `infinite`.
    public var height: Double
    public var infinite: Bool
    /// Points; for an infinite page, the height of each page an exporter
    /// paginates it into. Nil: `width × 11 / 8.5` (format.md §5.4).
    public var breakHeight: Double?

    public init(width: Double, height: Double, infinite: Bool = false, breakHeight: Double? = nil) {
        self.width = width; self.height = height; self.infinite = infinite; self.breakHeight = breakHeight
    }

    public static let letter = PageSize(width: 612, height: 792)
    public static let a4 = PageSize(width: 595, height: 842)
}

public struct NoteMeta: Hashable, Sendable, Codable {
    public var title: String
    public var tags: [String]
    public var notebook: String?
    public var favorite: Bool
    /// Set once by the first revision; never changes.
    public var created: Date
    public var paper: Paper
    public var pageSize: PageSize

    public init(title: String = "", tags: [String] = [], notebook: String? = nil, favorite: Bool = false,
                created: Date, paper: Paper = .blank, pageSize: PageSize = .letter) {
        self.title = title; self.tags = tags; self.notebook = notebook; self.favorite = favorite
        self.created = created; self.paper = paper; self.pageSize = pageSize
    }
}

/// Full note state as stored in a snapshot (format.md §5.4).
public struct NoteState: Hashable, Sendable, Codable {
    /// The LWW registers, named as they appear in `clocks` (format.md §5.4).
    public enum ClockKey: String, Hashable, Sendable, CaseIterable {
        case title, tags, notebook, favorite, paper, pageSize, deleted
    }

    public var deleted: Bool
    public var meta: NoteMeta
    /// Sorted by `(order, id)`.
    public var pages: [Page]
    /// Register name → `"<hlc>-<device>"` stamp that last set it. A missing
    /// register is stamped by the snapshot's own `(hlc, device)`.
    public var clocks: [String: String]?
    /// Stroke ids removed before their add was covered, and every removed
    /// page id (page tombstones are permanent).
    public var tombstones: Tombstones?
    /// The per-tag merge state (format.md §5.4.1). Nil in a snapshot written
    /// before that rule, whose `meta.tags` is then one legacy write; when set,
    /// `meta.tags` is derived from it.
    public var tagSet: TagSet?

    public init(deleted: Bool = false, meta: NoteMeta, pages: [Page] = [],
                clocks: [String: String]? = nil, tombstones: Tombstones? = nil, tagSet: TagSet? = nil) {
        self.deleted = deleted; self.meta = meta; self.pages = pages
        self.clocks = clocks; self.tombstones = tombstones; self.tagSet = tagSet
    }

    enum CodingKeys: String, CodingKey { case deleted, meta, pages, clocks, tombstones, tagSet }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        meta = try c.decode(NoteMeta.self, forKey: .meta)
        pages = try c.decode([Page].self, forKey: .pages)
        clocks = try c.decodeIfPresent([String: String].self, forKey: .clocks)
        tombstones = try c.decodeIfPresent(Tombstones.self, forKey: .tombstones)
        tagSet = try c.decodeIfPresent(TagSet.self, forKey: .tagSet)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(meta, forKey: .meta)
        try c.encode(pages, forKey: .pages)
        if let clocks, !clocks.isEmpty { try c.encode(clocks, forKey: .clocks) }
        if let tombstones, !tombstones.isEmpty { try c.encode(tombstones, forKey: .tombstones) }
        // Always written when known, even empty: its absence marks a pre-§5.4.1 snapshot.
        if let tagSet { try c.encode(tagSet, forKey: .tagSet) }
    }
}

/// A note's tags as an observed-remove set of instances (format.md §5.4.1).
/// Each `addTag` adds one instance, named by the op's origin; `removeTag`
/// removes the instances it lists. A tag key is present while it has a live
/// instance.
public struct TagSet: Hashable, Sendable, Codable {
    /// One live tag instance: its spelling and the op that added it.
    public struct Instance: Hashable, Sendable, Codable {
        /// The tag as written by its `addTag` (or the legacy array).
        public var tag: String
        /// The adding op; `seq` 0 for a legacy baseline instance.
        public var origin: Origin

        /// The tag key (`NoteOps.tagKey`).
        public var key: String { NoteOps.tagKey(tag) }

        public init(tag: String, origin: Origin) { self.tag = tag; self.origin = origin }

        enum CodingKeys: String, CodingKey { case tag, origin }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tag = try c.decode(String.self, forKey: .tag)
            origin = try c.decode(TagInstanceOrigin.self, forKey: .origin).origin
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tag, forKey: .tag)
            try c.encode(origin.description, forKey: .origin)
        }
    }

    /// A removed instance: its tag key and origin.
    public struct Removal: Hashable, Sendable, Codable {
        public var key: String
        public var origin: Origin

        public init(key: String, origin: Origin) { self.key = key; self.origin = origin }

        enum CodingKeys: String, CodingKey { case key, origin }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            origin = try c.decode(TagInstanceOrigin.self, forKey: .origin).origin
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(origin.description, forKey: .origin)
        }
    }

    /// The winning legacy `setMeta(tags)` write and its stamp.
    public struct Legacy: Hashable, Sendable, Codable {
        public var tags: [String]
        /// `"<hlc>-<device>"`.
        public var clock: String

        public init(tags: [String], clock: String) { self.tags = tags; self.clock = clock }
    }

    /// Every live instance, sorted by origin.
    public var instances: [Instance]
    /// Every removed instance; never pruned.
    public var removed: [Removal]
    /// The winning legacy write, if any was seen.
    public var legacy: Legacy?

    public init(instances: [Instance] = [], removed: [Removal] = [], legacy: Legacy? = nil) {
        self.instances = instances; self.removed = removed; self.legacy = legacy
    }

    /// The live instances of the key of `tag` (any spelling): what a
    /// `removeTag` of it lists as `observed`.
    public func instances(of tag: String) -> [Origin] {
        let key = NoteOps.tagKey(tag)
        return instances.filter { $0.key == key }.map(\.origin)
    }

    enum CodingKeys: String, CodingKey { case instances, removed, legacy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instances = try c.decodeIfPresent([Instance].self, forKey: .instances) ?? []
        removed = try c.decodeIfPresent([Removal].self, forKey: .removed) ?? []
        legacy = try c.decodeIfPresent(Legacy.self, forKey: .legacy)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(instances, forKey: .instances)
        try c.encode(removed, forKey: .removed)
        if let legacy { try c.encode(legacy, forKey: .legacy) }
    }
}

/// A tag instance id on the wire: an origin whose `seq` may be 0 (a legacy
/// baseline instance, format.md §5.4.1).
struct TagInstanceOrigin: Codable {
    var origin: Origin

    init(_ origin: Origin) { self.origin = origin }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let o = Origin.tagInstance(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad tag instance \(s)"))
        }
        origin = o
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(origin.description)
    }
}

/// Snapshot tombstones (format.md §5.4): stroke ids whose `removeStroke` was
/// seen while the adding revision was not yet covered, and every removed page
/// id, so a late add stays removed.
public struct Tombstones: Hashable, Sendable, Codable {
    public var strokes: [UUID]
    public var pages: [UUID]

    public init(strokes: [UUID] = [], pages: [UUID] = []) {
        self.strokes = strokes; self.pages = pages
    }

    public var isEmpty: Bool { strokes.isEmpty && pages.isEmpty }

    enum CodingKeys: String, CodingKey { case strokes, pages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = try c.decodeIfPresent([LowercaseUUID].self, forKey: .strokes)?.map(\.uuid) ?? []
        pages = try c.decodeIfPresent([LowercaseUUID].self, forKey: .pages)?.map(\.uuid) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(strokes.map(LowercaseUUID.init), forKey: .strokes)
        try c.encode(pages.map(LowercaseUUID.init), forKey: .pages)
    }
}

// MARK: - Metadata fields for setMeta ops (one case per LWW field)

public enum MetaChange: Hashable, Sendable {
    case title(String)
    /// Legacy whole-array tags write (format.md §5.4.1): read, never written;
    /// writers use `Op.addTag` / `Op.removeTag`.
    case tags([String])
    case notebook(String?)
    case favorite(Bool)
    case paper(Paper)
    case pageSize(PageSize)

    public var field: String {
        switch self {
        case .title: return "title"
        case .tags: return "tags"
        case .notebook: return "notebook"
        case .favorite: return "favorite"
        case .paper: return "paper"
        case .pageSize: return "pageSize"
        }
    }

    /// Applies the change to `meta`.
    public func apply(to meta: inout NoteMeta) {
        switch self {
        case .title(let v): meta.title = v
        case .tags(let v): meta.tags = v
        case .notebook(let v): meta.notebook = v
        case .favorite(let v): meta.favorite = v
        case .paper(let v): meta.paper = v
        case .pageSize(let v): meta.pageSize = v
        }
    }
}

// MARK: - Delta operations (format.md §5.2)

public enum Op: Hashable, Sendable {
    case addStroke(page: UUID, stroke: Stroke)
    case removeStroke(page: UUID, strokeId: UUID)
    case addPage(Page)
    case removePage(pageId: UUID)
    case setPageOrder(pageId: UUID, order: String)
    /// LWW on the page's recognised text; nil clears it (format.md §5.5).
    case setPageRecognition(pageId: UUID, recognition: Recognition?)
    /// LWW on the page's own paper; nil makes the page follow the note's
    /// paper again (format.md §5.4.2).
    case setPagePaper(pageId: UUID, paper: Paper?)
    case setMeta(MetaChange)
    /// Adds one instance of a tag, named by this op's origin (format.md §5.4.1).
    case addTag(String)
    /// Removes the listed instances of the key of `tag` (format.md §5.4.1).
    case removeTag(String, observed: [Origin])
    case deleteNote
    case restoreNote
}

extension Op: Codable {
    enum CodingKeys: String, CodingKey {
        case op, page, stroke, strokeId, pageId, order, recognition, paper, field, value, tag, observed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "addStroke":
            self = .addStroke(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                              stroke: try c.decode(Stroke.self, forKey: .stroke))
        case "removeStroke":
            self = .removeStroke(page: try c.decode(LowercaseUUID.self, forKey: .page).uuid,
                                 strokeId: try c.decode(LowercaseUUID.self, forKey: .strokeId).uuid)
        case "addPage":
            self = .addPage(try c.decode(Page.self, forKey: .page))
        case "removePage":
            self = .removePage(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid)
        case "setPageOrder":
            self = .setPageOrder(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                 order: try c.decode(String.self, forKey: .order))
        case "setPageRecognition":
            self = .setPageRecognition(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                       recognition: try c.decodeIfPresent(Recognition.self, forKey: .recognition))
        case "setPagePaper":
            self = .setPagePaper(pageId: try c.decode(LowercaseUUID.self, forKey: .pageId).uuid,
                                 paper: try c.decodeIfPresent(Paper.self, forKey: .paper))
        case "setMeta":
            let field = try c.decode(String.self, forKey: .field)
            switch field {
            case "title": self = .setMeta(.title(try c.decode(String.self, forKey: .value)))
            case "tags": self = .setMeta(.tags(try c.decode([String].self, forKey: .value)))
            case "notebook": self = .setMeta(.notebook(try c.decodeIfPresent(String.self, forKey: .value)))
            case "favorite": self = .setMeta(.favorite(try c.decode(Bool.self, forKey: .value)))
            case "paper": self = .setMeta(.paper(try c.decode(Paper.self, forKey: .value)))
            case "pageSize": self = .setMeta(.pageSize(try c.decode(PageSize.self, forKey: .value)))
            default:
                throw DecodingError.dataCorruptedError(forKey: .field, in: c, debugDescription: "unknown meta field \(field)")
            }
        case "addTag": self = .addTag(try c.decode(String.self, forKey: .tag))
        case "removeTag":
            self = .removeTag(try c.decode(String.self, forKey: .tag),
                              observed: try c.decode([TagInstanceOrigin].self, forKey: .observed).map(\.origin))
        case "deleteNote": self = .deleteNote
        case "restoreNote": self = .restoreNote
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(op)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addStroke(let page, let stroke):
            try c.encode("addStroke", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(stroke, forKey: .stroke)
        case .removeStroke(let page, let strokeId):
            try c.encode("removeStroke", forKey: .op)
            try c.encode(LowercaseUUID(page), forKey: .page)
            try c.encode(LowercaseUUID(strokeId), forKey: .strokeId)
        case .addPage(let page):
            try c.encode("addPage", forKey: .op)
            try c.encode(page, forKey: .page)
        case .removePage(let pageId):
            try c.encode("removePage", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
        case .setPageOrder(let pageId, let order):
            try c.encode("setPageOrder", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(order, forKey: .order)
        case .setPageRecognition(let pageId, let recognition):
            try c.encode("setPageRecognition", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(recognition, forKey: .recognition)   // null when nil
        case .setPagePaper(let pageId, let paper):
            try c.encode("setPagePaper", forKey: .op)
            try c.encode(LowercaseUUID(pageId), forKey: .pageId)
            try c.encode(paper, forKey: .paper)   // null when nil
        case .setMeta(let change):
            try c.encode("setMeta", forKey: .op)
            try c.encode(change.field, forKey: .field)
            switch change {
            case .title(let v): try c.encode(v, forKey: .value)
            case .tags(let v): try c.encode(v, forKey: .value)
            case .notebook(let v): try c.encode(v, forKey: .value)   // null when nil
            case .favorite(let v): try c.encode(v, forKey: .value)
            case .paper(let v): try c.encode(v, forKey: .value)
            case .pageSize(let v): try c.encode(v, forKey: .value)
            }
        case .addTag(let tag):
            try c.encode("addTag", forKey: .op)
            try c.encode(tag, forKey: .tag)
        case .removeTag(let tag, let observed):
            try c.encode("removeTag", forKey: .op)
            try c.encode(tag, forKey: .tag)
            try c.encode(observed.map(\.description), forKey: .observed)
        case .deleteNote: try c.encode("deleteNote", forKey: .op)
        case .restoreNote: try c.encode("restoreNote", forKey: .op)
        }
    }
}

// MARK: - JSON conventions (format.md §6)

/// UUIDs are lowercase on the wire; Foundation encodes them uppercase.
public struct LowercaseUUID: Codable, Hashable, Sendable {
    public var uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad uuid \(s)"))
        }
        uuid = u
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString.lowercased())
    }
}

public enum InkJSON {
    /// Encoder for all format JSON: sorted keys, RFC 3339 dates with
    /// fractional seconds (`RFC3339`), no slash escaping. A date outside
    /// years 0001...9999 throws `EncodingError` rather than writing a file
    /// no reader could decode.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            guard let s = RFC3339.string(from: date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: enc.codingPath,
                                                             debugDescription: "date outside years 0001...9999"))
            }
            var c = enc.singleValueContainer()
            try c.encode(s)
        }
        return e
    }

    /// Decoder for all format JSON; dates are RFC 3339 (`RFC3339.parse`).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = RFC3339.parse(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s.prefix(64))"))
        }
        return d
    }

    /// Writers round coordinates to 3 decimals (format.md §5.6). A value too
    /// large to scale (beyond about 10^305) is written as it is rather than
    /// as infinity, which JSON cannot hold.
    public static func round3(_ v: Double) -> Double {
        let scaled = v * 1000
        return scaled.isFinite ? scaled.rounded() / 1000 : v
    }
}
