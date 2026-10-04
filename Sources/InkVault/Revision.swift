import Foundation

/// Errors from the note log (revisions, reconstruction, snapshots).
public enum NoteLogError: Error, Hashable, Sendable {
    /// Reconstruction or a snapshot needs at least one revision.
    case noRevisions
    /// Revisions from two different notes were mixed.
    case mixedNotes(UUID, UUID)
    /// Two revisions claim the same `(device, seq)` with different content.
    case conflictingRevisions(device: DeviceID, seq: Int)
    /// A delta was required but something else was given.
    case notADelta(RevisionName)
}

// MARK: - File names

/// `<hlc>-<device>-<seq>.<delta|snapshot>.age` (format.md §5).
public struct RevisionName: Hashable, Comparable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        case delta, snapshot
    }

    /// Clock reading when the revision was written.
    public var hlc: HLC
    /// Writing device.
    public var device: DeviceID
    /// Per (note, device) counter, starting at 1.
    public var seq: Int
    /// Delta or snapshot.
    public var kind: Kind

    public init(hlc: HLC, device: DeviceID, seq: Int, kind: Kind) {
        self.hlc = hlc; self.device = device; self.seq = seq; self.kind = kind
    }

    /// Parses a file base name. Rejects non-canonical `seq` (leading zeros, 0).
    public init?(_ filename: String) {
        let dot = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard dot.count == 3, dot[2] == "age", let kind = Kind(rawValue: String(dot[1])) else { return nil }
        let dash = dot[0].split(separator: "-", omittingEmptySubsequences: false)
        guard dash.count == 3,
              let hlc = HLC(String(dash[0])),
              let device = DeviceID(String(dash[1])) else { return nil }
        let s = dash[2]
        guard !s.isEmpty, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s.first != "0",
              let seq = Int(s) else { return nil }
        self.init(hlc: hlc, device: device, seq: seq, kind: kind)
    }

    /// The file base name.
    public var filename: String { "\(hlc)-\(device)-\(seq).\(kind.rawValue).age" }
    public var description: String { filename }

    /// The LWW stamp of ops in this revision.
    public var stamp: Stamp { Stamp(hlc: hlc, device: device) }

    /// Total order `(hlc, device, seq)`; `kind` only breaks ties between
    /// malformed duplicates.
    public static func < (l: RevisionName, r: RevisionName) -> Bool {
        (l.hlc, l.device, l.seq, l.kind.rawValue) < (r.hlc, r.device, r.seq, r.kind.rawValue)
    }
}

// MARK: - origin

/// Which op added a page or stroke: `"<hlc>-<device>-<seq>-<op>"`, the adding
/// revision's ordering key plus the op's index in it (format.md §5.5–§5.6).
/// Strokes on a page render in origin order.
public struct Origin: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// `hlc` of the adding revision.
    public var hlc: HLC
    /// Device of the adding revision.
    public var device: DeviceID
    /// `seq` of the adding revision; at least 1 in any parsed origin.
    public var seq: Int
    /// Index of the adding op within the revision's `ops`, from 0.
    public var op: Int

    public init(hlc: HLC, device: DeviceID, seq: Int, op: Int) {
        self.hlc = hlc; self.device = device; self.seq = seq; self.op = op
    }

    public init(_ name: RevisionName, op: Int) {
        self.init(hlc: name.hlc, device: name.device, seq: name.seq, op: op)
    }

    /// Parses `"<hlc>-<device>-<seq>-<op>"`; rejects `seq` 0 and leading zeros.
    public init?(_ string: String) {
        let p = string.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 4, let h = HLC(String(p[0])), let d = DeviceID(String(p[1])),
              let seq = Origin.decimal(p[2]), seq >= 1, let op = Origin.decimal(p[3]) else { return nil }
        self.init(hlc: h, device: d, seq: seq, op: op)
    }

    private static func decimal(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.utf8.allSatisfy({ (0x30...0x39).contains($0) }), s == "0" || s.first != "0" else { return nil }
        return Int(s)
    }

    public var description: String { "\(hlc)-\(device)-\(seq)-\(op)" }

    public static func < (l: Origin, r: Origin) -> Bool {
        (l.hlc, l.device, l.seq, l.op) < (r.hlc, r.device, r.seq, r.op)
    }
}

// MARK: - included

/// The set of revisions a snapshot reflects (format.md §5.3): per device,
/// every `seq ≤ upTo` plus the listed `extra`.
public struct Included: Hashable, Sendable {
    /// Coverage for one device.
    public struct Entry: Hashable, Sendable, Codable {
        /// Every `seq` from 1 through `upTo` is covered (inclusive; may be 0).
        public var upTo: Int
        /// Sorted, all greater than `upTo + 1`.
        public var extra: [Int]

        public init(upTo: Int = 0, extra: [Int] = []) {
            self.upTo = upTo
            self.extra = extra
            normalize()
        }

        /// True for a covered `seq`; never for `seq < 1`.
        public func covers(_ seq: Int) -> Bool { seq >= 1 && (seq <= upTo || extra.contains(seq)) }

        mutating func insert(_ seq: Int) {
            guard seq >= 1, !covers(seq) else { return }
            extra.append(seq)
            normalize()
        }

