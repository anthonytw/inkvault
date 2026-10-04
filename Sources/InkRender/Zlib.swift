import Foundation
import CZlib

/// Thin wrapper over zlib's one-shot `compress2` (zlib format,
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
}
