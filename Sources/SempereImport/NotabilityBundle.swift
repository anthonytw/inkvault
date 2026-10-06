import Foundation
import Sempere

/// Reader for Notability's newer `.ntb` files (`docs/import-notability.md`,
/// ".ntb format"): a zip of `version`, `manifest.json`, `thumbnail.png` and
/// `noteBundle`, a FlatBuffers buffer holding the note as a list of records.
/// The schema is not published; everything here was decoded without it and
/// checked against the `.note` copies of the same notes. Only ink (strokes
/// and straight lines), the page geometry, the paper pattern, the title and
/// the creation date are read; there is no handwriting recognition in the
/// bundle, and PDFs and images live outside it.
public enum NotabilityBundle {
    /// Record types (`record.type`).
    enum RecordType: UInt8 {
        case document = 1
        case pdf = 2
        case stroke = 15
        case shape = 18
        case media = 22
        case erase = 25
    }

    /// Parses an `.ntb` package (already opened as a zip or directory).
    ///
    /// - Throws: `ImportError.notability` when there is no `noteBundle` or it
    ///   is not a bundle this reader understands.
    public static func parse(package pkg: NotePackage) throws -> NotabilityNote {
        guard let path = pkg.paths.first(where: { $0 == "noteBundle" })
                ?? pkg.paths.first(where: { $0.hasSuffix("/noteBundle") && $0.split(separator: "/").count == 2 }) else {
            throw ImportError.notability("no noteBundle in .ntb package")
        }
        return try parse(bundle: pkg.read(path))
    }

    /// How many bytes of geometry and erase lists one parse may decode, per
    /// byte of bundle. FlatBuffers references can point many records at one
    /// payload, so without a limit a small buffer could decode into
    /// gigabytes of points. A real bundle decodes each payload once (at most
    /// its own size); the factor leaves room for a writer that shares some.
    static let decodeBudgetFactor = 4

