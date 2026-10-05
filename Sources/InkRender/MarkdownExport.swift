import Foundation
import InkVault

/// What the text exporters (Markdown, HTML) say about one note.
public struct ExportNoteInfo: Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var tags: [String]
    public var notebook: String?
    public var favorite: Bool
    public var created: Date
    public var modified: Date?
    public var pages: Int
    /// Where the note came from, e.g. `inkvault:<vault id>`.
    public var source: String

    public init(id: UUID, title: String, tags: [String], notebook: String?, favorite: Bool = false,
                created: Date, modified: Date?, pages: Int, source: String) {
        self.id = id; self.title = title; self.tags = tags; self.notebook = notebook; self.favorite = favorite
        self.created = created; self.modified = modified; self.pages = pages; self.source = source
    }

    /// The title to show: `Untitled` when empty.
    public var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

/// One row of a folder index (`README.md`) or of the HTML index.
public struct ExportIndexEntry: Hashable, Sendable {
    public var title: String
    /// Link target relative to the index file (not yet percent-encoded).
    public var href: String
    public var notebook: String?
    public var tags: [String]
    public var pages: Int
    public var modified: Date?
    /// Text the HTML index search matches besides title, notebook and tags.
    public var searchText: String

    public init(title: String, href: String, notebook: String? = nil, tags: [String] = [], pages: Int = 0,
                modified: Date? = nil, searchText: String = "") {
        self.title = title; self.href = href; self.notebook = notebook; self.tags = tags
        self.pages = pages; self.modified = modified; self.searchText = searchText
    }
}

/// Builds the text of a Markdown (Obsidian-friendly) export. File layout and
/// writing live in the CLI; everything here is a pure function.
public enum MarkdownExport {
    /// A YAML double-quoted scalar for `s`: quotes, backslashes and control
    /// characters (newline, tab, U+0085, U+2028/9, BOM, ...) are escaped, every
    /// other character (including all of Unicode) is written as is.
    public static func yamlQuoted(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    o += "\\x" + hex(u.value, 2)
                } else if u.value == 0x85 || u.value == 0x2028 || u.value == 0x2029 || u.value == 0xFEFF
                            || (0x80...0x9F).contains(u.value) {
                    o += "\\u" + hex(u.value, 4)
                } else {
                    o.unicodeScalars.append(u)
                }
            }
        }
        return o + "\""
    }

    private static func hex(_ v: UInt32, _ width: Int) -> String {
        let h = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - h.count)) + h
    }

    /// `s` on one line: every Unicode line break (CR, LF, NEL, U+2028/9) becomes a space, so
    /// a title cannot start a new Markdown block.
    static func oneLine(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            u == "\n" || u == "\r" || u.value == 0x85 || u.value == 0x2028 || u.value == 0x2029 ? " " : u
        }))
    }

    /// A tag as Obsidian accepts it: no `#`, whitespace becomes `-`. Nil when nothing is left.
    public static func obsidianTag(_ tag: String) -> String? {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        let parts = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        t = parts.joined(separator: "-")
        return t.isEmpty ? nil : t
    }

    /// `2025-10-09T14:03:20Z`.
    public static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// The YAML front matter block, `---` lines included, ending in a newline.
    public static func frontMatter(_ info: ExportNoteInfo) -> String {
        var y = "---\n"
        y += "title: \(yamlQuoted(info.title))\n"
        y += "id: \(yamlQuoted(info.id.uuidString.lowercased()))\n"
        y += "created: \(timestamp(info.created))\n"
        if let m = info.modified { y += "modified: \(timestamp(m))\n" }
        var seen = Set<String>(), tags: [String] = []
        for t in info.tags {
            guard let o = obsidianTag(t), seen.insert(NoteOps.tagKey(o)).inserted else { continue }
            tags.append(o)
        }
        if tags.isEmpty { y += "tags: []\n" } else {
            y += "tags:\n"
            for t in tags { y += "  - \(yamlQuoted(t))\n" }
        }
        if let nb = NotebookPath.canonical(info.notebook) { y += "notebook: \(yamlQuoted(nb))\n" }
        if info.favorite { y += "favorite: true\n" }
        y += "pages: \(info.pages)\n"
        y += "source: \(yamlQuoted(info.source))\n"
        return y + "---\n"
    }

    /// Percent-encodes a relative path for a Markdown link target, keeping `/`.
    public static func linkPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { part in
            String(part).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
                ?? String(part)
        }.joined(separator: "/")
    }

    /// Text safe inside `[...]` of a Markdown link, on one line.
    public static func linkText(_ s: String) -> String {
        var o = ""
        for ch in oneLine(s) {
            if "\\[]".contains(ch) { o += "\\\(ch)" } else { o.append(ch) }
        }
        return o
    }

    /// A fenced block holding `text` literally (the fence outgrows any backtick run in it).
    static func fenced(_ text: String) -> String {
        var run = 0, longest = 0
        for ch in text { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)text\n\(text)\n\(fence)\n"
    }

    /// The note's Markdown file.
    ///
    /// - Parameters:
    ///   - pdfName: file name of the note's PDF, next to the `.md`.
    ///   - pageImages: per note page, the images (paths relative to the `.md`) of that page; may be empty.
    public static func note(info: ExportNoteInfo, state: NoteState, pdfName: String,
                            pageImages: [[String]] = []) -> String {
        var md = frontMatter(info) + "\n"
        md += "# \(oneLine(info.displayTitle))\n\n"
        md += "![[\(pdfName)]]\n\n"
        md += "[\(linkText(pdfName))](\(linkPath(pdfName)))\n"
        for (i, page) in state.pages.enumerated() {
            let images = i < pageImages.count ? pageImages[i] : []
            let text = page.recognition.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if images.isEmpty && text.isEmpty { continue }
            md += "\n## Page \(i + 1)\n\n"
            for img in images { md += "![Page \(i + 1)](\(linkPath(img)))\n" }
            if !text.isEmpty {
                if !images.isEmpty { md += "\n" }
                md += "Machine-recognized text (engine `\(oneLine(page.recognition?.engine ?? "").replacingOccurrences(of: "`", with: "'"))`, may contain errors):\n\n"
                md += fenced(text)
            }
        }
        return md
    }

    /// A folder's `README.md`: sub-folders (name, link relative to the folder) and notes.
    public static func folderIndex(title: String, subfolders: [(name: String, href: String)],
                                   notes: [ExportIndexEntry]) -> String {
        var md = "# \(oneLine(title))\n"
        if !subfolders.isEmpty {
            md += "\n## Notebooks\n\n"
            for f in subfolders { md += "- [\(linkText(f.name))](\(linkPath(f.href)))\n" }
        }
        if !notes.isEmpty {
            md += "\n## Notes\n\n"
            for n in notes {
                var line = "- [\(linkText(n.title.isEmpty ? "Untitled" : n.title))](\(linkPath(n.href)))"
                var facts = ["\(n.pages) page\(n.pages == 1 ? "" : "s")"]
                if let m = n.modified { facts.append("modified \(timestamp(m))") }
                let tags = n.tags.compactMap(obsidianTag)
                if !tags.isEmpty { facts.append("tags: " + tags.joined(separator: ", ")) }
                line += " — " + facts.joined(separator: ", ")
                md += line + "\n"
            }
        }
        md += "\n---\n\nPlaintext export from InkVault: these files are not encrypted.\n"
        return md
    }
}