        mutating func normalize() {
            upTo = max(upTo, 0)
            var set = Set(extra.filter { $0 > upTo })
            while set.remove(upTo + 1) != nil { upTo += 1 }
            extra = set.sorted()
        }
    }

    /// Per-device coverage; devices without an entry cover nothing.
    public private(set) var entries: [DeviceID: Entry]

    public init(_ entries: [DeviceID: Entry] = [:]) {
        self.entries = entries.mapValues { var e = $0; e.normalize(); return e }
    }

    /// True when the revision `(device, seq)` is reflected.
    public func covers(device: DeviceID, seq: Int) -> Bool {
        entries[device]?.covers(seq) ?? false
    }

    /// Adds one revision, folding contiguous extras into `upTo`.
    public mutating func insert(device: DeviceID, seq: Int) {
        guard seq >= 1 else { return }
        entries[device, default: Entry()].insert(seq)
    }

    /// True when every revision `other` covers is also covered here.
    public func isSuperset(of other: Included) -> Bool {
        for (device, theirs) in other.entries {
            let mine = entries[device] ?? Entry()
            if theirs.upTo > mine.upTo {
                // The gap must be filled by `extra`; too few extras cannot.
                guard theirs.upTo - mine.upTo <= mine.extra.count else { return false }
                let extras = Set(mine.extra)
                guard ((mine.upTo + 1)...theirs.upTo).allSatisfy(extras.contains) else { return false }
            }
            guard theirs.extra.allSatisfy(mine.covers) else { return false }
        }
        return true
    }

    /// Everything covered by either.
    public func union(_ other: Included) -> Included {
        var out = self
        for (device, e) in other.entries {
            var mine = out.entries[device] ?? Entry()
            mine.upTo = max(mine.upTo, e.upTo)
            mine.extra += e.extra
            mine.normalize()
            out.entries[device] = mine
        }
        return out
    }
}

extension Included: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Entry].self)
        var entries: [DeviceID: Entry] = [:]
        for (k, v) in raw {
            guard let d = DeviceID(k) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad device id \(k)"))
            }
            entries[d] = v
        }
        self.init(entries)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
    }
}

// MARK: - Revision envelope

/// One file under `notes/<noteId>/` (format.md §5.1–§5.3), decrypted and
/// unframed. Pure value; reading and writing files is elsewhere.
public struct Revision: Hashable, Sendable {
    /// The type-specific part of a revision.
    public enum Body: Hashable, Sendable {
        /// Ops applied in order (format.md §5.2).
        case delta(ops: [Op])
        /// Full state plus the revisions it reflects (format.md §5.3).
        case snapshot(included: Included, state: NoteState)
    }

    /// Note directory name; lowercase on the wire.
    public var noteId: UUID
    /// Writing device.
    public var device: DeviceID
    /// Per (note, device) counter, starting at 1, gap-free.
    public var seq: Int
    /// Clock reading when written; the LWW timestamp of the revision's ops.
    public var hlc: HLC
    /// Informational (history UI).
    public var wall: Date
    /// Informational, e.g. `inkvault-ios/0.1`.
    public var app: String
    /// Delta ops or snapshot content.
    public var body: Body

    public init(noteId: UUID, device: DeviceID, seq: Int, hlc: HLC, wall: Date, app: String, body: Body) {
        self.noteId = noteId; self.device = device; self.seq = seq; self.hlc = hlc
        self.wall = wall; self.app = app; self.body = body
    }

    public var kind: RevisionName.Kind {
        if case .delta = body { return .delta }
        return .snapshot
    }

    /// The file name this revision is stored under.
    public var name: RevisionName { RevisionName(hlc: hlc, device: device, seq: seq, kind: kind) }

    /// LWW stamp for this revision's ops.
    public var stamp: Stamp { Stamp(hlc: hlc, device: device) }
}

extension Revision: Codable {
    enum CodingKeys: String, CodingKey { case type, noteId, device, seq, hlc, wall, app, ops, included, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noteId = try c.decode(LowercaseUUID.self, forKey: .noteId).uuid
        device = try c.decode(DeviceID.self, forKey: .device)
        seq = try c.decode(Int.self, forKey: .seq)
        guard seq >= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .seq, in: c, debugDescription: "seq must be ≥ 1")
        }
        hlc = try c.decode(HLC.self, forKey: .hlc)
        wall = try c.decode(Date.self, forKey: .wall)
        app = try c.decode(String.self, forKey: .app)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "delta":
            body = .delta(ops: try c.decode([Op].self, forKey: .ops))
        case "snapshot":
            body = .snapshot(included: try c.decode(Included.self, forKey: .included),
                             state: try c.decode(NoteState.self, forKey: .state))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown revision type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .type)
        try c.encode(LowercaseUUID(noteId), forKey: .noteId)
        try c.encode(device, forKey: .device)
        try c.encode(seq, forKey: .seq)
        try c.encode(hlc, forKey: .hlc)
        try c.encode(wall, forKey: .wall)
        try c.encode(app, forKey: .app)
        switch body {
        case .delta(let ops):
            try c.encode(ops, forKey: .ops)
        case .snapshot(let included, let state):
            try c.encode(included, forKey: .included)
            try c.encode(state, forKey: .state)
        }
    }
}