    /// Parses the bytes of a `noteBundle`.
    ///
    /// - Throws: `ImportError.notability` when the bundle is malformed or
    ///   references its payloads so often that decoding would exceed
    ///   `decodeBudgetFactor` times its size.
    public static func parse(bundle data: Data) throws -> NotabilityNote {
        let fb = FlatBuffer(data)
        var budget = Budget(limit: decodeBudgetFactor * data.count + 65_536)
        let root = try fb.root()
        guard let recordsField = try fb.field(root, 6) else {
            throw ImportError.notability(".ntb: no record list")
        }
        let records = try fb.tables(atVectorRef: recordsField)
        let createdMs = try fb.field(root, 4).map { try fb.i64($0) }

        var title: String?
        var page: (w: Double, h: Double)?
        var paperPattern: Int?
        var paperSpacing: Double?
        var lastEdit: Int64?
        var curves: [NotabilityNote.Curve] = []
        var lines: [NotabilityNote.Curve] = []
        var placed: [(curve: Int, page: Int)] = []   // stroke and line indices with their page
        var originX: [Float] = []   // per stroke, as stored
        var pdfs = 0, media = 0, unsupportedStrokes = 0, unsupportedShapes = 0, dashed = Set<Int>()

        // Erase records list the ids of the stroke and shape records they
        // remove (bundles written as a log, without a `.note` next to them;
        // bundles next to a `.note` are compacted and hold none).
        var erased = Set<UInt64>()
        for record in records {
            guard let tf = try fb.field(record, 4), try fb.u8(tf) == RecordType.erase.rawValue,
                  let pf = try fb.field(record, 5) else { continue }
            let payload = try fb.table(atRef: pf)
            guard let list = try fb.field(payload, 0) else { continue }
            let (start, count) = try fb.vector(atRef: list, elementSize: 8)
            try budget.spend(8 * count)
            for i in 0..<count { erased.insert(try fb.recordID(start + 8 * i)) }
        }
        var erasedCount = 0

        for record in records {
            if !erased.isEmpty, let idField = try fb.field(record, 0), erased.contains(try fb.recordID(idField)) {
                erasedCount += 1
                continue
            }
            if let t = try fb.field(record, 1) {
                let ms = try fb.i64(t)
                lastEdit = max(lastEdit ?? ms, ms)
            }
            guard let typeField = try fb.field(record, 4), let type = RecordType(rawValue: try fb.u8(typeField)) else {
                continue
            }
            guard let payloadField = try fb.field(record, 5) else { continue }
            let payload = try fb.table(atRef: payloadField)
            switch type {
            case .document:
                // Every record may point at one shared title: charge its bytes.
                try budget.spend(64)
                if let f = try fb.field(payload, 0), let s = try fb.field(fb.table(atRef: f), 0) {
                    try budget.spend(try fb.vector(atRef: s, elementSize: 1).count)
                    title = try fb.string(atRef: s)
                }
                if let f = try fb.field(payload, 1), let l = try fb.field(fb.table(atRef: f), 0) {
                    let layout = try fb.table(atRef: l)
                    if let size = try fb.field(layout, 3) {
                        page = (Double(try fb.f32(size)), Double(try fb.f32(size + 4)))
                    }
                    if let p = try fb.field(layout, 0) {
                        let paper = try fb.table(atRef: p)
                        paperPattern = try fb.field(paper, 0).map { Int(try fb.u8($0)) }
                        paperSpacing = try fb.field(paper, 1).map { Double(try fb.f32($0)) }
                    }
                }
            case .pdf:
                pdfs += 1
            case .media:
                media += 1
            case .erase:
                break
            case .stroke:
                guard let pieces = try stroke(fb, payload, budget: &budget) else { unsupportedStrokes += 1; continue }
                let isDashed = try fb.field(payload, 5).map { try fb.u8($0) != 0 } ?? false
                let pg = try pageIndex(fb, payload)
                let ox = try fb.field(payload, 1).map { try fb.f32($0) } ?? 0
                for curve in pieces {
                    if isDashed { dashed.insert(curves.count) }
                    placed.append((curves.count, pg))
                    originX.append(ox)
                    curves.append(curve)
                }
            case .shape:
                try budget.spend(64)
                guard let curve = try line(fb, payload) else { unsupportedShapes += 1; continue }
                placed.append((-(lines.count + 1), try pageIndex(fb, payload)))
                lines.append(curve)
            }
        }

        let width = page.map(\.w).flatMap(NotabilityNote.plausibleWidth) ?? NotabilityNote.defaultWidth
        let pageHeight = page.flatMap { NotabilityNote.plausibleAspect($0.h / width).map { $0 * width } }
            ?? width * NotabilityNote.defaultPageAspect
        // Bundle coordinates are page coordinates (x from the page edge, y
        // from the page's top); `.note` coordinates are continuous with x = 0
        // at `insetX`. Not the bundle's recorded margin: newer letter-size
        // notes record 36 there while their points are still page coordinates.
        let inset = width * NotabilityNote.horizontalInsetFraction
        func place(_ c: inout NotabilityNote.Curve, page: Int) {
            let dy = Double(page) * pageHeight
            c.points = c.points.map { NotabilityNote.Point(x: $0.x - inset, y: $0.y + dy) }
        }
        for (index, pg) in placed {
            if index >= 0 { place(&curves[index], page: pg) } else { place(&lines[-index - 1], page: pg) }
        }
        for i in dashed { curves[i].dashed = true }
        // A stroke that starts beyond the right page edge is stored with its
        // origin clamped to the edge (seen on notes whose ink overhangs the
        // page): its shape is right, its position is not recoverable.
        if let w = page?.w {
            for i in curves.indices where originX[i] == Float(w) { curves[i].originClamped = true }
        }
        let all = curves + lines
        guard all.allSatisfy({ $0.points.allSatisfy { abs($0.x) <= NotabilityNote.maxCoordinate
                && abs($0.y) <= NotabilityNote.maxCoordinate } }) else {
            throw ImportError.notability(".ntb: coordinates beyond ±\(Int(NotabilityNote.maxCoordinate))")
        }

        let kind: PaperKind
        switch paperPattern {
        case 0?: kind = .ruled
        case 1?: kind = .dot
        case 2?: kind = .grid
        default: kind = .blank
        }
        let spacing = kind == .blank ? nil : paperSpacing.flatMap { $0.isFinite && $0 > 0 && $0 < width ? $0 : nil }
        // Dates the vault cannot store (beyond years 0001...9999) are dropped,
        // as for a `.note` (`NotabilityNote.writable`): the import would
        // otherwise trap turning them back into milliseconds.
        func date(_ ms: Int64?) -> Date? {
            ms.flatMap { NotabilityNote.writable(Date(timeIntervalSince1970: Double($0) / 1000)) }
        }
        let created = date(createdMs)
        var note = NotabilityNote(
            metadata: .init(name: title.map { $0.isEmpty ? "Untitled" : $0 } ?? "Untitled", created: created),
            paper: .init(width: width, pageHeight: pageHeight, kind: kind, spacing: spacing),
            curves: all, pdfCount: pdfs, mediaCount: media)
        note.sourceFormat = .ntb
        note.bundleModified = date(lastEdit)
        note.shapeCount = lines.count
        note.unsupportedShapes = unsupportedShapes
        note.unsupportedStrokes = unsupportedStrokes
        note.clampedStrokes = curves.filter(\.originClamped).count
        note.erasedRecords = erasedCount
        return note
    }

