import Foundation
import Sempere

// Recordings of a Notability note (docs/import-notability.md "Recordings",
// docs/attachments.md §11, task D4): `Recordings/library.plist` entries, the
// audio files next to it, and `eventTokens` linking curves to them. The
// library's field names are not confirmed, so entries are read like media
// objects: candidate names, recorded in the report.

extension NotabilityNote {
    /// One entry of `Recordings/library.plist`'s `recordings`.
    public struct RecordingEntry: Hashable, Sendable {
        /// The entry's key in `recordings` (or its index, for an array).
        public var key: String
        public var fieldNames: [String]
        /// Every string value in the entry: one may name the audio file.
        public var strings: [String]
        public var title: String?
        public var started: Date?
        public var duration: Double?

        public init(key: String, fieldNames: [String] = [], strings: [String] = [], title: String? = nil,
                    started: Date? = nil, duration: Double? = nil) {
            self.key = key; self.fieldNames = fieldNames; self.strings = strings; self.title = title
            self.started = started; self.duration = duration
        }
    }

    /// Entries read at most (format.md §8.4 allows 1 000 recordings per note).
    static let maxRecordingEntries = 1_000

    /// The entries of `Recordings/library.plist` (an XML plist), sorted by key.
    static func parseRecordingEntries(_ data: Data?) throws -> [RecordingEntry] {
        guard let data, case .dict(let root) = try PlistValue.parse(data, allowXML: true) else { return [] }
        var raw: [(String, PlistValue)] = []
        switch root["recordings"] {
        case .dict(let d)?: raw = d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        case .array(let a)?: raw = a.enumerated().map { (String($0.offset), $0.element) }
        default: return []
        }
        return raw.prefix(maxRecordingEntries).map { key, value in
            var leaves: [(path: [String], value: PlistValue)] = []
            var budget = MediaObject.maxValues
            flatten(value, path: [], depth: 0, budget: &budget, into: &leaves)
            var e = RecordingEntry(key: key)
            if case .dict(let d) = value { e.fieldNames = d.keys.sorted() }
            func first<T>(_ match: (String) -> Bool, _ get: (PlistValue) -> T?) -> T? {
                leaves.filter { l in l.path.last.map { match($0.lowercased()) } ?? false }
                    .min { $0.path.count < $1.path.count }
                    .flatMap { get($0.value) }
            }
            e.strings = leaves.compactMap { $0.value.string }
            e.title = first({ ["name", "title", "displayname", "recordingname", "label"].contains($0) }) { $0.string }
            e.started = first({ $0.contains("date") || $0.contains("start") || $0.contains("created") }) { v in
                if case .date(let d) = v { return NotabilityNote.writable(d) }
                return nil
            }
            e.duration = first({ $0.contains("duration") || $0 == "length" || $0 == "seconds" }) { v in
                v.double.flatMap { $0.isFinite && $0 >= 0 && $0 < 1e7 ? $0 : nil }
            }
            return e
        }
    }

    static func flatten(_ v: PlistValue, path: [String], depth: Int, budget: inout Int,
                        into out: inout [(path: [String], value: PlistValue)]) {
        guard budget > 0 else { return }
        budget -= 1
        switch v {
        case .dict(let d):
            guard depth < MediaObject.maxDepth else { return }
            for (k, x) in d.sorted(by: { $0.key < $1.key }) {
                flatten(x, path: path + [k], depth: depth + 1, budget: &budget, into: &out)
            }
        case .array(let a):
            guard depth < MediaObject.maxDepth else { return }
            for (i, x) in a.prefix(MediaObject.maxArray).enumerated() {
                flatten(x, path: path + ["[\(i)]"], depth: depth + 1, budget: &budget, into: &out)
            }
        default:
            out.append((path, v))
        }
    }

    /// `eventTokens`: 4 bytes per curve, little-endian; `ffffffff` (−1)
    /// means none. Nil per curve for none; empty when the array is absent or
    /// not 4 bytes per curve.
    static func eventTokens(_ d: Data, curves n: Int) -> [Int32?] {
        guard n > 0, d.count == 4 * n else { return [] }
        return d.withUnsafeBytes { raw in
            (0..<n).map { i in
                let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: Int32.self))
                return v == -1 ? nil : v
            }
        }
    }
}

/// What an audio file is, from its bytes: the media type to store and what
/// its container says about the audio (informational fields of a recording,
/// format.md §8.3.1). Every length is checked (format.md §9).
public struct AudioInfo: Hashable, Sendable {
    /// `audio/mp4`, `audio/x-caf`, `audio/wav`, `audio/aiff` or `audio/mpeg`.
    public var type: String
    public var duration: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var channels: Int?

    /// Boxes or chunks visited at most.
    static let maxBoxes = 10_000

    /// Nil when the bytes are no audio container this reader knows.
    public static func read(_ data: Data) -> AudioInfo? {
        let d = [UInt8](data)
        func at(_ i: Int, _ s: String) -> Bool { d.count >= i + s.utf8.count && Array(d[i..<(i + s.utf8.count)]) == Array(s.utf8) }
        if at(4, "ftyp") { return mp4(d) }
        if at(0, "caff") { return caf(d) }
        if at(0, "RIFF"), at(8, "WAVE") { return AudioInfo(type: "audio/wav", codec: "lpcm") }
        if at(0, "FORM"), at(8, "AIFF") || at(8, "AIFC") { return AudioInfo(type: "audio/aiff") }
        if at(0, "ID3") || (d.count >= 2 && d[0] == 0xFF && d[1] & 0xE0 == 0xE0) { return AudioInfo(type: "audio/mpeg", codec: "mp3") }
        return nil
    }

