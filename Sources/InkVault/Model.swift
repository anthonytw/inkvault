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

    public init(id: UUID = UUID(), order: String, strokes: [Stroke] = [], orderClock: String? = nil,
                origin: String? = nil, recognition: Recognition? = nil, recognitionClock: String? = nil,
                parent: UUID? = nil) {
        self.id = id; self.order = order; self.strokes = strokes; self.orderClock = orderClock; self.origin = origin
        self.recognition = recognition; self.recognitionClock = recognitionClock; self.parent = parent
    }

    enum CodingKeys: String, CodingKey {
        case id, order, strokes, orderClock, origin, recognition, recognitionClock, parent
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
        case op, page, stroke, strokeId, pageId, order, recognition, field, value, tag, observed
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