    /// The 0-based page of a stroke or shape record (third word of its field 0).
    static func pageIndex(_ fb: FlatBuffer, _ payload: Int) throws -> Int {
        guard let f = try fb.field(payload, 0) else { return 0 }
        let page = Int(try fb.u32(f + 8))
        guard page < 100_000 else { throw ImportError.notability(".ntb: page index \(page)") }
        return page
    }

    /// A stroke record: origin (field 1), tool (4; 2 is the highlighter),
    /// colour RGBA (7), width (8) and the geometry bytes (9). One curve per
    /// piece (an erased gap splits a stroke into pieces, where a `.note` has
    /// separate curves). Nil for a geometry this reader does not decode.
    static func stroke(_ fb: FlatBuffer, _ p: Int, budget: inout Budget) throws -> [NotabilityNote.Curve]? {
        guard let o = try fb.field(p, 1), let g = try fb.field(p, 9) else { return nil }
        let x0 = Double(try fb.f32(o)), y0 = Double(try fb.f32(o + 4))
        try budget.spend(try fb.vector(atRef: g, elementSize: 1).count)
        let blob = try fb.bytes(atVectorRef: g)
        guard let pieces = geometry(blob, x0: x0, y0: y0) else { return nil }
        let color = try fb.field(p, 7).map { f in
            Color(r: try fb.u8(f), g: try fb.u8(f + 1), b: try fb.u8(f + 2), a: try fb.u8(f + 3))
        } ?? Color(r: 0, g: 0, b: 0, a: 255)
        let width = try fb.field(p, 8).map { Double(try fb.f32($0)) } ?? NotabilityNote.defaultCurveWidth
        let tool = try fb.field(p, 4).map { try fb.u8($0) } ?? 0
        guard width.isFinite, width > 0, width <= NotabilityNote.maxCoordinate else { return nil }
        return pieces.map { geo in
            NotabilityNote.Curve(points: geo.points, fractionalWidths: geo.fw, forces: geo.forces,
                                 altitudes: geo.altitudes, azimuths: geo.azimuths, width: width, color: color,
                                 style: tool == 2 ? NotabilityNote.highlighterStyle : NotabilityNote.penStyle)
        }
    }

    /// Decoded geometry of one piece of a stroke.
    struct Geometry {
        var points: [NotabilityNote.Point]
        var fw: [Double], forces: [Double], altitudes: [Double], azimuths: [Double]
    }

