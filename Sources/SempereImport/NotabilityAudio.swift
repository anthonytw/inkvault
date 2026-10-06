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

// MARK: - Resolution (D4)

extension NotabilityAttachments {
    /// Recordings from `Recordings/`: each library entry with the audio file
    /// it names (or, when entries name none, the files in name order), stored
    /// as a blob in its own container (`audio/mp4`, `audio/x-caf`, …; format.md
    /// §8.3.1 allows importers other types). Then `eventTokens` become the
    /// strokes' `rec` where they read as times in the recording.
    mutating func resolveRecordings(_ note: NotabilityNote, _ pkg: NotePackage, prefix: String) {
        let dir = prefix + "Recordings/"
        let files = pkg.paths.filter { $0.hasPrefix(dir) && !$0.hasSuffix("/library.plist") && !$0.hasSuffix("/") }
            .map { String($0.dropFirst(prefix.count)) }.sorted()
        let entries = note.recordingEntries
        var pairs: [(entry: NotabilityNote.RecordingEntry?, file: String)] = []
        var claimed = Set<String>()
        var unmatched: [NotabilityNote.RecordingEntry] = []
        for e in entries {
            let m = NotabilityNote.MediaObject(className: "recording", strings: e.strings)
            if let f = Self.file(for: m, in: files), !claimed.contains(f) {
                pairs.append((e, f)); claimed.insert(f)
            } else {
                unmatched.append(e)
            }
        }
        let free = files.filter { !claimed.contains($0) }
        if !unmatched.isEmpty, unmatched.count == free.count {
            pairs += zip(unmatched, free).map { ($0, $1) }
            warnings.append("\(unmatched.count) recording(s) paired with the audio files by order: the library names no file "
                            + "(fields: \(Set(unmatched.flatMap(\.fieldNames)).sorted().joined(separator: ", ")))")
            unmatched = []
        } else if entries.isEmpty, !free.isEmpty {
            pairs += free.map { (nil, $0) }
            warnings.append("\(free.count) audio file(s) in Recordings/ without a library entry imported without title")
        }
        for e in unmatched {
            dropped.recordings += 1
            warnings.append("recording \(e.key): no audio file found (fields: \(e.fieldNames.joined(separator: ", ")))")
        }
        for (n, pair) in pairs.enumerated() {
            let label = "recording \(pair.entry?.key ?? String(n + 1)) (\(pair.file))"
            guard recordings.count < 1_000 else { dropped.recordings += 1; continue }
            let data: Data
            do { data = try pkg.read(prefix + pair.file) } catch {
                dropped.recordings += 1
                warnings.append("\(label): cannot be read (\(NotabilityImporter.describe(error)))"); continue
            }
            guard let info = AudioInfo.read(data) else {
                dropped.recordings += 1
                warnings.append("\(label): not an audio container this importer knows (MPEG-4, CAF, WAV, AIFF, MP3)"); continue
            }
            var started = pair.entry?.started
            if started == nil {
                started = note.metadata.created
                warnings.append("\(label): no start date in the library; the note's creation date is used")
            }
            let ref = BlobRef(content: data, type: info.type)
            if blobs[ref.sha256] == nil { blobs[ref.sha256] = (ref, data) }
            let duration = (pair.entry?.duration ?? info.duration).map { ($0 * 1000).rounded() / 1000 }
            recordings.append(Recording(blob: ref, started: started ?? Date(timeIntervalSince1970: 0), duration: duration,
                                        codec: info.codec, sampleRate: info.sampleRate, channels: info.channels,
                                        title: pair.entry?.title))
            imported.recordings += 1
        }
        linkStrokes(note)
    }

    /// Reads `eventTokens` as milliseconds from the start of the note's one
    /// recording — a hypothesis (docs/attachments.md §11, unknown 7) applied
    /// only when it is plausible: one recording with a duration, every token
    /// within it, and the tokens of successive curves mostly ascending (90 %),
    /// as times of writing are. Otherwise no `rec` is written and the report
    /// gives the tokens' range, so the encoding can be worked out.
    mutating func linkStrokes(_ note: NotabilityNote) {
        let tokens = note.curves.enumerated().compactMap { i, c in c.eventToken.map { (i, Int64($0)) } }
        guard !tokens.isEmpty else { return }
        let lo = tokens.map(\.1).min() ?? 0, hi = tokens.map(\.1).max() ?? 0
        let ascending = zip(tokens, tokens.dropFirst()).filter { $0.1 <= $1.1 }.count
        let orderly = tokens.count < 2 || Double(ascending) >= 0.9 * Double(tokens.count - 1)
        if recordings.count == 1, let duration = recordings[0].duration, lo >= 0,
           Double(hi) <= duration * 1000 + 1000, orderly {
            for (i, t) in tokens { strokeLinks[i] = StrokeLink(recording: 0, at: Double(t) / 1000) }
            imported.recLinkedStrokes = tokens.count
            warnings.append("\(tokens.count) stroke(s) linked to the recording from eventTokens read as milliseconds "
                            + "(\(lo)…\(hi) in a \(duration) s recording; unconfirmed, check by listening)")
        } else {
            dropped.recLinks = tokens.count
            warnings.append("\(tokens.count) stroke(s) carry eventTokens \(lo)…\(hi) (\(ascending) of \(tokens.count - 1) "
                            + "ascending) with \(recordings.count) recording(s): not read as times, no rec written")
        }
    }
}
