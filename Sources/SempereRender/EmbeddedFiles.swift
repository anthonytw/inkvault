import Foundation
import Sempere

/// Files a PDF export embeds (`/Names /EmbeddedFiles`, PDF 1.4): a note's
/// recordings and their transcripts as `.txt`, for "PDF + attachments"
/// (docs/attachments.md §10 "Audio in exports").
struct EmbeddedFiles {
    struct File {
        /// The file name shown by viewers (any Unicode).
        var name: String
        var mimeType: String
        var description: String
        var data: Data
        /// Audio is already compressed; text is worth deflating.
        var compress: Bool

        /// `name` with anything outside printable ASCII replaced (the `/F` entry).
        var asciiName: String {
            String(name.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F && $0 != "/" && $0 != "\\" ? Character($0) : "_" })
        }
    }

    let limit: Int
    private(set) var files: [File] = []
    private var bytes = 0
    private var usedNames: Set<String> = []

    init(limit: Int) { self.limit = limit }

    /// The recording's file name: its title (or "Recording" and its start
    /// time), made safe for file systems and unique in the PDF.
    private mutating func uniqueName(_ base: String, ext: String) -> String {
        var name = "\(base).\(ext)"
        var n = 2
        while usedNames.contains(name.lowercased()) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        usedNames.insert(name.lowercased())
        return name
    }

    static func safe(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { c -> String in
            if c.properties.generalCategory == .control || "/\\:*?\"<>|".unicodeScalars.contains(c) { return "-" }
            return String(c)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }

    static func fileExtension(_ type: String) -> String {
        let base = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch base {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/x-caf": return "caf"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        default: return "audio"
        }
    }

    /// Adds `note`'s recordings, in their order (format.md §5.4), each
    /// followed by its transcript as text when it has one. A recording that
    /// cannot be read, or would pass the size limit, is left out and reported.
    mutating func add(recordingsOf note: NoteState, blobs: (any BlobSource)?, report: inout RenderReport) {
        let title = note.meta.title.isEmpty ? "Untitled" : note.meta.title
        for r in note.recordings.sorted(by: Recording.sortsBefore) {
            let label = r.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Recording \(EmbeddedFormat.utcShort(r.started))"
            guard let blobs else {
                report.recordingsOmitted += 1
                report.warn("recordings were not embedded: no attachments were available to the export")
                continue
            }
            guard r.blob.size >= 0, bytes + Int(clamping: r.blob.size) <= limit else {
                report.recordingsOmitted += 1
                report.warn("recordings over \(limit >> 20) MiB in one PDF were left out")
                continue
            }
            let audio: Data
            do { audio = try blobs.data(for: r.blob, maxBytes: limit - bytes) } catch {
                report.recordingsOmitted += 1
                report.warn("a recording of \(title) could not be read: \(error)")
                continue
            }
            bytes += audio.count
            let base = Self.safe(label).isEmpty ? "Recording" : Self.safe(label)
            let audioName = uniqueName(base, ext: Self.fileExtension(r.blob.type))
            var desc = "\(label) – \(title), \(EmbeddedFormat.utcShort(r.started))"
            if let d = r.duration, d.isFinite { desc += ", \(Transcript.clock(d))" }
            files.append(File(name: audioName, mimeType: r.blob.type.split(separator: ";").first.map(String.init) ?? "audio/mp4",
                              description: desc, data: audio, compress: false))
            report.recordingsAttached += 1
            if let ref = r.transcript,
               let content = try? blobs.data(for: ref, maxBytes: Transcript.maxSize),
               let transcript = try? Transcript.decode(content), transcript.recording == r.id {
                let text = Data(transcript.plainText.utf8)
                bytes += text.count
                files.append(File(name: uniqueName(base, ext: "txt"), mimeType: "text/plain",
                                  description: "Transcript of \(label) (\(transcript.language), \(transcript.engine))",
                                  data: text, compress: true))
            }
        }
    }
}

/// PDF name objects.
enum PDFNames {
    /// `/audio#2Fmp4` style: a name with every byte outside the regular
    /// characters written as `#xx` (PDF 1.7 §7.3.5).
    static func name(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if b > 0x20 && b < 0x7F && !"#/()<>[]{}%".contains(c) { out.append(c) } else { out += String(format: "#%02X", b) }
        }
        return out
    }
}

enum EmbeddedFormat {
    /// `2026-10-04 16:20 UTC`.
    static func utcShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: d)
    }
}
