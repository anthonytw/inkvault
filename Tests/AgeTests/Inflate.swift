import Foundation

/// Minimal zlib (RFC 1950) / DEFLATE (RFC 1951) decoder, test-only.
///
/// Some CCTV vectors are zlib-compressed. Foundation on Linux has no zlib
/// API and the AgeTests target depends only on `Age`, so the tests carry
/// this small, unoptimised inflater.
enum Inflate {
    struct Failure: Error {}

    private struct BitReader {
        let data: [UInt8]
        var pos = 0
        var bit = 0

        mutating func bits(_ n: Int) throws -> Int {
            var v = 0
            for i in 0..<n {
                guard pos < data.count else { throw Failure() }
                v |= Int((data[pos] >> UInt8(bit)) & 1) << i
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return v
        }

        mutating func alignToByte() {
            if bit != 0 { bit = 0; pos += 1 }
        }
    }

    /// Canonical Huffman decoding table: counts per length and symbols in order.
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l != 0 {
                symbols[offs[l]] = s
                offs[l] += 1
            }
        }

        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try r.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure()
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Decodes a zlib stream (2-byte header, DEFLATE data, Adler-32).
    static func zlib(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 6 else { throw Failure() }
        let cmf: Int = Int(bytes[0])
        let flg: Int = Int(bytes[1])
        guard cmf & 0x0F == 8, (cmf * 256 + flg) % 31 == 0, flg & 0x20 == 0 else { throw Failure() }
        var r = BitReader(data: bytes, pos: 2)
        var out = [UInt8]()
        var final = false
        while !final {
            final = try r.bits(1) == 1
            switch try r.bits(2) {
            case 0:
                r.alignToByte()
                guard r.pos + 4 <= bytes.count else { throw Failure() }
                let len: Int = Int(bytes[r.pos]) + 256 * Int(bytes[r.pos + 1])
                r.pos += 4
                guard r.pos + len <= bytes.count else { throw Failure() }
                out += bytes[r.pos..<r.pos + len]
                r.pos += len
            case 1:
                var l = [Int](repeating: 8, count: 288)
                for i in 144..<256 { l[i] = 9 }
                for i in 256..<280 { l[i] = 7 }
                try inflateBlock(&r, &out, Huffman(lengths: l), Huffman(lengths: [Int](repeating: 5, count: 30)))
            case 2:
                let hlit = try r.bits(5) + 257, hdist = try r.bits(5) + 1, hclen = try r.bits(4) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { cl[order[i]] = try r.bits(3) }
                let clh = Huffman(lengths: cl)
                var lengths = [Int]()
                while lengths.count < hlit + hdist {
                    let sym = try clh.decode(&r)
                    switch sym {
                    case 0..<16: lengths.append(sym)
                    case 16:
                        guard let prev = lengths.last else { throw Failure() }
                        lengths += [Int](repeating: prev, count: 3 + (try r.bits(2)))
                    case 17: lengths += [Int](repeating: 0, count: 3 + (try r.bits(3)))
                    default: lengths += [Int](repeating: 0, count: 11 + (try r.bits(7)))
                    }
                }
                try inflateBlock(
                    &r, &out, Huffman(lengths: Array(lengths[0..<hlit])),
                    Huffman(lengths: Array(lengths[hlit..<hlit + hdist])))
            default:
                throw Failure()
            }
        }
        r.alignToByte()
        guard r.pos + 4 <= bytes.count else { throw Failure() }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in out {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        var want: UInt32 = 0
        for k in 0..<4 { want = want << 8 | UInt32(bytes[r.pos + k]) }
        let got: UInt32 = b << 16 | a
        guard want == got else { throw Failure() }
        return Data(out)
    }

    private static func inflateBlock(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < lengthBase.count else { throw Failure() }
                let len = lengthBase[li] + (try r.bits(lengthExtra[li]))
                let di = try dist.decode(&r)
                guard di < distBase.count else { throw Failure() }
                let d = distBase[di] + (try r.bits(distExtra[di]))
                guard d <= out.count else { throw Failure() }
                let start = out.count - d
                for k in 0..<len { out.append(out[start + k]) }
            }
        }
    }
}
