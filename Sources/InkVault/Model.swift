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

    public init(id: UUID = UUID(), ink: Ink, points: [StrokePoint], transform: Transform? = nil, parent: UUID? = nil) {
        self.id = id; self.ink = ink; self.points = points; self.transform = transform; self.parent = parent
    }

    enum CodingKeys: String, CodingKey { case id, ink, points, transform, parent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        ink = try c.decode(Ink.self, forKey: .ink)
        points = try c.decode([StrokePoint].self, forKey: .points)
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform)
        parent = try c.decodeIfPresent(LowercaseUUID.self, forKey: .parent)?.uuid
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(ink, forKey: .ink)
        try c.encode(points, forKey: .points)
        if let transform, !transform.isIdentity { try c.encode(transform, forKey: .transform) }
        if let parent { try c.encode(LowercaseUUID(parent), forKey: .parent) }
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

    public init(id: UUID = UUID(), order: String, strokes: [Stroke] = [], orderClock: String? = nil) {
        self.id = id; self.order = order; self.strokes = strokes; self.orderClock = orderClock
    }

    enum CodingKeys: String, CodingKey { case id, order, strokes, orderClock }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LowercaseUUID.self, forKey: .id).uuid
        order = try c.decode(String.self, forKey: .order)
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        orderClock = try c.decodeIfPresent(String.self, forKey: .orderClock)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LowercaseUUID(id), forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(strokes, forKey: .strokes)
        if let orderClock { try c.encode(orderClock, forKey: .orderClock) }
    }
}

public enum PaperKind: String, Hashable, Sendable, Codable, CaseIterable {
    case blank, ruled, grid, dot
}

public struct Paper: Hashable, Sendable, Codable {
    public var kind: PaperKind
    /// Line/grid spacing in points.
    public var spacing: Double
    public var background: Color
    public var lineColor: Color

    public init(kind: PaperKind, spacing: Double = 24, background: Color = .white,
                lineColor: Color = Color(r: 0xD0, g: 0xD8, b: 0xE8)) {
        self.kind = kind; self.spacing = spacing; self.background = background; self.lineColor = lineColor
    }

    public static let blank = Paper(kind: .blank)
    public static let ruled = Paper(kind: .ruled)
}

public struct PageSize: Hashable, Sendable, Codable {
    /// Points (1/72 in).
    public var width: Double
    /// Points; current extent when `infinite`.
    public var height: Double
    public var infinite: Bool

    public init(width: Double, height: Double, infinite: Bool = false) {
        self.width = width; self.height = height; self.infinite = infinite
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
    /// LWW register names that may appear in `clocks` (format.md §5.4).
    public static let clockKeys = ["title", "tags", "notebook", "favorite", "paper", "pageSize", "deleted"]

    public var deleted: Bool
    public var meta: NoteMeta
    /// Sorted by `(order, id)`.
    public var pages: [Page]
    /// Register name → `"<hlc>-<device>"` stamp that last set it. A missing
    /// register is stamped by the snapshot's own `(hlc, device)`.
    public var clocks: [String: String]?
    /// Removed ids whose add the snapshot writer had not seen.
    public var tombstones: Tombstones?

    public init(deleted: Bool = false, meta: NoteMeta, pages: [Page] = [],
                clocks: [String: String]? = nil, tombstones: Tombstones? = nil) {
        self.deleted = deleted; self.meta = meta; self.pages = pages
        self.clocks = clocks; self.tombstones = tombstones
    }

    enum CodingKeys: String, CodingKey { case deleted, meta, pages, clocks, tombstones }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        meta = try c.decode(NoteMeta.self, forKey: .meta)
        pages = try c.decode([Page].self, forKey: .pages)
        clocks = try c.decodeIfPresent([String: String].self, forKey: .clocks)
        tombstones = try c.decodeIfPresent(Tombstones.self, forKey: .tombstones)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(meta, forKey: .meta)
        try c.encode(pages, forKey: .pages)
        if let clocks, !clocks.isEmpty { try c.encode(clocks, forKey: .clocks) }
        if let tombstones, !tombstones.isEmpty { try c.encode(tombstones, forKey: .tombstones) }
    }
}

/// Snapshot tombstones (format.md §5.4): ids whose `removeStroke` /
/// `removePage` was seen before the matching add, so a late add stays removed.
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
    case setMeta(MetaChange)
    case deleteNote
    case restoreNote
}

extension Op: Codable {
    enum CodingKeys: String, CodingKey { case op, page, stroke, strokeId, pageId, order, field, value }

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
    /// Encoder for all format JSON: sorted keys, RFC 3339 dates with fractional seconds, no slash escaping.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(rfc3339.string(from: date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = rfc3339.date(from: s) ?? rfc3339NoFraction.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }

    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let rfc3339NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Writers round coordinates to 3 decimals (format.md §5.6).
    public static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
}