    static func be(_ d: [UInt8], _ i: Int, _ n: Int) -> UInt64? {
        guard i >= 0, n <= 8, i + n <= d.count else { return nil }
        return d[i..<(i + n)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// MPEG-4 audio: `moov/mvhd` for the duration, the first `mp4a` sample
    /// entry for channels and sample rate.
    static func mp4(_ d: [UInt8]) -> AudioInfo? {
        var info = AudioInfo(type: "audio/mp4")
        var visited = 0
        func walk(_ range: Range<Int>, depth: Int) {
            var pos = range.lowerBound
            while pos + 8 <= range.upperBound, visited < maxBoxes, depth < 8 {
                visited += 1
                guard var size = be(d, pos, 4).map(Int.init) else { return }
                let type = String(decoding: d[(pos + 4)..<(pos + 8)], as: UTF8.self)
                var header = 8
                if size == 1 {
                    guard let big = be(d, pos + 8, 8), big <= UInt64(range.upperBound - pos) else { return }
                    size = Int(big); header = 16
                } else if size == 0 { size = range.upperBound - pos }
                guard size >= header, pos + size <= range.upperBound else { return }
                let body = (pos + header)..<(pos + size)
                switch type {
                case "moov", "trak", "mdia", "minf", "stbl": walk(body, depth: depth + 1)
                case "mvhd":
                    let v1 = d[body.lowerBound] == 1
                    let scale = be(d, body.lowerBound + (v1 ? 20 : 12), 4)
                    let duration = be(d, body.lowerBound + (v1 ? 24 : 16), v1 ? 8 : 4)
                    if let scale, scale > 0, let duration, duration < UInt64(1) << 52 {
                        let s = Double(duration) / Double(scale)
                        if s.isFinite, s < 1e7 { info.duration = s }
                    }
                case "stsd":
                    // Full box, entry count, then sample entries; an audio
                    // entry has channels at +24 and a 16.16 rate at +32.
                    let entry = body.lowerBound + 8
                    if entry + 8 <= body.upperBound, info.codec == nil {
                        let name = String(decoding: d[(entry + 4)..<(entry + 8)], as: UTF8.self)
                        info.codec = name == "mp4a" ? "aac" : (name == "alac" ? "alac" : name.trimmingCharacters(in: .whitespaces))
                        if let ch = be(d, entry + 24, 2), (1...64).contains(ch) { info.channels = Int(ch) }
                        if let rate = be(d, entry + 32, 4), rate >> 16 > 0 { info.sampleRate = Int(rate >> 16) }
                    }
                default: break
                }
                pos += size
            }
        }
        walk(0..<d.count, depth: 0)
        return info
    }

    /// Core Audio Format: `desc` (rate, format, channels) and `pakt` (valid
    /// frames) or the `data` size for a constant packet size.
    static func caf(_ d: [UInt8]) -> AudioInfo? {
        var info = AudioInfo(type: "audio/x-caf")
        var rate: Double?, bytesPerPacket = 0, framesPerPacket = 0, validFrames: UInt64?, dataBytes: Int?
        var pos = 8, visited = 0
        while pos + 12 <= d.count, visited < maxBoxes {
            visited += 1
            let type = String(decoding: d[pos..<(pos + 4)], as: UTF8.self)
            guard let size = be(d, pos + 4, 8) else { break }
            let body = pos + 12
            let end = size == UInt64.max ? d.count : (size <= UInt64(d.count - body) ? body + Int(size) : -1)
            guard end >= body else { break }
            switch type {
            case "desc" where end - body >= 32:
                if let bits = be(d, body, 8) {
                    let r = Double(bitPattern: bits)
                    if r.isFinite, r > 0, r < 1e7 { rate = r; info.sampleRate = Int(r) }
                }
                let format = String(decoding: d[(body + 8)..<(body + 12)], as: UTF8.self)
                info.codec = ["aac ": "aac", "alac": "alac", "lpcm": "lpcm", "ima4": "ima4", "opus": "opus"][format]
                    ?? format.trimmingCharacters(in: .whitespaces)
                bytesPerPacket = Int(be(d, body + 16, 4) ?? 0)
                framesPerPacket = Int(be(d, body + 20, 4) ?? 0)
                if let ch = be(d, body + 24, 4), (1...64).contains(ch) { info.channels = Int(ch) }
            case "pakt" where end - body >= 24:
                validFrames = be(d, body + 8, 8)
            case "data":
                dataBytes = end - body - 4
            default: break
            }
            pos = end
        }
        if let rate {
            if let v = validFrames, v < UInt64(1) << 52 {
                info.duration = Double(v) / rate
            } else if let n = dataBytes, n > 0, bytesPerPacket > 0, framesPerPacket > 0 {
                info.duration = Double(n / bytesPerPacket) * Double(framesPerPacket) / rate
            }
        }
        return info
    }
}