    /// The geometry bytes of a stroke: an 8-byte header (precision, node
    /// count as little-endian u16, kind 3, four zero bytes), for float32
    /// precision four more bytes, then the first node and one segment per
    /// further node. A node is the width multiplier and force (half floats)
    /// plus altitude and azimuth bytes. A segment is a flags byte, the two
    /// control points and the end point as (x, y) offsets from the stroke's
    /// origin (half floats, or float32 when the precision byte is 1), then its
    /// end node. Flags 3 (both control points omitted) is a jump: the end
    /// point starts a new piece, nothing is drawn in between (verified against
    /// the `.note` copies, which hold the pieces as separate curves). Other
    /// flags were never seen and are rejected.
    static func geometry(_ b: Data, x0: Double, y0: Double) -> [Geometry]? {
        let bytes = [UInt8](b)
        guard bytes.count >= 14, bytes[3] == 3, bytes[0] <= 1 else { return nil }
        let wide = bytes[0] == 1
        let n = Int(bytes[1]) | Int(bytes[2]) << 8
        guard n >= 1 else { return nil }
        var pos = wide ? 12 : 8
        func half(_ i: Int) -> Double {
            NotabilityNote.half(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
        }
        func float(_ i: Int) -> Double {
            Double(Float(bitPattern: UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16
                         | UInt32(bytes[i + 3]) << 24))
        }
        var pieces: [Geometry] = []
        var g = Geometry(points: [NotabilityNote.Point(x: x0, y: y0)], fw: [], forces: [], altitudes: [], azimuths: [])
        func node() -> Bool {
            guard pos + 6 <= bytes.count else { return false }
            g.fw.append(half(pos)); g.forces.append(half(pos + 2))
            g.altitudes.append(Double(bytes[pos + 4]) / 255 * .pi / 2)
            g.azimuths.append(Double(bytes[pos + 5]) / 255 * 2 * .pi)
            pos += 6
            return true
        }
        func offset() -> NotabilityNote.Point? {
            let size = wide ? 8 : 4
            guard pos + size <= bytes.count else { return nil }
            let dx = wide ? float(pos) : half(pos), dy = wide ? float(pos + 4) : half(pos + 2)
            pos += size
            return NotabilityNote.Point(x: x0 + dx, y: y0 + dy)
        }
        guard node() else { return nil }
        for _ in 1..<max(n, 1) {
            guard pos < bytes.count else { return nil }
            let flags = bytes[pos]
            pos += 1
            switch flags {
            case 0:
                guard let c1 = offset(), let c2 = offset(), let end = offset() else { return nil }
                g.points += [c1, c2, end]
                guard node() else { return nil }
            case 3:
                guard let start = offset() else { return nil }
                pieces.append(g)
                g = Geometry(points: [start], fw: [], forces: [], altitudes: [], azimuths: [])
                guard node() else { return nil }
            default:
                return nil
            }
        }
        pieces.append(g)
        guard pos == bytes.count,
              pieces.allSatisfy({ $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } && $0.fw.allSatisfy(\.isFinite) })
        else { return nil }
        return pieces
    }

    /// A straight-line shape record: origin (field 1), kind 1 (field 4), the
    /// end point as an offset (field 5 → field 3), colour (9), width (10).
    static func line(_ fb: FlatBuffer, _ p: Int) throws -> NotabilityNote.Curve? {
        guard let k = try fb.field(p, 4), try fb.u8(k) == 1, let o = try fb.field(p, 1),
              let gf = try fb.field(p, 5) else { return nil }
        let geo = try fb.table(atRef: gf)
        guard let e = try fb.field(geo, 3) else { return nil }
        let a = NotabilityNote.Point(x: Double(try fb.f32(o)), y: Double(try fb.f32(o + 4)))
        let b = NotabilityNote.Point(x: a.x + Double(try fb.f32(e)), y: a.y + Double(try fb.f32(e + 4)))
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let color = try fb.field(p, 9).map { f in
            Color(r: try fb.u8(f), g: try fb.u8(f + 1), b: try fb.u8(f + 2), a: try fb.u8(f + 3))
        } ?? Color(r: 0, g: 0, b: 0, a: 255)
        let width = try fb.field(p, 10).map { Double(try fb.f32($0)) } ?? NotabilityNote.defaultCurveWidth
        guard width.isFinite, width > 0, width <= NotabilityNote.maxCoordinate else { return nil }
        return NotabilityNote.Curve(points: NotabilityShapes.line(a, b), fractionalWidths: [1, 1], width: width,
                                    color: color, style: NotabilityNote.penStyle)
    }
}

