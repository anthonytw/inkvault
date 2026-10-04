import Foundation
import CZlib

/// Thin wrappers over zlib's one-shot `compress2` / `uncompress` (zlib format,
/// which is what PDF `FlateDecode` expects).
enum Zlib {
    static func compress(_ data: Data, level: Int32 = 6) throws -> Data {
        var destLen = compressBound(uLong(data.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let rc: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
            let base = src.bindMemory(to: Bytef.self).baseAddress
            return dest.withUnsafeMutableBufferPointer { d in
                compress2(d.baseAddress, &destLen, base, uLong(data.count), level)
            }
        }
        guard rc == Z_OK else { throw RenderError.compressionFailed(rc) }
        return Data(dest[0..<Int(destLen)])
    }

    /// Inflates `data`; `sizeHint` bounds the output (grows on `Z_BUF_ERROR`).
    static func decompress(_ data: Data, sizeHint: Int = 1 << 16) throws -> Data {
        var cap = max(sizeHint, 1024)
        while cap < (1 << 31) {
            var destLen = uLongf(cap)
            var dest = [UInt8](repeating: 0, count: cap)
            let rc: Int32 = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
                let base = src.bindMemory(to: Bytef.self).baseAddress
                return dest.withUnsafeMutableBufferPointer { d in
                    uncompress(d.baseAddress, &destLen, base, uLong(data.count))
                }
            }
            if rc == Z_OK { return Data(dest[0..<Int(destLen)]) }
            if rc != Z_BUF_ERROR { throw RenderError.compressionFailed(rc) }
            cap *= 4
        }
        throw RenderError.compressionFailed(Z_MEM_ERROR)
    }
}
