import Foundation

/// Drops stroke point payloads from revision JSON before it is decoded, for
/// readers that need everything but the ink geometry (note summaries, search).
///
/// Point arrays are almost all of a revision's bytes, and building them is
/// almost all of the decoding time. This pass copies the JSON byte for byte,
/// except that the value of every `"points"` member that is *certainly*
/// decodable as `[StrokePoint]` becomes `[]`. The result then goes through the
/// ordinary `Revision` decoder, so every other field is decoded, validated and
/// merged exactly as on the full path (`NoteReducer` never looks at points):
///
/// - A value is replaced only when it is an array whose every element is an
///   array of exactly nine JSON numbers (RFC 8259 grammar) without an
///   exponent and with at most `maxIntegerDigits` integer digits, so each is
///   a finite `Double`. Such a value always decodes as `[StrokePoint]`, and
///   so does `[]`. Anything else (null, strings, eight or ten numbers, `1e5`,
///   a syntax error) is copied unchanged and the decoder judges it as usual.
/// - Bytes outside replaced values are untouched, and a replaced value is
///   a complete JSON value in both versions, so the output is valid JSON
///   exactly when the input is, and decodes to the same revision apart from
///   `points` being empty. Strings are followed exactly (`\"` escapes), so
///   `"points"` inside a string value is never taken for a key.
/// - A key spelled with escapes (`"points"`) is not recognised: its value
///   is simply decoded in full.
///
/// - Only UTF-8 is filtered: a body holding a NUL byte (UTF-16 or UTF-32,
///   which the decoder also accepts; valid UTF-8 JSON never holds one) is
///   returned unchanged, since its bytes are not its characters.
/// - Replacing a value removes nesting levels, so a document nested near the
///   decoder's limit (512 levels) could decode only once stripped: one
///   reaching `maxDepth` outside the replaced values is returned unchanged.
///
/// Cost: one pass over the bytes, O(n) time, output at most n bytes. No
/// allocation until the first replacement.
enum StrokePointsFilter {
    /// Integer digits beyond which a number might not be a finite `Double`
    /// (the largest finite one has 309); such a points value is kept.
    static let maxIntegerDigits = 300
    /// Nesting depth (outside replaced values) from which the input is left
    /// as it is: a replaced value nests two more levels, still below the
    /// decoder's 512.
    static let maxDepth = 500

    /// `json` with every certainly-decodable `"points"` value replaced by `[]`.
    static func strip(_ json: Data) -> Data {
        guard !json.contains(0) else { return json }   // not UTF-8
        return json.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            guard let base = b.baseAddress else { return json }
            let n = b.count
            var out: Data?
            var copied = 0
            var i = 0
            var depth = 0
            while i < n {
                guard b[i] == quote else {
                    if b[i] == open || b[i] == brace {
                        depth += 1
                        if depth >= maxDepth { return json }
                    } else if b[i] == close || b[i] == closeBrace {
                        depth -= 1
                    }
                    i += 1
                    continue
                }
                // A string from i + 1 to its closing quote.
                let start = i + 1
                var j = start
                while j < n {
                    let c = b[j]
                    if c == backslash { j += 2; continue }
                    if c == quote { break }
                    j += 1
                }
                guard j < n else { break }   // unterminated: the decoder reports it
                i = j + 1
                guard j - start == 6, b[start] == 0x70, b[start + 1] == 0x6F, b[start + 2] == 0x69,
                      b[start + 3] == 0x6E, b[start + 4] == 0x74, b[start + 5] == 0x73 else { continue }   // points
                var k = skipSpace(b, i)
                guard k < n, b[k] == colon else { continue }   // a string value, not a key
                k = skipSpace(b, k + 1)
                guard k < n, b[k] == open, let end = pointArrayEnd(b, from: k) else { continue }
                if out == nil {
                    out = Data()
                    out?.reserveCapacity(n / 4)
                }
                out?.append(base + copied, count: k - copied)
                out?.append(contentsOf: [open, close])
                copied = end
                i = end
            }
            guard var result = out else { return json }
            if copied < n { result.append(base + copied, count: n - copied) }
            return result
        }
    }

    private static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, colon: UInt8 = 0x3A
    private static let open: UInt8 = 0x5B, close: UInt8 = 0x5D, comma: UInt8 = 0x2C
    private static let brace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D

    private static func skipSpace(_ b: UnsafeBufferPointer<UInt8>, _ from: Int) -> Int {
        var i = from
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        return i
    }

    /// The index after the `]` closing the array at `from` if it is an array
    /// of 9-number arrays (see the type's rules), else nil.
    static func pointArrayEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = skipSpace(b, from + 1)
        guard i < b.count else { return nil }
        if b[i] == close { return i + 1 }
        while true {
            guard i < b.count, b[i] == open else { return nil }
            i += 1
            for v in 0..<9 {
                i = skipSpace(b, i)
                guard let after = numberEnd(b, from: i) else { return nil }
                i = skipSpace(b, after)
                guard i < b.count, b[i] == (v == 8 ? close : comma) else { return nil }
                i += 1
            }
            i = skipSpace(b, i)
            guard i < b.count else { return nil }
            if b[i] == close { return i + 1 }
            guard b[i] == comma else { return nil }
            i = skipSpace(b, i + 1)
        }
    }

    /// The index after a JSON number at `from` without exponent and with at
    /// most `maxIntegerDigits` integer digits, else nil.
    static func numberEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from
        let n = b.count
        if i < n, b[i] == 0x2D { i += 1 }   // -
        guard i < n, isDigit(b[i]) else { return nil }
        if b[i] == 0x30 {
            i += 1
        } else {
            let first = i
            while i < n, isDigit(b[i]) { i += 1 }
            guard i - first <= maxIntegerDigits else { return nil }
        }
        if i < n, b[i] == 0x2E {   // .
            i += 1
            guard i < n, isDigit(b[i]) else { return nil }
            while i < n, isDigit(b[i]) { i += 1 }
        }
        // An exponent (or a digit after a leading 0, which is invalid JSON) is left to the decoder.
        if i < n, b[i] == 0x65 || b[i] == 0x45 || isDigit(b[i]) { return nil }
        return i
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
}