extension NotabilityBundle {
    /// Decoding work left for one parse (`decodeBudgetFactor`).
    struct Budget {
        var limit: Int
        var used = 0

        mutating func spend(_ n: Int) throws {
            used += n
            guard used <= limit else {
                throw ImportError.notability(".ntb: decode budget exceeded (payloads referenced repeatedly)")
            }
        }
    }
}

/// A read-only, bounds-checked view of a FlatBuffers buffer, read without a
/// schema: tables by field index, references, vectors and strings.
struct FlatBuffer {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }

    func check(_ pos: Int, _ size: Int) throws {
        guard pos >= 0, size >= 0, pos <= bytes.count - size else {
            throw ImportError.notability(".ntb: read of \(size) bytes at \(pos) beyond \(bytes.count)")
        }
    }

    func u8(_ p: Int) throws -> UInt8 { try check(p, 1); return bytes[p] }
    func u16(_ p: Int) throws -> Int { try check(p, 2); return Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
    func u32(_ p: Int) throws -> UInt32 {
        try check(p, 4)
        return UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
    }
    func i32(_ p: Int) throws -> Int { Int(Int32(bitPattern: try u32(p))) }
    func i64(_ p: Int) throws -> Int64 {
        Int64(bitPattern: UInt64(try u32(p)) | UInt64(try u32(p + 4)) << 32)
    }
    func f32(_ p: Int) throws -> Float { Float(bitPattern: try u32(p)) }
    /// A record id: the (u32, u32) struct at `p` as one 64-bit key.
    func recordID(_ p: Int) throws -> UInt64 { UInt64(try u32(p)) << 32 | UInt64(try u32(p + 4)) }

    /// The root table's position.
    func root() throws -> Int { try table(Int(try u32(0))) }

    /// Validates a table position (its vtable must lie inside the buffer).
    func table(_ t: Int) throws -> Int {
        let vt = t - (try i32(t))
        let size = try u16(vt)
        guard size >= 4, size % 2 == 0 else { throw ImportError.notability(".ntb: bad vtable at \(vt)") }
        try check(vt, size)
        return t
    }

    /// The absolute position of field `index` of the table at `t`, or nil when absent.
    func field(_ t: Int, _ index: Int) throws -> Int? {
        let vt = t - (try i32(t))
        let size = try u16(vt)
        let slot = 4 + 2 * index
        guard slot + 2 <= size else { return nil }
        let off = try u16(vt + slot)
        guard off != 0 else { return nil }
        let tableSize = try u16(vt + 2)
        guard off < tableSize else { throw ImportError.notability(".ntb: field outside its table at \(t)") }
        return t + off
    }

    /// Follows the reference stored at `p` (an unsigned offset from `p`).
    func ref(_ p: Int) throws -> Int {
        let target = p + Int(try u32(p))
        try check(target, 4)
        return target
    }

    func table(atRef p: Int) throws -> Int { try table(ref(p)) }

    /// The element count and first-element position of the vector referenced at `p`.
    func vector(atRef p: Int, elementSize: Int) throws -> (start: Int, count: Int) {
        let v = try ref(p)
        let count = Int(try u32(v))
        guard count <= (bytes.count - v - 4) / max(elementSize, 1) else {
            throw ImportError.notability(".ntb: vector of \(count) overruns the buffer")
        }
        return (v + 4, count)
    }

    func tables(atVectorRef p: Int) throws -> [Int] {
        let (start, count) = try vector(atRef: p, elementSize: 4)
        return try (0..<count).map { try table(atRef: start + 4 * $0) }
    }

    func bytes(atVectorRef p: Int) throws -> Data {
        let (start, count) = try vector(atRef: p, elementSize: 1)
        return Data(bytes[start..<(start + count)])
    }

    func string(atRef p: Int) throws -> String {
        let d = try bytes(atVectorRef: p)
        return String(decoding: d, as: UTF8.self)
    }
}
